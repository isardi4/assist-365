"""Reconcile a prepared snapshot against BigQuery raw without changing source data."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import uuid
from pathlib import Path

from scripts.shared.common import ExtractionError, atomic_write, emit, utc_now
from scripts.shared.artifacts import artifact_path, open_gzip
from .load_bigquery import PROJECT_ID, RAW_DATASET, CONTROL_DATASET, SCHEMA_DIR, bq_load


def verify_raw(manifest_path: Path, project: str, location: str, maximum_bytes: int) -> None:
    """Check every page, technical position, JSON marker and control-file row count."""
    manifest = json.loads(manifest_path.read_text())
    run_id = manifest['run_id']
    # Parameters and identifiers are validated before constructing SQL.
    if not re.fullmatch(r'[a-z][a-z0-9-]*', project):
        raise ExtractionError('Proyecto inválido.')
    base = f'`{project}.{RAW_DATASET}.'
    day_bounds = {}
    for key, column in [('resources', 'ingested_at'), ('run_file', 'started_at'),
                        ('error_file', 'created_at'), ('reconciliation_file', 'checked_at')]:
        dates = set()
        artifacts = manifest[key] if key == 'resources' else [manifest[key]]
        for artifact in artifacts:
            with open_gzip(artifact['load_file'], 'rt') as source:
                for line in source:
                    dates.add(json.loads(line)[column][:10])
        day_bounds[key] = (min(dates), max(dates))

    def predicate(key: str, column: str) -> str:
        """Limit reads to the source partitions and the requested run."""
        first, last = day_bounds[key]
        return f"DATE({column}) BETWEEN '{first}' AND '{last}' AND run_id = @run_id"

    queries = []
    for resource in manifest['resources']:
        if resource['resource'] not in {'polizas', 'siniestros', 'agencias', 'productos', 'tipo_cambio'}:
            raise ExtractionError('Recurso inválido.')
        queries.append(f'''SELECT 'page' AS kind, resource, page_number, COUNT(*) AS row_count,
      COUNT(DISTINCT record_index) AS positions,
      COUNTIF(payload IS NULL OR record_hash IS NULL OR source_file IS NULL
        OR batch_id IS NULL OR snapshot_id IS NULL OR snapshot_id != @run_id) AS invalid_metadata,
      COUNTIF(JSON_VALUE(payload, '$.amount.currency.__non_finite_number__') = 'NaN') AS markers
      FROM {base}{resource['resource']}` WHERE {predicate('resources', 'ingested_at')}
      GROUP BY resource, page_number''')
    sql = '\nUNION ALL\n'.join(queries)
    control_base = f'`{project}.{CONTROL_DATASET}.'
    for key, table, column in [('run_file', 'ingestion_runs', 'started_at'),
                               ('error_file', 'ingestion_errors', 'created_at'),
                               ('reconciliation_file', 'reconciliations', 'checked_at')]:
        extra = ""
        if table == 'reconciliations':
            extra = " AND check_name IN ('local_pages_to_records', 'source_total_to_snapshot_rows', 'non_finite_values_encoded_and_logged')"
        sql += f"\nUNION ALL SELECT '{table}', '', 0, COUNT(*), 0, 0, 0 FROM {control_base}{table}` WHERE {predicate(key, column)}{extra}"
    folder = manifest_path.parent / 'remote-verification'
    folder.mkdir(exist_ok=True)
    atomic_write(folder / 'verification.sql', sql.encode())
    job_id = 'assist365_raw_verify_' + uuid.uuid4().hex
    command = ['bq', f'--project_id={project}', f'--location={location}', '--format=json',
               'query', '--use_legacy_sql=false', f'--maximum_bytes_billed={maximum_bytes}',
               f'--parameter=run_id:STRING:{run_id}', '--max_rows=10000']
    dry = subprocess.run(command + ['--dry_run', sql], capture_output=True, text=True)
    atomic_write(folder / 'dry_run.txt', (dry.stdout + dry.stderr).encode())
    if dry.returncode:
        raise ExtractionError('Falló el dry run raw: ' + (dry.stdout + dry.stderr)[-1000:])
    result = subprocess.run(command + [f'--job_id={job_id}', sql], capture_output=True, text=True)
    atomic_write(folder / 'query_output.json', result.stdout.encode())
    if result.returncode:
        raise ExtractionError('Falló la conciliación raw: ' + (result.stdout + result.stderr)[-1000:])
    metadata = subprocess.run(['bq', f'--project_id={project}', f'--location={location}',
                               'show', '--job=true', '--format=json', job_id],
                              capture_output=True, text=True)
    if metadata.returncode:
        raise ExtractionError('No se pudo guardar la evidencia del job de verificación.')
    atomic_write(folder / 'query_job.json', metadata.stdout.encode())
    actual = json.loads(result.stdout)
    pages = {(r['resource'], int(r['page_number'])): r for r in actual if r['kind'] == 'page'}
    expected = {(r['resource'], p['page_number']): p['rows']
                for r in manifest['resources'] for p in r['pages']}
    checks = []
    now = utc_now()

    def check(resource: str, name: str, expected_count: int, actual_count: int) -> None:
        """Create auditable raw reconciliation evidence, including failed checks."""
        checks.append(dict(checked_at=now, run_id=run_id, resource=resource,
                           check_name=name, check_status='PASS' if expected_count == actual_count else 'FAIL',
                           expected_count=expected_count, actual_count=actual_count,
                           difference_count=actual_count-expected_count,
                           details={'query_job_id': job_id}))

    check('all', 'bigquery_page_inventory', 0, len(set(pages) ^ set(expected)))
    for resource in manifest['resources']:
        name = resource['resource']
        selected = [r for (res, _), r in pages.items() if res == name]
        check(name, 'local_records_to_bigquery', resource['rows'], sum(int(r['row_count']) for r in selected))
        check(name, 'bigquery_page_counts', 0, sum(int(pages.get(key, {}).get('row_count', -1)) != count
              for key, count in expected.items() if key[0] == name))
        check(name, 'bigquery_duplicate_positions', 0, sum(int(r['row_count'])-int(r['positions']) for r in selected))
        check(name, 'bigquery_raw_metadata', 0, sum(int(r['invalid_metadata']) for r in selected))
        check(name, 'bigquery_non_finite_markers', resource['data_quality_issue_count'], sum(int(r['markers']) for r in selected))
    controls = {r['kind']: int(r['row_count']) for r in actual if r['kind'] != 'page'}
    for key, table in [('run_file', 'ingestion_runs'), ('error_file', 'ingestion_errors'),
                       ('reconciliation_file', 'reconciliations')]:
        artifact = manifest[key]
        check('all', 'bigquery_' + table + '_rows', artifact.get('rows', artifact.get('errors', 0)), controls[table])
    path = folder / 'reconciliations.ndjson.gz'
    atomic_write(path, gzip.compress((''.join(json.dumps(r) + '\n' for r in checks)).encode(), mtime=0))
    bq_load(path, 'reconciliations', SCHEMA_DIR / 'reconciliations_schema.json', location, project)
    failed = [r for r in checks if r['check_status'] != 'PASS']
    statistics = json.loads(metadata.stdout).get('statistics', {})
    query_statistics = statistics.get('query', {})
    report = dict(run_id=run_id, verified_at=now, status='FAILED' if failed else 'PASS',
                  rows=manifest['rows_prepared'], pages=len(expected), checks=len(checks),
                  failed_checks=failed, query_job_id=job_id,
                  query_statistics={key: query_statistics.get(key) for key in
                                    ('totalBytesProcessed', 'totalBytesBilled', 'totalSlotMs', 'cacheHit')})
    atomic_write(folder / 'report.json', json.dumps(report, indent=2).encode())
    emit('bigquery_raw_verification', **report)
    if failed:
        raise ExtractionError('La carga raw no concilia; consultar report.json.')


def main() -> int:
    """Run bounded remote reconciliation and persist results in raw controls."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('load_manifest', type=artifact_path)
    parser.add_argument('--project', default=PROJECT_ID)
    parser.add_argument('--location', required=True)
    parser.add_argument('--maximum-bytes-billed', type=int, default=1024**3)
    args = parser.parse_args()
    try:
        verify_raw(args.load_manifest, args.project, args.location, args.maximum_bytes_billed)
        return 0
    except Exception as exc:
        emit('bigquery_raw_verification_failed', error_class=type(exc).__name__, message=str(exc))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
