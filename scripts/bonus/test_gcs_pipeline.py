"""Offline checks for GCS checkpoints, preparation, integrity and BigQuery source URIs."""
import gzip
import io
import json
import unittest
import urllib.parse
from types import SimpleNamespace
from unittest.mock import Mock, patch

from scripts.shared.artifacts import artifact_path
from scripts.shared.common import ExtractionError, atomic_write
from scripts.parte_01_extraccion.extractor.storage import (
    initial_manifest, save_manifest, load_or_create_manifest, write_raw_page,
    persist_page, commit_page, fetch_and_save_page, append_error,
)
from scripts.parte_02_carga_bigquery.prepare_load import prepare_run
from scripts.parte_02_carga_bigquery.load_bigquery import (
    bq_load, load_run, verify_prepared_file, SCHEMA_DIR,
)


class MemoryGCS:
    """Simula objetos GCS y sus generaciones en memoria para probar sin conexión."""
    def __init__(self):
        """Crea el almacén vacío de objetos y generaciones simuladas."""
        self.objects = {}

    def request(self, url, method='GET', data=None):
        """Simula lecturas y escrituras GCS y rechaza conflictos de generación."""
        parsed = urllib.parse.urlsplit(url)
        params = urllib.parse.parse_qs(parsed.query)
        if method == 'POST':
            key = params['name'][0]
            existing = self.objects.get(key)
            generation = existing[0] if existing else 0
            if int(params['ifGenerationMatch'][0]) != generation:
                raise ExtractionError('Generation conflict')
            self.objects[key] = (generation + 1, data)
        else:
            key = urllib.parse.unquote(parsed.path.split('/o/', 1)[1])
            if key not in self.objects:
                raise FileNotFoundError(key)
        generation, payload = self.objects[key]
        if params.get('alt') == ['media']:
            if int(params['generation'][0]) != generation:
                raise ExtractionError('Generation conflict')
            return io.BytesIO(payload)
        return io.BytesIO(json.dumps({'generation': str(generation),
                                     'size': str(len(payload))}).encode())


