"""Create the four Assist-365 datasets and raw/control tables in one location."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path

from scripts.shared.common import ExtractionError, emit


PROJECT_ID = "a365-de-ignacio"
DATASETS = {
    "assist365_raw": "Source data, one table per API resource",
    "assist365_control": "Operational ingestion, error and reconciliation controls",
    "assist365_staging": "Reserved for profiled intermediate models",
    "assist365_mart": "Reserved for validated analytical models",
}
DDL_PATH = (
    Path(__file__).resolve().parent / "sql" / "001_raw_and_control_tables.sql"
)
SCHEMA_DIR = DDL_PATH.parent
TABLE_SCHEMAS = {
    "polizas": "raw_records_schema.json",
    "siniestros": "raw_records_schema.json",
    "agencias": "raw_records_schema.json",
    "productos": "raw_records_schema.json",
    "tipo_cambio": "raw_records_schema.json",
    "ingestion_runs": "ingestion_runs_schema.json",
    "ingestion_errors": "ingestion_errors_schema.json",
    "reconciliations": "reconciliations_schema.json",
    "watermarks": "watermarks_schema.json",
    "snapshot_diffs": "snapshot_diffs_schema.json",
}


def run_bq(arguments: list[str], location: str) -> subprocess.CompletedProcess[str]:
    """Run a BigQuery CLI command with explicit project location and captured output."""
    return subprocess.run(
        ["bq", f"--project_id={PROJECT_ID}", f"--location={location}", *arguments],
        capture_output=True, text=True, check=False,
    )


def existing_datasets(location: str) -> set[str]:
    """List current datasets so creation never overwrites or assumes their region."""
    result = run_bq(["ls", "--format=json"], location)
    if result.returncode:
        raise ExtractionError(f"No se pudieron listar datasets: {result.stderr[-500:]}")
    try:
        values = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        raise ExtractionError("bq ls no devolvió JSON válido.") from None
    return {
        item.get("datasetReference", {}).get("datasetId")
        for item in values if isinstance(item, dict)
    }


def dataset_location(dataset: str, location: str) -> str:
    """Read a dataset's configured location before reusing it."""
    result = run_bq(["show", "--format=json", f"{PROJECT_ID}:{dataset}"], location)
    if result.returncode:
        raise ExtractionError(f"No se pudo inspeccionar {dataset}: {result.stderr[-500:]}")
    try:
        return json.loads(result.stdout).get("location", "")
    except json.JSONDecodeError:
        raise ExtractionError(f"bq show no devolvió JSON válido para {dataset}.") from None


def create_environment(location: str) -> None:
    """Create datasets/tables and apply each table's schema metadata in one update."""
    if shutil.which("bq") is None:
        raise ExtractionError("No se encontró bq CLI en PATH.")
    existing = existing_datasets(location)
    for dataset, description in DATASETS.items():
        if dataset in existing:
            current_location = dataset_location(dataset, location)
            if current_location.casefold() != location.casefold():
                raise ExtractionError(
                    f"{dataset} ya existe en {current_location}, no en {location}."
                )
            emit("bigquery_dataset_reused", project=PROJECT_ID, dataset=dataset,
                 location=location)
            continue
        result = run_bq([
            "mk", "--dataset", f"--description={description}",
            f"{PROJECT_ID}:{dataset}",
        ], location)
        if result.returncode:
            raise ExtractionError(f"No se pudo crear {dataset}: {result.stderr[-500:]}")
        emit("bigquery_dataset_created", project=PROJECT_ID, dataset=dataset,
             location=location)

    sql = DDL_PATH.read_text(encoding="utf-8")
    result = run_bq(["query", "--use_legacy_sql=false", sql], location)
    if result.returncode:
        raise ExtractionError(f"Falló {DDL_PATH.name}: {result.stderr[-800:]}")
    emit("bigquery_raw_tables_created", project=PROJECT_ID, location=location)

    descriptions = json.loads(
        SCHEMA_DIR.joinpath("table_descriptions.json").read_text(encoding="utf-8")
    )
    for index, (table, schema_file) in enumerate(TABLE_SCHEMAS.items()):
        # BigQuery limits rapid metadata updates; pace the schema patches.
        if index:
            time.sleep(2.2)
        dataset = "assist365_raw" if table in {"polizas", "siniestros", "agencias", "productos", "tipo_cambio"} else "assist365_control"
        result = run_bq([
            "update", f"--description={descriptions[table]}",
            f"--schema={SCHEMA_DIR / schema_file}",
            f"{PROJECT_ID}:{dataset}.{table}",
        ], location)
        if result.returncode:
            raise ExtractionError(
                f"Falló la descripción del esquema {table}: {result.stderr[-800:]}"
            )
        emit("bigquery_table_metadata_updated", project=PROJECT_ID, table=table,
             columns=len(json.loads((SCHEMA_DIR / schema_file).read_text(encoding="utf-8"))))


def parse_args() -> argparse.Namespace:
    """Parse the required, explicit BigQuery location for resource creation."""
    parser = argparse.ArgumentParser(description="Crear el entorno BigQuery de Assist-365.")
    parser.add_argument("--location", required=True,
                        help="Ubicación fija de los cuatro datasets, por ejemplo US.")
    return parser.parse_args()


def main() -> int:
    """Create datasets/tables, failing safely when environment already exists."""
    args = parse_args()
    try:
        create_environment(args.location)
        return 0
    except Exception as exc:
        emit("bigquery_environment_creation_failed", error_class=type(exc).__name__,
             message=str(exc)[:300])
        return 1
