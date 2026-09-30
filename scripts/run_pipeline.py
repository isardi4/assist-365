"""Run the GCS snapshot through raw, staging and gold without calling the source API."""
from __future__ import annotations

import argparse
import json
import re
import shutil
import uuid
from datetime import date

from scripts.shared.artifacts import artifact_path, gcs_root
from scripts.shared.common import ExtractionError, atomic_write, emit, utc_now
from scripts.parte_02_carga_bigquery.create_environment import create_environment
from scripts.parte_02_carga_bigquery.prepare_load import prepare_run
from scripts.parte_02_carga_bigquery.load_bigquery import load_run, PROJECT_ID
from scripts.parte_02_carga_bigquery.verify_raw import verify_raw
from scripts.parte_03_modelo_bigquery.apply_staging import apply as apply_staging, RESOURCES
from scripts.parte_03_modelo_bigquery.gold.apply_gold import apply as apply_gold


def run(run_id: str, cutoff: str, location: str, setup: bool = False) -> dict:
    """Ejecuta preparación, raw, staging y gold desde GCS y guarda el reporte de la corrida."""
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', run_id):
        raise ExtractionError('run_id inválido.')
    if any(shutil.which(tool) is None for tool in ['gcloud', 'bq']):
        raise ExtractionError('Se necesitan gcloud y bq en PATH.')
    root = artifact_path(gcs_root())
    evidence = root / 'pipeline' / run_id / uuid.uuid4().hex
    manifest = root / 'bigquery-load' / run_id / 'load_manifest.json'
    report = {'run_id': run_id, 'fecha_corte': cutoff, 'started_at': utc_now(),
              'source_api_calls': 0, 'steps': [], 'evidence': str(evidence)}
    steps = []
    if setup:
        steps.append(('environment', lambda: create_environment(location)))
    steps += [
        ('prepare', lambda: prepare_run(root / 'raw' / run_id, root / 'bigquery-load')),
        ('raw_load', lambda: load_run(manifest, location)),
        ('raw_verify', lambda: verify_raw(manifest, PROJECT_ID, location, 1024 ** 3)),
        ('staging', lambda: apply_staging(manifest, location, sorted(RESOURCES))),
        ('gold', lambda: apply_gold(location, cutoff)),
    ]
    try:
        for name, operation in steps:
            emit('pipeline_step_started', step=name, run_id=run_id)
            result = operation()
            report['steps'].append({'step': name, 'status': 'SUCCESS'})
            if name == 'gold':
                report['gold'] = result
        report['status'] = 'SUCCESS'
    except Exception as error:
        report.update(status='FAILED', failed_step=name, error=str(error)[:500])
        raise
    finally:
        report['finished_at'] = utc_now()
        atomic_write(evidence / 'report.json', json.dumps(report, indent=2).encode())
        emit('pipeline_finished', run_id=run_id, status=report['status'], evidence=str(evidence))
    return report


def main() -> int:
    """Lee las opciones del pipeline y devuelve un código de error si alguna etapa falla."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--fecha-corte', type=date.fromisoformat, required=True)
    parser.add_argument('--location', default='us-central1')
    parser.add_argument('--setup', action='store_true', help='Crear/reutilizar datasets y esquemas antes de cargar.')
    args = parser.parse_args()
    try:
        run(args.run_id, args.fecha_corte.isoformat(), args.location, args.setup)
        return 0
    except Exception as error:
        emit('pipeline_failed', message=str(error)[:500])
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
