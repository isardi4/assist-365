"""Materialize the validated emission-cohort dashboard using existing silver data only."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import uuid
from pathlib import Path
from scripts.parte_03_modelo_bigquery.apply_staging import bq, query, metadata_api
from scripts.shared.common import atomic_write, emit
from scripts.shared.artifacts import artifact_path, gcs_root

ROOT = Path(__file__).resolve().parent


def apply(location: str = 'us-central1', fecha_corte: str = '2026-09-29') -> dict:
    job_id = 'assist365_gold_' + uuid.uuid4().hex
    evidence = artifact_path(gcs_root()) / 'gold' / job_id
    evidence.mkdir(parents=True, exist_ok=True)
    sql = '\n'.join((ROOT / 'sql' / name).read_text() for name in (
        '002_build_dashboard.sql', '001_dashboard_table.sql', '003_publish_dashboard.sql'))
    fingerprint = hashlib.sha256(sql.encode()).hexdigest()
    parameters = [f'job_id:STRING:{job_id}', f'model_sha256:STRING:{fingerprint}', f'fecha_corte:DATE:{fecha_corte}']
    atomic_write(evidence / 'executed.sql', sql.encode())
    query((ROOT / 'sql/000_control.sql').read_text(), location, job_id + '_control', parameters)
    emit('gold_started', job_id=job_id)
    try:
        output = query(sql, location, job_id, parameters)
        atomic_write(evidence / 'output.json', output.encode())
    except Exception as exc:
        error_message = str(exc)
        try:
            failed_job = json.loads(bq(['show', '--job=true', '--format=json', job_id], location))
            atomic_write(evidence / 'job.json', json.dumps(failed_job, indent=2).encode())
            error_message = failed_job.get('status', {}).get('errorResult', {}).get('message', error_message)
        except Exception:
            pass
        atomic_write(evidence / 'failure.txt', error_message.encode())
        query("""UPDATE `a365-de-ignacio.assist365_control.gold_runs`
        SET run_status='FAILED',finished_at=CURRENT_TIMESTAMP(),error_message=@error
        WHERE job_id=@job_id AND DATE(started_at)>=DATE '1970-01-01'""", location,
              job_id + '_failure', parameters + [f'error:STRING:{error_message[:1000]}'])
        raise
    job = json.loads(bq(['show', '--job=true', '--format=json', job_id], location))
    atomic_write(evidence / 'job.json', json.dumps(job, indent=2).encode())
    # Update descriptions in a single metadata operation, avoiding per-column DDL quotas.
    table_description = json.loads(re.search(
        r'^OPTIONS\(description=(".*")\);$',
        (ROOT / 'sql/001_dashboard_table.sql').read_text(), re.MULTILINE).group(1))
    bq(['update', '--schema=' + str(ROOT / 'schema.json'),
        '--description=' + table_description,
        'a365-de-ignacio:assist365_mart.dashboard_diario'], location)
    api = metadata_api()
    meta = api('datasets/assist365_mart/tables/dashboard_diario')
    expected = json.loads((ROOT / 'schema.json').read_text())
    actual = meta['schema']['fields']
    assert meta['type'] == 'TABLE'
    assert [(f['name'], {'BOOLEAN': 'BOOL', 'INTEGER': 'INT64'}.get(f['type'], f['type'])) for f in actual] == [(f['name'], f['type']) for f in expected]
    assert all(len(f.get('description', '')) >= 40 for f in actual)
    assert len(meta.get('description', '')) >= 200
    assert int(meta.get('numBytes', 0)) <= 50_000_000
    assert not any(f['name'].endswith('_id') for f in actual)
    inventory = {'table': 'dashboard_diario', 'rows': int(meta.get('numRows', 0)),
                 'logical_bytes': int(meta.get('numBytes', 0)), 'fields': actual,
                 'partition': meta.get('timePartitioning'), 'clustering': meta.get('clustering')}
    atomic_write(evidence / 'inventory.json', json.dumps(inventory, indent=2, ensure_ascii=False).encode())
    summary = json.loads(query("""SELECT summary FROM `a365-de-ignacio.assist365_control.gold_runs`
    WHERE job_id=@job_id AND DATE(started_at)>=DATE '1970-01-01'""", location, job_id + '_summary', parameters))[0]['summary']
    if isinstance(summary, str):
        summary = json.loads(summary)
    report = {'job_id': job_id, 'status': 'SUCCESS', 'table': 'dashboard_diario',
              'rows': inventory['rows'], 'logical_bytes': inventory['logical_bytes'],
              'processed_bytes': job['statistics'].get('totalBytesProcessed'),
              'summary': summary, 'evidence': str(evidence)}
    atomic_write(evidence / 'report.json', json.dumps(report, indent=2, ensure_ascii=False).encode())
    emit('gold_complete', **report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--location', default='us-central1')
    from datetime import date
    parser.add_argument('--fecha-corte', type=date.fromisoformat, default=date(2026, 9, 29))
    args = parser.parse_args()
    apply(args.location, args.fecha_corte.isoformat())
