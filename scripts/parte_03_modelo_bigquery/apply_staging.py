"""Apply verified raw batches incrementally to six physical business tables."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import uuid
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from scripts.shared.common import ExtractionError, atomic_write, emit
from scripts.shared.artifacts import artifact_path, gcs_root, open_gzip
from scripts.parte_01_extraccion.api.common import ssl_context
from scripts.parte_02_carga_bigquery.load_bigquery import verify_prepared_file

PROJECT = 'a365-de-ignacio'
ROOT = Path(__file__).resolve().parent
RESOURCES = {'polizas', 'siniestros', 'agencias', 'productos', 'tipo_cambio'}


def bq(args: list[str], location: str, sql: str | None = None) -> str:
    """Ejecuta un comando bq y devuelve su salida; envía el SQL por entrada estándar."""
    result = subprocess.run(['bq', f'--project_id={PROJECT}', f'--location={location}',
                             *args], input=sql, capture_output=True, text=True)
    if result.returncode:
        useful_error = '\n'.join(line for line in result.stderr.replace('\r', '\n').splitlines() if 'Waiting on ' not in line and 'Current status:' not in line)
        raise ExtractionError((result.stdout + useful_error)[-2500:])
    return result.stdout


def query(sql: str, location: str, job_id: str, parameters: list[str]) -> str:
    """Ejecuta SQL parametrizado con un límite de bytes facturados de 4 GiB."""
    return bq([f'--job_id={job_id}', 'query', '--use_legacy_sql=false',
               '--maximum_bytes_billed=4294967296', '--format=json', '--max_rows=1000',
               *[f'--parameter={p}' for p in parameters]], location, sql)


def metadata_api() -> object:
    """Crea un lector de metadatos BigQuery con la identidad activa de gcloud y TLS."""
    token = subprocess.run(['gcloud', 'auth', 'print-access-token'],
                           capture_output=True, text=True, check=True).stdout.strip()
    context = ssl_context()

    def api(path: str) -> dict:
        """Consulta la ruta de metadatos BigQuery recibida y devuelve su respuesta JSON."""
        request = urllib.request.Request(
            f'https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT}/' + path,
            headers={'Authorization': 'Bearer ' + token})
        try:
            with urllib.request.urlopen(request, timeout=30, context=context) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            raise ExtractionError(exc.read().decode()[:1000]) from None
    return api


def inspect_layout(evidence: Path, require_clean: bool = False) -> list[dict]:
    """Verifica las tablas y campos de staging y guarda su inventario físico."""
    api = metadata_api()
    inventory = []
    expected = set(json.loads((ROOT / 'silver_schema.json').read_text()))
    tables = api('datasets/assist365_staging/tables?maxResults=1000').get('tables', [])
    if require_clean and {t['tableReference']['tableId'] for t in tables} != expected:
        raise ExtractionError('Staging no contiene exactamente las seis tablas acordadas.')
    for table in tables:
        name = table['tableReference']['tableId']
        if name not in expected:
            continue
        meta = api(f'datasets/assist365_staging/tables/{name}')
        fields = meta['schema']['fields']
        expected_fields = json.loads((ROOT / 'silver_schema.json').read_text())[name]['fields']
        if meta['type'] != 'TABLE' or [(f['name'], f['type']) for f in fields] != [tuple(x) for x in expected_fields]:
            # BigQuery reports BOOL as BOOLEAN.
            actual = [(f['name'], {'BOOLEAN': 'BOOL'}.get(f['type'], f['type'])) for f in fields]
            if meta['type'] != 'TABLE' or actual != [tuple(x) for x in expected_fields]:
                raise ExtractionError(f'Esquema inesperado en {name}.')
        if len(meta.get('description', '')) < 200 or any(len(f.get('description', '')) < 40 for f in fields):
            raise ExtractionError(f'Descripciones incompletas en {name}.')
        inventory.append({'table': name, 'rows': int(meta.get('numRows', 0)),
                          'logical_bytes': int(meta.get('numBytes', 0)),
                          'partition': meta.get('timePartitioning'),
                          'clustering': meta.get('clustering'), 'fields': [f['name'] for f in fields]})
    if len(inventory) != len(expected):
        raise ExtractionError('Faltan tablas físicas de silver.')
    atomic_write(evidence / 'inventory.json', json.dumps(inventory, indent=2).encode())
    return inventory


def source_parameters(manifest_path: Path, selected: list[str]) -> tuple[dict, list[str]]:
    """Valida los archivos y obtiene fechas y conteos para limitar la lectura de raw."""
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('source_run_status') not in {'SUCCESS', 'SUCCESS_WITH_QUARANTINE'}:
        raise ExtractionError('La captura de origen no está completa.')
    if not selected or not set(selected) <= RESOURCES:
        raise ExtractionError('Lista de recursos inválida.')
    dates = set()
    counts = {}
    for resource in manifest['resources']:
        name = resource['resource']
        if name not in selected:
            continue
        path = artifact_path(resource['load_file'])
        verify_prepared_file(path, resource)
        count = 0
        with open_gzip(path, 'rt') as stream:
            for line in stream:
                row = json.loads(line)
                if row['run_id'] != manifest['run_id'] or row['resource'] != name:
                    raise ExtractionError('El archivo contiene otra corrida o recurso.')
                dates.add(row['ingested_at'][:10])
                count += 1
        if count != resource['rows']:
            raise ExtractionError(f'Conteo de archivo inválido: {name}.')
        counts[name] = count
    if set(counts) != set(selected):
        raise ExtractionError('Faltan recursos o particiones para la carga.')
    run_path = artifact_path(manifest['run_file']['load_file'])
    verify_prepared_file(run_path, manifest['run_file'])
    with open_gzip(run_path, 'rt') as source:
        run = json.loads(next(source))
    source_day = run['started_at'][:10]
    if not dates:
        dates.add(source_day)
    parameters = [f"run_id:STRING:{manifest['run_id']}",
                  f'from_date:DATE:{min(dates)}', f'to_date:DATE:{max(dates)}',
                  f'source_from_date:DATE:{source_day}', f'source_to_date:DATE:{source_day}',
                  'resources:ARRAY<STRING>:' + json.dumps(selected)]
    parameters += [f'{name}_rows:INT64:{counts.get(name, 0)}' for name in sorted(RESOURCES)]
    identity = {r['resource']: {'rows': r['rows'], 'sha256': r['compressed_sha256']} for r in manifest['resources'] if r['resource'] in selected}
    identity['model_sql_sha256'] = hashlib.sha256((ROOT / 'sql/011_incremental_silver.sql').read_bytes()).hexdigest()
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    parameters.append(f'batch_fingerprint:STRING:{fingerprint}')
    return manifest, parameters


def apply(manifest_path: Path, location: str, resources: list[str], cleanup: bool = False, replay: bool = False) -> None:
    """Aplica el lote con MERGE transaccional y registra controles, checkpoints y fallas."""
    resources = sorted(set(resources))
    manifest, parameters = source_parameters(manifest_path, resources)
    run_id = manifest['run_id']
    if not re.fullmatch(r'[A-Za-z0-9_-]+', run_id):
        raise ExtractionError('run_id inválido.')
    attempt = 'assist365_silver_' + uuid.uuid4().hex
    evidence = artifact_path(gcs_root()) / 'silver' / run_id / attempt
    evidence.mkdir(parents=True, exist_ok=True)
    ddl_job = attempt + '_ddl'
    query((ROOT / 'sql/010_silver_tables.sql').read_text(), location, ddl_job, [])
    if not replay and not cleanup:
        skip_sql = f"""SELECT COUNT(*) processed FROM `{PROJECT}.assist365_control.silver_runs`
        WHERE DATE(started_at)>=DATE '1970-01-01' AND run_id=@run_id AND run_status='SUCCESS'
        AND TO_JSON_STRING(resources)=TO_JSON_STRING(TO_JSON(@resources))
        AND JSON_VALUE(summary,'$.batch_fingerprint')=@batch_fingerprint"""
        previous = json.loads(query(skip_sql, location, attempt+'_lookup', parameters))
        if int(previous[0]['processed']):
            emit('silver_batch_already_processed', run_id=run_id, resources=resources)
            return
    parameters.append(f'job_id:STRING:{attempt}')
    emit('silver_batch_started', run_id=run_id, job_id=attempt, resources=resources)
    sql = (ROOT / 'sql/011_incremental_silver.sql').read_text()
    atomic_write(evidence / 'executed.sql', sql.encode())
    try:
        output = query(sql, location, attempt, parameters)
        atomic_write(evidence / 'output.json', output.encode())
    except Exception as exc:
        message = str(exc)
        atomic_write(evidence / 'failure.txt', message.encode())
        failure_sql = f'''MERGE `{PROJECT}.assist365_control.silver_runs` t
        USING (SELECT @run_id run_id, @job_id job_id) s
        ON t.job_id=s.job_id AND DATE(t.started_at)>=DATE '1970-01-01'
        WHEN MATCHED THEN UPDATE SET run_status='FAILED',finished_at=CURRENT_TIMESTAMP(),error_message=@error
        WHEN NOT MATCHED THEN INSERT(run_id,job_id,started_at,finished_at,run_status,error_message)
        VALUES(s.run_id,s.job_id,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP(),'FAILED',@error);'''
        query(failure_sql, location, attempt + '_failure',
              [f'run_id:STRING:{run_id}', f'job_id:STRING:{attempt}', f'error:STRING:{message[:1000]}'])
        raise
    metadata = bq(['show', '--job=true', '--format=json', attempt], location)
    atomic_write(evidence / 'job.json', metadata.encode())
    inventory = inspect_layout(evidence)
    if cleanup:
        query((ROOT / 'sql/020_retire_legacy_staging.sql').read_text(), location, attempt+'_cleanup', [])
        inventory = inspect_layout(evidence, require_clean=True)
    result = {'run_id': run_id, 'job_id': attempt, 'status': 'SUCCESS',
              'resources': resources, 'tables': inventory,
              'processed_bytes': json.loads(metadata)['statistics'].get('totalBytesProcessed'),
              'evidence': str(evidence)}
    atomic_write(evidence / 'report.json', json.dumps(result, indent=2).encode())
    emit('silver_batch_complete', run_id=run_id, job_id=attempt,
         tables={t['table']: t['rows'] for t in inventory}, evidence=str(evidence))


def main() -> int:
    """Procesa todos los recursos o un delta validado de pólizas sin consultar la API."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('load_manifest', type=artifact_path, nargs='?', default=None)
    parser.add_argument('--location', default='us-central1')
    parser.add_argument('--resources', nargs='+', default=sorted(RESOURCES))
    parser.add_argument('--retire-legacy', action='store_true')
    parser.add_argument('--replay', action='store_true', help='Reprocesar incluso un lote ya confirmado.')
    args = parser.parse_args()
    try:
        apply(args.load_manifest or artifact_path(gcs_root()) / "bigquery-load/smoke-20260929/load_manifest.json", args.location, args.resources, args.retire_legacy, args.replay)
        return 0
    except Exception as exc:
        emit('silver_batch_failed', error_class=type(exc).__name__, message=str(exc))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
