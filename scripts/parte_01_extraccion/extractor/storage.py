"""Local raw-page storage, durable checkpoints, manifests, and error ledgers."""

from __future__ import annotations

import gzip
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..api.common import BASE_URL, RESOURCES
from ...shared.common import ExtractionError, atomic_write, emit, sha256, utc_now


def save_manifest(path: Path, manifest: dict[str, Any]) -> None:
    """Atomically persist run state so the next invocation can resume safely."""
    manifest["updated_at"] = utc_now()
    raw = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    atomic_write(path, raw)


def append_error(path: Path, record: dict[str, Any]) -> None:
    """Append one structured failure without including the source record value."""
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps({"timestamp": utc_now(), **record}, ensure_ascii=False).encode("utf-8") + b"\n"
    with path.open("ab") as output:
        output.write(line)
        output.flush()
        os.fsync(output.fileno())


def initial_manifest(run_id: str, output_dir: Path, selected: list[str]) -> dict[str, Any]:
    """Create an empty manifest covering every source and selected resource."""
    return {
        "manifest_version": 1,
        "run_id": run_id,
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "api_base": BASE_URL,
        "output_dir": str(output_dir),
        "run_status": "RUNNING",
        "resources": {
            name: {
                "status": "PENDING" if name not in selected else "RUNNING",
                "complete": False,
                "rows_received": 0,
                "pages_saved": 0,
                "quarantined_records": 0,
                "pages": [],
            }
            for name in RESOURCES
        },
    }


def load_or_create_manifest(
    path: Path, run_id: str, output_dir: Path, selected: list[str],
) -> dict[str, Any]:
    """Load a compatible checkpoint or initialize a new extraction run."""
    if path.exists():
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if manifest.get("manifest_version") != 1 or manifest.get("run_id") != run_id:
            raise ExtractionError("El manifest existente no coincide con esta versión o run_id.")
        if manifest.get("api_base") != BASE_URL:
            raise ExtractionError("El manifest existente apunta a otra base de API.")
        return manifest
    return initial_manifest(run_id, output_dir, selected)


def page_path(run_dir: Path, resource: str, page_number: int) -> Path:
    """Return the canonical local path for a resource page."""
    return run_dir / resource / f"page-{page_number:06d}.json.gz"


def write_raw_page(raw_body: bytes, run_dir: Path, resource: str, page_number: int) -> Path:
    """Durably store a full response page, preserving retries as separate files."""
    path = page_path(run_dir, resource, page_number)
    if path.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = path.with_name(f"{path.stem}.attempt-{stamp}{path.suffix}")
    atomic_write(path, gzip.compress(raw_body, mtime=0))
    return path


