"""Load prepared local gzip NDJSON into BigQuery with replay-safe job fingerprints."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from typing import Any

from scripts.shared.common import ExtractionError, emit


PROJECT_ID = "a365-de-ignacio"
RAW_DATASET = "assist365_raw"
SCHEMA_DIR = Path(__file__).resolve().parent / "sql"


def bq_load(
    source: Path, table: str, schema: Path, location: str,
    project_id: str = PROJECT_ID,
) -> None:
    """Run one synchronous append load job and raise on any nonzero CLI result."""
    command = [
        "bq", f"--project_id={project_id}", f"--location={location}",
        "--fingerprint_job_id=true", "load",
        "--source_format=NEWLINE_DELIMITED_JSON", "--compression=GZIP",
        f"--schema={schema}", f"{project_id}:{RAW_DATASET}.{table}", str(source),
    ]
    emit("bigquery_load_started", table=table, source=source.name,
         bytes=source.stat().st_size)
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        emit("bigquery_load_failed", table=table, source=source.name,
             return_code=result.returncode, message=result.stderr[-1000:])
        raise ExtractionError(f"Falló bq load para {table}/{source.name}.")
    emit("bigquery_load_succeeded", table=table, source=source.name,
         output=result.stdout[-500:])


def verify_prepared_file(path: Path, metadata: dict[str, Any]) -> None:
    """Reject a missing or modified file before it can create a BigQuery load job."""
    if not path.is_file():
        raise ExtractionError(f"No existe el archivo preparado: {path}")
    if path.stat().st_size != metadata.get("compressed_bytes"):
        raise ExtractionError(f"Cambió el tamaño del archivo preparado: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != metadata.get("compressed_sha256"):
        raise ExtractionError(f"Cambió el checksum del archivo preparado: {path}")


def load_run(manifest_path: Path, location: str, project_id: str = PROJECT_ID) -> None:
    """Load one fully prepared run sequentially, once per resource file."""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("source_run_status") not in {"SUCCESS", "SUCCESS_WITH_QUARANTINE"}:
        raise ExtractionError("Se rechaza cargar un run parcial o fallido.")
    if not manifest.get("resources"):
        raise ExtractionError("El manifiesto de carga no contiene recursos.")
    if shutil.which("bq") is None:
        raise ExtractionError("No se encontró bq CLI en PATH.")

    for resource in manifest["resources"]:
        source = Path(resource["load_file"])
        verify_prepared_file(source, resource)
        if resource["rows"]:
            bq_load(source, "records", SCHEMA_DIR / "raw_records_schema.json", location,
                    project_id)

    run_file = manifest.get("run_file", {}).get("load_file")
    if run_file:
        verify_prepared_file(Path(run_file), manifest["run_file"])
        bq_load(Path(run_file), "ingestion_runs", SCHEMA_DIR / "ingestion_runs_schema.json",
                location, project_id)
    reconciliation_file = manifest.get("reconciliation_file", {}).get("load_file")
    if reconciliation_file:
        verify_prepared_file(Path(reconciliation_file), manifest["reconciliation_file"])
        bq_load(Path(reconciliation_file), "reconciliations",
                SCHEMA_DIR / "reconciliations_schema.json", location, project_id)

    error_file: dict[str, Any] | None = manifest.get("error_file")
    if error_file and error_file.get("errors", 0):
        source = Path(error_file["load_file"])
        verify_prepared_file(source, error_file)
        bq_load(source, "ingestion_errors", SCHEMA_DIR / "ingestion_errors_schema.json",
                location, project_id)
    emit("bigquery_run_loads_complete", run_id=manifest.get("run_id"),
         rows=manifest.get("rows_prepared"),
         resources=len(manifest["resources"]))


def parse_args() -> argparse.Namespace:
    """Parse a prepared-run manifest and required BigQuery location."""
    parser = argparse.ArgumentParser(description="Load verified local raw files to BigQuery.")
    parser.add_argument("load_manifest", type=Path)
    parser.add_argument("--location", required=True,
                        help="Ubicación del dataset BigQuery, por ejemplo US.")
    parser.add_argument("--project", default=PROJECT_ID)
    return parser.parse_args()


def main() -> int:
    """Load a verified run locally prepared earlier, without API extraction."""
    args = parse_args()
    try:
        load_run(args.load_manifest, args.location, args.project)
        return 0
    except Exception as exc:
        emit("bigquery_run_load_failed", error_class=type(exc).__name__,
             message=str(exc)[:300])
        return 1
