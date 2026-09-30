"""Exercise the extractor CLI with cursor/offset fixtures and no source-network access."""
import gzip
import io
import json
import sys
import unittest
from unittest.mock import patch

from scripts.bonus.test_gcs_pipeline import MemoryGCS
from scripts.shared.artifacts import artifact_path
from scripts.parte_01_extraccion.extractor.cli import main
from scripts.parte_01_extraccion.api.client import ApiClient


class FixtureClient:
    def __init__(self, *args):
        self.request_count = 0
        self.retry_count = 0
        self.calls = []

    def get_json(self, endpoint, params):
        self.request_count += 1
        self.calls.append((endpoint, params))
        if endpoint == 'catalogos':
            payload = {'data': [{'resource': params['tipo']}]}
        elif endpoint == 'polizas':
            first = not params.get('cursor')
            payload = {'data': [{'poliza_id': 'P1', 'op': 'I' if first else 'U'}],
                       'pagination': {'has_more': first, 'next_cursor': 'cursor-1' if first else None}}
        else:
            offset = params['offset']
            payload = {'data': [{'claim_id': f'S{i}'} for i in range(offset, min(offset+500, 501))],
                       'meta': {'offset': offset, 'limit': 500, 'total': 501}}
        return json.dumps(payload).encode(), {}, 200


class ExtractorTests(unittest.TestCase):
    def test_full_cli_writes_gcs_and_complete_resume_does_not_call_api(self):
        storage = MemoryGCS()
        client = FixtureClient()
        argv = ['extractor', '--full', '--run-id', 'fixture', '--output-dir', 'gs://test-bucket/raw']
        with patch.object(sys, 'argv', argv), \
             patch('scripts.shared.artifacts._request', storage.request), \
             patch('scripts.parte_01_extraccion.extractor.cli.ApiClient', return_value=client) as factory, \
             patch('scripts.parte_01_extraccion.extractor.cli.read_token', return_value='fixture'), \
             patch('urllib.request.urlopen', side_effect=AssertionError('Source network prohibited')):
            self.assertEqual(main(), 0)
            manifest = artifact_path('gs://test-bucket/raw/fixture/manifest.json')
            first = manifest.read_bytes()
            self.assertEqual(main(), 0)
            self.assertEqual(manifest.read_bytes(), first)
            factory.assert_called_once()
        data = json.loads(first)
        self.assertEqual(data['run_status'], 'SUCCESS')
        self.assertEqual(data['http_requests'], 7)
        self.assertEqual(data['resources']['polizas']['rows_received'], 2)
        self.assertEqual(data['resources']['siniestros']['rows_received'], 501)
        self.assertIn(('polizas', {'cursor': 'cursor-1'}), client.calls)
        self.assertEqual([p['offset'] for e,p in client.calls if e == 'siniestros'], [0, 500])

    def test_http_client_decodes_gzip_with_fixture_response(self):
        body = b'{"data":[]}'
        response = io.BytesIO(gzip.compress(body))
        response.headers = {'Content-Encoding': 'gzip'}
        response.status = 200
        with patch('urllib.request.urlopen', return_value=response):
            actual, _, code = ApiClient('fixture', 0, 1).get_json('polizas', {})
        self.assertEqual((actual, code), (body, 200))


if __name__ == '__main__':
    unittest.main()
