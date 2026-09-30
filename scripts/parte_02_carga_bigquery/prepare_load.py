"""Convert validated API pages into BigQuery-ready newline-delimited JSON."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from scripts.shared.common import ExtractionError, emit, sha256, utc_now
from scripts.shared.artifacts import GCSPath, artifact_path, gcs_root, publish_file


SOURCE_KEYS = {
    "productos": ("producto_id",),
    "agencias": ("agencia_id",),
    "tipo_cambio": ("fecha", "moneda"),
    "polizas": ("poliza_id",),
    "siniestros": ("claim_id",),
}


def canonical_json(value: Any) -> str:
    """Serialize a JSON value deterministically for stable row fingerprints."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False)


def encode_non_finite(value: Any, path: str = "$", issues: list[dict[str, str]] | None = None) -> Any:
    """Replace non-finite numbers with explicit JSON markers and record their paths."""
    if issues is None:
        issues = []
    if isinstance(value, float) and not math.isfinite(value):
        marker = "NaN" if math.isnan(value) else ("Infinity" if value > 0 else "-Infinity")
        issues.append({"path": path, "value": marker})
        return {"__non_finite_number__": marker}
    if isinstance(value, dict):
        return {key: encode_non_finite(item, f"{path}.{key}", issues)
                for key, item in value.items()}
    if isinstance(value, list):
        return [encode_non_finite(item, f"{path}[{index}]", issues)
                for index, item in enumerate(value)]
    return value


def source_key(resource: str, row: Any) -> str | None:
    """Build a source key when the observed row contains its documented identifiers."""
    fields = SOURCE_KEYS.get(resource, ())
    if not fields or not isinstance(row, dict) or any(row.get(field) is None for field in fields):
        return None
    return "|".join(str(row[field]) for field in fields)


def normalized_timestamp(value: Any) -> str | None:
    """Return an ISO UTC timestamp for parseable source timestamps, otherwise null."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def file_fingerprint(path: Path) -> tuple[int, str]:
    """Return a streamed size and SHA-256 checksum for a prepared artifact."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return path.stat().st_size, digest.hexdigest()


def write_resource(
    run_dir: Path, output_file: Path, run_id: str, resource: str,
    pages: list[dict[str, Any]],
) -> dict[str, Any]:
    """Verify a resource's pages and combine them into one atomic gzip load unit."""
    output_file.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{output_file.name}.", suffix=".tmp",
                                     dir=None if isinstance(output_file, GCSPath) else output_file.parent)
    count = 0
    digest = hashlib.sha256()
    page_checks: list[dict[str, Any]] = []
    data_quality_errors: list[dict[str, Any]] = []
    try:
        with os.fdopen(fd, "wb") as raw_output:
            with gzip.GzipFile(fileobj=raw_output, mode="wb", mtime=0) as compressed:
                for page_info in pages:
                    raw_path = run_dir / page_info["raw_file"]
                    if not raw_path.is_file():
                        raise ExtractionError(f"Falta página raw: {raw_path}")
                    try:
                        raw_body = gzip.decompress(raw_path.read_bytes())
                        payload = json.loads(raw_body)
                    except (OSError, EOFError, gzip.BadGzipFile, json.JSONDecodeError):
                        raise ExtractionError(f"No se puede leer JSON gzip: {raw_path}") from None
                    if sha256(raw_body) != page_info.get("response_sha256"):
                        raise ExtractionError(f"El checksum de la página no coincide: {raw_path}")
                    rows = payload.get("data") if isinstance(payload, dict) else None
                    if not isinstance(rows, list) or len(rows) != page_info.get("rows_received"):
                        raise ExtractionError(f"El conteo de la página no coincide: {raw_path}")
                    page_number = page_info["page_number"]
                    for index, row in enumerate(rows):
                        issues: list[dict[str, str]] = []
                        encoded_row = encode_non_finite(row, issues=issues)
                        source_fingerprint = hashlib.sha256(
                            json.dumps(row, ensure_ascii=False, sort_keys=True,
                                       separators=(",", ":"), allow_nan=True).encode("utf-8")
                        ).hexdigest()
                        for issue in issues:
                            data_quality_errors.append({
                                "created_at": page_info.get("saved_at") or utc_now(),
                                "run_id": run_id,
                                "resource": resource,
                                "batch_id": f"{run_id}:{resource}:{page_number}",
                                "page_number": page_number,
                                "record_index": index,
                                "source_key": source_key(resource, row),
                                "error_class": "NonFiniteJSONNumber",
                                "message": (
                                    f"Valor numérico {issue['value']} codificado con marcador "
                                    f"JSON explícito en {issue['path']}; revisar semántica de origen."
                                ),
                                "fingerprint_sha256": source_fingerprint,
                                "source_file": page_info["raw_file"],
                                "resolution_status": "preserved_with_marker",
                            })
                        record = {
                            "ingested_at": page_info.get("saved_at") or utc_now(),
                            "run_id": run_id,
                            "batch_id": f"{run_id}:{resource}:{page_number}",
                            "resource": resource,
                            "snapshot_id": run_id,
                            "page_number": page_number,
                            "record_index": index,
                            "source_key": source_key(resource, row),
                            "source_updated_at": normalized_timestamp(
                                row.get("updated_at") if isinstance(row, dict) else None
                            ),
                            "record_hash": source_fingerprint,
                            "source_file": page_info["raw_file"],
                            "payload": encoded_row,
                        }
                        line = (canonical_json(record) + "\n").encode("utf-8")
                        compressed.write(line)
                        digest.update(line)
                        count += 1
                    page_checks.append({
                        "page_number": page_number,
                        "rows": len(rows),
                        "response_sha256": page_info["response_sha256"],
                    })
            raw_output.flush()
            os.fsync(raw_output.fileno())
        publish_file(temporary, output_file)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    compressed_bytes, compressed_sha256 = file_fingerprint(output_file)
    return {
        "load_file": str(output_file),
        "rows": count,
        "uncompressed_sha256": digest.hexdigest(),
        "compressed_bytes": compressed_bytes,
        "compressed_sha256": compressed_sha256,
        "pages": page_checks,
        "data_quality_errors": data_quality_errors,
    }