def json_type(value: Any) -> str:
    """Classify a JSON value without retaining its contents."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def shape_summary(
    data: list[Any],
) -> tuple[list[dict[str, Any]], dict[str, dict[str, int]], list[tuple[int, Any]]]:
    """Count record field-shapes and value types, returning non-object rows for quarantine."""
    counts: dict[str, int] = {}
    field_types: dict[str, dict[str, int]] = {}
    invalid: list[tuple[int, Any]] = []
    for index, row in enumerate(data):
        if not isinstance(row, dict):
            invalid.append((index, row))
            continue
        signature = json.dumps(sorted(row.keys()), ensure_ascii=False, separators=(",", ":"))
        counts[signature] = counts.get(signature, 0) + 1
        for field, value in row.items():
            types = field_types.setdefault(field, {})
            kind = json_type(value)
            types[kind] = types.get(kind, 0) + 1
    shapes = [{"fields": json.loads(shape), "rows": count} for shape, count in sorted(counts.items())]
    return shapes, field_types, invalid


def fail_record(
    error_path: Path, manifest: dict[str, Any], resource: str, page_number: int,
    row_index: int, row: Any, raw_file: str,
) -> None:
    """Record a malformed top-level row by position and fingerprint, retaining raw separately."""
    fingerprint = sha256(json.dumps(row, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")).encode("utf-8"))
    append_error(error_path, {
        "run_id": manifest["run_id"],
        "resource": resource,
        "page_number": page_number,
        "record_index": row_index,
        "error_class": "top_level_record_not_object",
        "fingerprint_sha256": fingerprint,
        "raw_file": raw_file,
        "resolution_status": "pending",
    })
    manifest["resources"][resource]["quarantined_records"] += 1


def persist_page(
    raw_body: bytes, payload: Any, path: Path, run_dir: Path, manifest: dict[str, Any],
    resource: str, page_number: int, request_position: dict[str, Any],
) -> tuple[dict[str, Any], list[tuple[int, Any]]]:
    """Describe a saved response page without changing or projecting its JSON body."""
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise ExtractionError(f"Respuesta inválida en {resource}, página {page_number}; JSON crudo preservado.")
    rows = payload["data"]
    shapes, field_types, invalid_rows = shape_summary(rows)
    rel_path = str(path.relative_to(run_dir))
    page: dict[str, Any] = {
        "page_number": page_number,
        **request_position,
        "_raw_file": rel_path,
        "compressed_bytes": path.stat().st_size,
        "response_bytes": len(raw_body),
        "response_sha256": sha256(raw_body),
        "rows_received": len(rows),
        "record_shapes": shapes,
        "field_types": field_types,
        "saved_at": utc_now(),
    }
    for key in ("pagination", "meta"):
        if isinstance(payload.get(key), dict):
            page[key] = payload[key]
    return page, invalid_rows


def commit_page(
    page: dict[str, Any], invalid_rows: list[tuple[int, Any]], error_path: Path,
    manifest_path: Path, manifest: dict[str, Any], resource: str,
) -> None:
    """Commit page metadata and row-level quarantine entries as one checkpoint."""
    state = manifest["resources"][resource]
    raw_file = page.pop("_raw_file")
    page["raw_file"] = raw_file
    state["pages"].append(page)
    state["pages_saved"] += 1
    state["rows_received"] += page["rows_received"]
    state["response_bytes"] = state.get("response_bytes", 0) + page["response_bytes"]
    state["compressed_bytes"] = state.get("compressed_bytes", 0) + page["compressed_bytes"]
    for index, row in invalid_rows:
        fail_record(error_path, manifest, resource, page["page_number"], index, row, raw_file)
    save_manifest(manifest_path, manifest)
    if invalid_rows:
        emit("records_quarantined", run_id=manifest["run_id"], resource=resource,
             page=page["page_number"], count=len(invalid_rows), raw_file=raw_file)


def mark_in_progress(
    manifest_path: Path, manifest: dict[str, Any], resource: str,
    page_number: int, position: dict[str, Any],
) -> None:
    """Persist the requested page position before issuing its API call."""
    manifest["resources"][resource]["in_progress"] = {
        "page_number": page_number, **position, "started_at": utc_now(),
    }
    save_manifest(manifest_path, manifest)


def fetch_and_save_page(
    client: Any, endpoint: str, params: dict[str, str | int], run_dir: Path,
    manifest_path: Path, manifest: dict[str, Any], resource: str,
    page_number: int, position: dict[str, Any],
) -> tuple[bytes, Path]:
    """Recover a pending raw page when possible; otherwise request and save it atomically."""
    state = manifest["resources"][resource]
    pending = state.get("in_progress", {})
    same_request = pending.get("page_number") == page_number and all(
        pending.get(key) == value for key, value in position.items()
    )
    if same_request:
        candidate = run_dir / pending["raw_file"] if pending.get("raw_file") else page_path(
            run_dir, resource, page_number
        )
        if candidate.is_file():
            try:
                body = gzip.decompress(candidate.read_bytes())
                emit("page_recovered_from_checkpoint", run_id=manifest["run_id"],
                     resource=resource, page=page_number,
                     raw_file=str(candidate.relative_to(run_dir)))
                return body, candidate
            except (OSError, EOFError, gzip.BadGzipFile):
                emit("checkpoint_file_unreadable", run_id=manifest["run_id"],
                     resource=resource, page=page_number,
                     raw_file=str(candidate.relative_to(run_dir)))
    mark_in_progress(manifest_path, manifest, resource, page_number, position)
    body, _, _ = client.get_json(endpoint, params)
    raw_path = write_raw_page(body, run_dir, resource, page_number)
    state["in_progress"]["raw_file"] = str(raw_path.relative_to(run_dir))
    save_manifest(manifest_path, manifest)
    return body, raw_path


def report_schema_changes(manifest: dict[str, Any], resource: str, page: dict[str, Any]) -> None:
    """Log new record shapes and field types relative to previously committed pages."""
    seen: set[str] = set()
    prior_types: dict[str, set[str]] = {}
    for old_page in manifest["resources"][resource]["pages"]:
        for shape in old_page.get("record_shapes", []):
            seen.add(json.dumps(shape["fields"], ensure_ascii=False, separators=(",", ":")))
        for field, type_counts in old_page.get("field_types", {}).items():
            prior_types.setdefault(field, set()).update(type_counts)
    for shape in page.get("record_shapes", []):
        signature = json.dumps(shape["fields"], ensure_ascii=False, separators=(",", ":"))
        if seen and signature not in seen:
            emit("record_shape_drift", run_id=manifest["run_id"], resource=resource,
                 page=page["page_number"], fields=shape["fields"], rows=shape["rows"])
    for field, type_counts in page.get("field_types", {}).items():
        if len(type_counts) > 1:
            emit("mixed_field_types_in_page", run_id=manifest["run_id"], resource=resource,
                 page=page["page_number"], field=field, type_counts=type_counts)
        known_types = prior_types.get(field, set())
        new_types = sorted(set(type_counts) - known_types)
        if known_types and new_types:
            emit("field_type_drift", run_id=manifest["run_id"], resource=resource,
                 page=page["page_number"], field=field, new_types=new_types)


def finish_resource(manifest_path: Path, manifest: dict[str, Any], resource: str, complete: bool) -> None:
    """Set a resource to complete or partial, preserving quarantine status."""
    state = manifest["resources"][resource]
    state["complete"] = complete
    if complete:
        state["status"] = "SUCCESS_WITH_QUARANTINE" if state["quarantined_records"] else "SUCCESS"
    elif state["status"] != "FAILED":
        state["status"] = "PARTIAL"
    state["finished_at"] = utc_now()
    save_manifest(manifest_path, manifest)