class GCSPipelineTests(unittest.TestCase):
    """Prueba almacenamiento, preparación y repetición de cargas con GCS simulado."""
    def setUp(self):
        """Prepara un bucket simulado y sustituye las solicitudes GCS para cada prueba."""
        self.backend = MemoryGCS()
        self.request = patch('scripts.shared.artifacts._request', self.backend.request)
        self.request.start()
        self.addCleanup(self.request.stop)
        self.run = artifact_path('gs://test-bucket/raw/test-run')

    def page(self):
        """Crea una página raw y su checkpoint para las pruebas de carga."""
        body = json.dumps({'data': [{'producto_id': 1, 'tipo': 'Premium'}]}).encode()
        manifest = initial_manifest('test-run', self.run, ['productos'])
        path = write_raw_page(body, self.run, 'productos', 1)
        page, invalid = persist_page(body, json.loads(body), path, self.run,
                                     manifest, 'productos', 1, {})
        commit_page(page, invalid, self.run / 'errors.jsonl', self.run / 'manifest.json',
                    manifest, 'productos')
        manifest.update(run_status='SUCCESS', finished_at=manifest['created_at'])
        for state in manifest['resources'].values():
            state.update(complete=True, status='SUCCESS')
        save_manifest(self.run / 'manifest.json', manifest)
        return body, manifest

    def test_page_and_manifest_round_trip_without_local_directory(self):
        """Comprueba que páginas y manifiestos se guarden y lean sin directorios locales."""
        body, _ = self.page()
        checkpoint = load_or_create_manifest(self.run / 'manifest.json', 'test-run', self.run,
                                              ['productos'])
        self.assertEqual(checkpoint['resources']['productos']['rows_received'], 1)
        self.assertEqual(gzip.decompress((self.run / 'productos/page-000001.json.gz').read_bytes()), body)
        self.assertEqual(checkpoint['output_dir'], str(self.run))

    def test_pending_page_recovers_without_source_api_call(self):
        """Comprueba que una página pendiente se recupere desde GCS sin consultar la API."""
        body, manifest = self.page()
        manifest['resources']['productos']['in_progress'] = {'page_number': 1, 'request_offset': 0}
        client = Mock()
        recovered, _ = fetch_and_save_page(client, '/productos', {}, self.run,
            self.run / 'manifest.json', manifest, 'productos', 1, {'request_offset': 0})
        self.assertEqual(recovered, body)
        client.get_json.assert_not_called()

    def test_prepare_reads_gcs_and_publishes_verified_gcs_files(self):
        """Comprueba que la preparación lea GCS y publique archivos con huellas verificables."""
        self.page()
        manifest_path = prepare_run(self.run, artifact_path('gs://test-bucket/bigquery-load'))
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest['rows_prepared'], 1)
        for item in manifest['resources']:
            self.assertTrue(item['load_file'].startswith('gs://'))
            verify_prepared_file(artifact_path(item['load_file']), item)
        product = next(item for item in manifest['resources'] if item['resource'] == 'productos')
        row = json.loads(gzip.decompress(artifact_path(product['load_file']).read_bytes()))
        self.assertEqual(row['payload']['tipo'], 'Premium')
        item = artifact_path(product['load_file'])
        item.write_bytes(b'corrupt')
        with self.assertRaises(ExtractionError):
            verify_prepared_file(artifact_path(product['load_file']), product)

    def test_stale_manifest_cannot_overwrite_a_newer_checkpoint(self):
        """Comprueba que un manifiesto antiguo no sobrescriba un checkpoint más reciente."""
        first = self.run / 'manifest.json'
        atomic_write(first, b'{}')
        stale = self.run / 'manifest.json'
        stale.read_bytes()
        atomic_write(first, b'{"new":true}')
        with self.assertRaises(ExtractionError):
            atomic_write(stale, b'{"old":true}')

    def test_error_ledger_preserves_both_entries(self):
        """Comprueba que agregar un error conserve también los errores anteriores."""
        path = self.run / 'errors.jsonl'
        append_error(path, {'error_class': 'First'})
        append_error(path, {'error_class': 'Second'})
        self.assertEqual([json.loads(line)['error_class'] for line in path.read_text().splitlines()],
                         ['First', 'Second'])

    def test_bigquery_uses_gcs_uri_and_persists_receipt_in_gcs(self):
        """Comprueba que bq use la URI GCS y que el recibo de carga quede en el bucket."""
        source = artifact_path('gs://test-bucket/bigquery-load/test-run/productos.ndjson.gz')
        source.write_bytes(gzip.compress(b'{"payload":{}}\n'))
        with patch('scripts.parte_02_carga_bigquery.load_bigquery.subprocess.run',
                   return_value=SimpleNamespace(returncode=0, stdout='', stderr='')) as command:
            bq_load(source, 'productos', SCHEMA_DIR / 'raw_records_schema.json', 'us-central1')
        self.assertEqual(command.call_args.args[0][-1], str(source))
        receipt = json.loads(source.with_name(source.name + '.bigquery-job.json').read_text())
        self.assertEqual(receipt['identity']['table'], 'productos')

    def migrated(self):
        """Prepara un lote simulado con una confirmación de migración raw existente."""
        self.page()
        path = prepare_run(self.run, artifact_path('gs://test-bucket/bigquery-load'))
        manifest = json.loads(path.read_text())
        manifest['remote_resource_migration'] = {
            'project': 'a365-de-ignacio', 'location': 'us-central1',
            'job_id': 'existing', 'status': 'PASS'}
        path.write_text(json.dumps(manifest))
        return path, manifest

    def test_migrated_snapshot_is_not_loaded_again(self):
        """Comprueba que el lote migrado se valide por conteos sin volver a cargarlo."""
        path, manifest = self.migrated()
        counts = [{'resource': r['resource'], 'row_count': r['rows']} for r in manifest['resources']]
        with patch('scripts.parte_02_carga_bigquery.load_bigquery.bq_load') as load, \
             patch('scripts.parte_02_carga_bigquery.load_bigquery.shutil.which', return_value='bq'), \
             patch('scripts.parte_02_carga_bigquery.load_bigquery.subprocess.run',
                   return_value=SimpleNamespace(returncode=0, stdout=json.dumps(counts))):
            load_run(path, 'us-central1')
        load.assert_not_called()

    def test_migration_confirmation_rejects_missing_destination_rows(self):
        """Comprueba que se rechace una migración confirmada si faltan filas en destino."""
        path, _ = self.migrated()
        with patch('scripts.parte_02_carga_bigquery.load_bigquery.shutil.which', return_value='bq'), \
             patch('scripts.parte_02_carga_bigquery.load_bigquery.subprocess.run',
                   return_value=SimpleNamespace(returncode=0, stdout='[]')):
            with self.assertRaisesRegex(ExtractionError, 'no coincide'):
                load_run(path, 'us-central1')

    def test_preparation_reuses_manifest_without_overwriting_receipts(self):
        """Comprueba que repetir la preparación conserve objetos, manifiesto y recibos."""
        path, _ = self.migrated()
        before = self.backend.objects.copy()
        reused = prepare_run(self.run, artifact_path('gs://test-bucket/bigquery-load'))
        self.assertEqual(str(path), str(reused))
        self.assertEqual(self.backend.objects, before)

    def test_preparation_rejects_changed_source_with_same_run_id(self):
        """Comprueba que se rechace una captura modificada con el mismo identificador de lote."""
        _, _ = self.migrated()
        path = self.run / 'manifest.json'
        source = json.loads(path.read_text())
        source['resources']['productos']['pages'][0]['response_sha256'] = 'changed'
        path.write_text(json.dumps(source))
        before = self.backend.objects.copy()
        with self.assertRaisesRegex(ExtractionError, 'Cambió la captura'):
            prepare_run(self.run, artifact_path('gs://test-bucket/bigquery-load'))
        self.assertEqual(self.backend.objects, before)

    def test_raw_verifier_publishes_gzip_report_without_an_error_ledger(self):
        """Comprueba que se publique el reporte gzip aunque no exista un archivo de errores."""
        from scripts.parte_02_carga_bigquery.verify_raw import verify_raw
        self.page()
        path = prepare_run(self.run, artifact_path('gs://test-bucket/bigquery-load'))
        manifest = json.loads(path.read_text())
        records = [{'kind': 'page', 'resource': 'productos', 'page_number': 1,
                    'row_count': 1, 'positions': 1, 'invalid_metadata': 0, 'markers': 0}]
        records += [{'kind': name, 'row_count': count} for name,count in [
            ('ingestion_runs', 1), ('ingestion_errors', 0),
            ('reconciliations', manifest['reconciliation_file']['rows'])]]
        def command(args, **kwargs):
            """Simula las respuestas de bq necesarias para probar la verificación raw sin conexión."""
            output = '{}' if 'show' in args else '' if '--dry_run' in args else json.dumps(records)
            return SimpleNamespace(returncode=0, stdout=output, stderr='')
        with patch('scripts.parte_02_carga_bigquery.verify_raw.subprocess.run', side_effect=command), \
             patch('scripts.parte_02_carga_bigquery.verify_raw.bq_load'):
            verify_raw(path, 'a365-de-ignacio', 'us-central1', 1024**3)
        folder = path.parent / 'remote-verification'
        report = json.loads((folder / 'report.json').read_text())
        self.assertEqual(report['status'], 'PASS')
        self.assertEqual(len(gzip.decompress((folder / 'reconciliations.ndjson.gz').read_bytes()).splitlines()), 29)


if __name__ == '__main__':
    unittest.main()