def write_error_ledger(
    run_dir: Path, output_dir: Path, run_id: str,
    data_quality_errors: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Convert the structured error ledger into a BigQuery load file."""
    source = run_dir / "errors.jsonl"
    if (not source.is_file() or source.stat().st_size == 0) and not data_quality_errors:
        return None
    destination = output_dir / "errors.ndjson.gz"
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", suffix=".tmp",
                                     dir=None if isinstance(destination, GCSPath) else destination.parent)
    count = 0
    try:
        with os.fdopen(fd, "wb") as raw_output:
            with gzip.GzipFile(fileobj=raw_output, mode="wb", mtime=0) as compressed:
                source_lines = source.read_text(encoding="utf-8").splitlines() \
                    if source.is_file() else []
                for line_number, source_line in enumerate(source_lines, 1):
                    try:
                        error = json.loads(source_line)
                    except json.JSONDecodeError:
                        raise ExtractionError(
                            f"Ledger de errores inválido en línea {line_number}."
                        ) from None
                    record = {
                        "created_at": error.get("timestamp"),
                        "run_id": error.get("run_id", run_id),
                        "resource": error.get("resource"),
                        "batch_id": None,
                        "page_number": error.get("page_number"),
                        "record_index": error.get("record_index"),
                        "source_key": error.get("source_key"),
                        "error_class": error.get("error_class", "unspecified"),
                        "message": error.get("message"),
                        "fingerprint_sha256": error.get("fingerprint_sha256"),
                        "source_file": error.get("raw_file"),
                        "resolution_status": error.get("resolution_status", "pending"),
                    }
                    compressed.write((canonical_json(record) + "\n").encode("utf-8"))
                    count += 1
                for record in data_quality_errors:
                    compressed.write((canonical_json(record) + "\n").encode("utf-8"))
                    count += 1
            raw_output.flush()
            os.fsync(raw_output.fileno())
        publish_file(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    compressed_bytes, compressed_sha256 = file_fingerprint(destination)
    return {"load_file": str(destination), "errors": count,
            "compressed_bytes": compressed_bytes, "compressed_sha256": compressed_sha256}


def write_control_file(destination: Path, rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Write a small atomic gzip NDJSON file for run or reconciliation metadata."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", suffix=".tmp",
                                     dir=None if isinstance(destination, GCSPath) else destination.parent)
    try:
        with os.fdopen(fd, "wb") as raw_output:
            with gzip.GzipFile(fileobj=raw_output, mode="wb", mtime=0) as compressed:
                for row in rows:
                    compressed.write((canonical_json(row) + "\n").encode("utf-8"))
            raw_output.flush()
            os.fsync(raw_output.fileno())
        publish_file(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    compressed_bytes, compressed_sha256 = file_fingerprint(destination)
    return {"load_file": str(destination), "rows": len(rows),
            "compressed_bytes": compressed_bytes, "compressed_sha256": compressed_sha256}


def prepare_run(run_dir: Path, output_dir: Path, allow_partial: bool = False) -> Path:
    """Verify a run and create replayable NDJSON gzip files without API calls."""
    manifest_path = run_dir / "manifest.json"
    if not manifest_path.is_file():
        raise ExtractionError(f"No existe el manifiesto: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    status = manifest.get("run_status")
    if status not in {"SUCCESS", "SUCCESS_WITH_QUARANTINE"} and not allow_partial:
        raise ExtractionError(
            f"El run está {status}; requiere éxito completo para preparar carga. "
            "Usá --allow-partial solo para validaciones locales."
        )
    run_id = manifest.get("run_id")
    if not isinstance(run_id, str) or not run_id:
        raise ExtractionError("El manifiesto no contiene un run_id válido.")

    output_run = output_dir / run_id
    resource_results: list[dict[str, Any]] = []
    reconciliation_rows: list[dict[str, Any]] = []
    data_quality_errors: list[dict[str, Any]] = []
    for resource, resource_state in manifest.get("resources", {}).items():
        pages = resource_state.get("pages", [])
        load_path = output_run / f"{resource}.ndjson.gz"
        result = write_resource(run_dir, load_path, run_id, resource, pages)
        if result["rows"] != resource_state.get("rows_received", 0):
            raise ExtractionError(f"El total acumulado del manifiesto no coincide para {resource}.")
        resource_errors = result.pop("data_quality_errors")
        data_quality_errors.extend(resource_errors)
        resource_results.append({
            "resource": resource,
            "data_quality_issue_count": len(resource_errors),
            **result,
        })
        reconciliation_rows.append({
            "checked_at": utc_now(),
            "run_id": run_id,
            "resource": resource,
            "check_name": "local_pages_to_records",
            "check_status": "PASS",
            "expected_count": resource_state.get("rows_received", 0),
            "actual_count": result["rows"],
            "difference_count": 0,
            "details": {"pages": len(result["pages"]), "hashes_verified": len(result["pages"])},
        })
        if resource_errors:
            reconciliation_rows.append({
                "checked_at": utc_now(),
                "run_id": run_id,
                "resource": resource,
                "check_name": "non_finite_values_encoded_and_logged",
                "check_status": "PASS",
                "expected_count": len(resource_errors),
                "actual_count": len(resource_errors),
                "difference_count": 0,
                "details": {
                    "rows_dropped": 0,
                    "marker": '{"__non_finite_number__":"NaN"}',
                },
            })
        source_totals = [
            total
            for page in resource_state.get("pages", [])
            for total in (
                page.get("source_total"),
                page.get("meta", {}).get("total")
                if isinstance(page.get("meta"), dict) else None,
            )
            if isinstance(total, int) and not isinstance(total, bool)
        ]
        if source_totals:
            expected = source_totals[-1]
            actual = result["rows"]
            if expected != actual and resource_state.get("complete"):
                raise ExtractionError(f"El total de la fuente no coincide para {resource}.")
            reconciliation_rows.append({
                "checked_at": utc_now(), "run_id": run_id, "resource": resource,
                "check_name": "source_total_to_snapshot_rows",
                "check_status": "PASS" if expected == actual else "PARTIAL",
                "expected_count": expected, "actual_count": actual,
                "difference_count": actual - expected,
                "details": {"note": "Total informado por la API"},
            })

    error_file = write_error_ledger(run_dir, output_run, run_id, data_quality_errors)
    raw_jobs = len([item for item in resource_results if item["rows"] > 0])
    expected_jobs = raw_jobs + 2 + (1 if error_file and error_file["errors"] else 0)
    run_record = {
        "run_id": run_id,
        "started_at": manifest.get("created_at"),
        "finished_at": manifest.get("finished_at"),
        "run_status": status,
        "invocation_mode": "full" if manifest.get("full_extraction") else "bounded",
        "source_watermark_before": None,
        "source_watermark_after": None,
        "http_requests": manifest.get("http_requests", 0),
        "http_retries": manifest.get("http_retries", 0),
        "summary": {"resources": manifest.get("resources", {}),
                    "rows_prepared": sum(item["rows"] for item in resource_results)},
    }
    run_file = write_control_file(output_run / "ingestion_run.ndjson.gz", [run_record])
    reconciliation_file = write_control_file(
        output_run / "reconciliations.ndjson.gz", reconciliation_rows
    )

    summary = {
        "manifest_version": 1,
        "run_id": run_id,
        "source_run_status": status,
        "prepared_at": utc_now(),
        "source_manifest": str(manifest_path),
        "rows_prepared": sum(item["rows"] for item in resource_results),
        "pages_prepared": sum(len(item["pages"]) for item in resource_results),
        "data_quality_issues": len(data_quality_errors),
        "load_jobs_expected": expected_jobs,
        "error_file": error_file,
        "run_file": run_file,
        "reconciliation_file": reconciliation_file,
        "resources": resource_results,
    }
    summary_path = output_run / "load_manifest.json"
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8")
    emit("bigquery_files_prepared", run_id=run_id,
         pages=summary["pages_prepared"], rows=summary["rows_prepared"],
         load_jobs=summary["load_jobs_expected"],
         output_dir=str(output_run))
    return summary_path


def parse_args() -> argparse.Namespace:
    """Parse source/output paths and the explicit partial-run override."""
    parser = argparse.ArgumentParser(
        description="Verify GCS or local raw pages and prepare BigQuery NDJSON gzip load files."
    )
    parser.add_argument("run_dir", type=artifact_path, help="Directorio de una corrida con manifest.json")
    parser.add_argument("--output-dir", type=artifact_path,
                        help="Destino preparado; por defecto gcs_root/bigquery-load.")
    parser.add_argument("--allow-partial", action="store_true",
                        help="Permite preparar smoke tests incompletos; nunca para producción.")
    return parser.parse_args()


def main() -> int:
    """Check source integrity and convert pages without querying the source API."""
    args = parse_args()
    try:
        prepare_run(args.run_dir, args.output_dir or artifact_path(gcs_root()) / "bigquery-load", args.allow_partial)
        return 0
    except Exception as exc:
        emit("bigquery_preparation_failed", error_class=type(exc).__name__,
             message=str(exc)[:300])
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
