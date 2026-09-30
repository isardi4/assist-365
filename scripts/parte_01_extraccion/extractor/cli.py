"""Command-line interface and orchestration for bounded or full extraction runs."""

from __future__ import annotations

import argparse
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..api.client import ApiClient
from ..api.common import RESOURCES, read_token
from ...shared.common import ExtractionError, emit, sha256, utc_now
from ...shared.artifacts import artifact_path, gcs_root
from .extractors import extract_catalog, extract_claims, extract_policies
from .storage import append_error, finish_resource, load_or_create_manifest, save_manifest


def finalize_run(manifest_path: Path, manifest: dict[str, Any]) -> None:
    """Set the run-level outcome from the completion states of all resources."""
    statuses = [state["status"] for state in manifest["resources"].values()]
    if any(status == "FAILED" for status in statuses):
        status = "FAILED"
    elif all(status in {"SUCCESS", "SUCCESS_WITH_QUARANTINE"} for status in statuses):
        status = "SUCCESS_WITH_QUARANTINE" if "SUCCESS_WITH_QUARANTINE" in statuses else "SUCCESS"
    else:
        status = "PARTIAL"
    manifest["run_status"] = status
    manifest["finished_at"] = utc_now()
    save_manifest(manifest_path, manifest)
    emit("run_finished", run_id=manifest["run_id"], status=status,
         resources={name: state["status"] for name, state in manifest["resources"].items()})


def parse_args() -> argparse.Namespace:
    """Parse conservative defaults, explicit full mode, and optional resource filters."""
    parser = argparse.ArgumentParser(description="Checkpointed, low-rate Assist-365 API extractor.")
    parser.add_argument("--output-dir", type=artifact_path,
                        help="Prefijo gs:// para páginas/checkpoints; por defecto gcs_root/raw.")
    parser.add_argument("--run-id", help="ID para reanudar una ejecución; por defecto se genera uno UTC.")
    limits = parser.add_mutually_exclusive_group()
    limits.add_argument("--max-pages-per-resource", type=int, default=1,
                        help="Tope por recurso (default: 1); el run queda PARTIAL si faltan páginas.")
    limits.add_argument("--full", action="store_true",
                        help="Recorrer todas las páginas; requiere autorización para la descarga completa.")
    parser.add_argument("--min-interval-seconds", type=float, default=1.0,
                        help="Pausa mínima entre requests secuenciales (default: 1 segundo).")
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--max-retries", type=int, default=6,
                        help="Máximo de reintentos por request (default: 6; usar 0 para una sola tentativa).")
    parser.add_argument("--only", choices=RESOURCES, action="append", dest="selected",
                        help="Limitar a recursos específicos; repetir para más de uno.")
    args = parser.parse_args()
    if args.max_pages_per_resource < 1:
        parser.error("--max-pages-per-resource debe ser >= 1")
    if args.min_interval_seconds < 0 or args.timeout_seconds <= 0:
        parser.error("Los intervalos deben ser no negativos y el timeout positivo.")
    if args.max_retries < 0:
        parser.error("--max-retries debe ser >= 0")
    if args.run_id and not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.run_id):
        parser.error("--run-id admite letras, números, guion y guion bajo (1–64 caracteres).")
    args.selected = args.selected or list(RESOURCES)
    args.page_limit = None if args.full else args.max_pages_per_resource
    return args


def main() -> int:
    """Run selected resources, record failures, and return a nonzero partial/failure code."""
    args = parse_args()
    run_id = args.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        run_dir = (args.output_dir or artifact_path(gcs_root()) / "raw") / run_id
        manifest_path = run_dir / "manifest.json"
        error_path = run_dir / "errors.jsonl"
        token = read_token()
        client = ApiClient(token, args.min_interval_seconds, args.timeout_seconds, args.max_retries)
        del token
        run_dir.mkdir(parents=True, exist_ok=True)
        manifest = load_or_create_manifest(manifest_path, run_id, run_dir, args.selected)
        manifest["run_status"] = "RUNNING"
        manifest["full_extraction"] = args.full
        manifest["max_pages_per_resource"] = args.page_limit
        manifest["min_interval_seconds"] = args.min_interval_seconds
        manifest["max_retries"] = args.max_retries
        save_manifest(manifest_path, manifest)
        emit("run_started", run_id=run_id, resources=args.selected,
             page_limit_per_resource=args.page_limit, min_interval_seconds=args.min_interval_seconds)
        extractors = {
            "productos": lambda: extract_catalog("productos", client, run_dir, manifest_path,
                                                  error_path, manifest, args.page_limit),
            "agencias": lambda: extract_catalog("agencias", client, run_dir, manifest_path,
                                                 error_path, manifest, args.page_limit),
            "tipo_cambio": lambda: extract_catalog("tipo_cambio", client, run_dir, manifest_path,
                                                    error_path, manifest, args.page_limit),
            "polizas": lambda: extract_policies(client, run_dir, manifest_path, error_path,
                                                 manifest, args.page_limit),
            "siniestros": lambda: extract_claims(client, run_dir, manifest_path, error_path,
                                                  manifest, args.page_limit),
        }
        failures = 0
        for resource in args.selected:
            state = manifest["resources"][resource]
            if not state["complete"]:
                state["status"] = "RUNNING"
            try:
                extractors[resource]()
            except Exception as exc:
                failures += 1
                state["status"] = "FAILED"
                state["complete"] = False
                state["finished_at"] = utc_now()
                context = state.get("in_progress", {})
                cursor = context.get("request_cursor")
                append_error(error_path, {
                    "run_id": run_id,
                    "resource": resource,
                    "page_number": context.get("page_number"),
                    "request_offset": context.get("request_offset"),
                    "request_cursor_sha256": sha256(cursor.encode("utf-8")) if isinstance(cursor, str) else None,
                    "raw_file": context.get("raw_file"),
                    "error_class": type(exc).__name__,
                    "message": str(exc)[:500],
                    "resolution_status": "pending",
                })
                state["error_count"] = state.get("error_count", 0) + 1
                save_manifest(manifest_path, manifest)
                emit("resource_failed", run_id=run_id, resource=resource,
                     error_class=type(exc).__name__, message=str(exc)[:250])
        manifest["http_requests"] = client.request_count
        manifest["http_retries"] = client.retry_count
        finalize_run(manifest_path, manifest)
        return 1 if failures else (0 if manifest["run_status"] == "SUCCESS" else 2)
    except Exception as exc:
        emit("extractor_failed", run_id=run_id, error_class=type(exc).__name__, message=str(exc)[:300])
        return 1
