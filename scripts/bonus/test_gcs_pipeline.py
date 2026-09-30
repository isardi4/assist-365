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
    def __init__(self):
        self.objects = {}

    def request(self, url, method='GET', data=None):
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
    def setUp(self):
        self.backend = MemoryGCS()
        self.request = patch('scripts.shared.artifacts._request', self.backend.request)
        self.request.start()
        self.addCleanup(self.request.stop)
        self.run = artifact_path('gs://test-bucket/raw/test-run')

    def page(self):
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
        body, _ = self.page()
        checkpoint = load_or_create_manifest(self.run / 'manifest.json', 'test-run', self.run,
                                              ['productos'])
        self.assertEqual(checkpoint['resources']['productos']['rows_received'], 1)
        self.assertEqual(gzip.decompress((self.run / 'productos/page-000001.json.gz').read_bytes()), body)
        self.assertEqual(checkpoint['output_dir'], str(self.run))

    def test_pending_page_recovers_without_source_api_call(self):
        body, manifest = self.page()
        manifest['resources']['productos']['in_progress'] = {'page_number': 1, 'request_offset': 0}
        client = Mock()
        recovered, _ = fetch_and_save_page(client, '/productos', {}, self.run,
            self.run / 'manifest.json', manifest, 'productos', 1, {'request_offset': 0})
        self.assertEqual(recovered, body)
        client.get_json.assert_not_called()

    def test_prepare_reads_gcs_and_publishes_verified_gcs_files(self):
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
        first = self.run / 'manifest.json'
        atomic_write(first, b'{}')
        stale = self.run / 'manifest.json'
        stale.read_bytes()
        atomic_write(first, b'{"new":true}')
        with self.assertRaises(ExtractionError):
            atomic_write(stale, b'{"old":true}')

    def test_error_ledger_preserves_both_entries(self):
        path = self.run / 'errors.jsonl'
        append_error(path, {'error_class': 'First'})
        append_error(path, {'error_class': 'Second'})
        self.assertEqual([json.loads(line)['error_class'] for line in path.read_text().splitlines()],
                         ['First', 'Second'])

    def test_bigquery_uses_gcs_uri_and_persists_receipt_in_gcs(self):
        source = artifact_path('gs://test-bucket/bigquery-load/test-run/productos.ndjson.gz')
        source.write_bytes(gzip.compress(b'{"payload":{}}\n'))
        with patch('scripts.parte_02_carga_bigquery.load_bigquery.subprocess.run',
                   return_value=SimpleNamespace(returncode=0, stdout='', stderr='')) as command:
            bq_load(source, 'productos', SCHEMA_DIR / 'raw_records_schema.json', 'us-central1')
        self.assertEqual(command.call_args.args[0][-1], str(source))
        receipt = json.loads(source.with_name(source.name + '.bigquery-job.json').read_text())
        self.assertEqual(receipt['identity']['table'], 'productos')

    def test_migrated_snapshot_is_not_loaded_again(self):
        path = self.run / 'load_manifest.json'
        path.write_text(json.dumps({'run_id': 'test-run', 'remote_resource_migration': {
            'project': 'a365-de-ignacio', 'location': 'us-central1', 'job_id': 'existing'}}))
        with patch('scripts.parte_02_carga_bigquery.load_bigquery.bq_load') as load:
            load_run(path, 'us-central1')
        load.assert_not_called()


if __name__ == '__main__':
    unittest.main()
