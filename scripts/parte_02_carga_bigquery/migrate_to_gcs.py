"""Copy an existing local snapshot to GCS and rebase its manifests without API calls."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import urllib.parse
from pathlib import Path

from scripts.shared.artifacts import GCSPath, _request, artifact_path, gcs_root
from scripts.shared.common import ExtractionError, atomic_write, emit


def inventory(prefix: GCSPath) -> dict:
    objects = {}
    token = None
    while True:
        parameters = {'prefix': prefix.key + '/', 'maxResults': 1000}
        if token:
            parameters['pageToken'] = token
        url = ('https://storage.googleapis.com/storage/v1/b/' + prefix.bucket + '/o?'
               + urllib.parse.urlencode(parameters))
        with _request(url) as response:
            page = json.load(response)
        objects.update({item['name']: item for item in page.get('items', [])})
        token = page.get('nextPageToken')
        if not token:
            return objects


def migrate(raw: Path, prepared: Path, destination: GCSPath, upload: bool = True) -> dict:
    raw_manifest = json.loads((raw / 'manifest.json').read_text())
    load_manifest = json.loads((prepared / 'load_manifest.json').read_text())
    run_id = raw_manifest['run_id']
    if load_manifest['run_id'] != run_id or raw.name != run_id or prepared.name != run_id:
        raise ExtractionError('Los directorios y manifiestos deben identificar la misma corrida.')
    roots = [(raw, destination / 'raw' / run_id),
             (prepared, destination / 'bigquery-load' / run_id)]
    if upload:
        for local, cloud in roots:
            subprocess.run(['gcloud', 'storage', 'cp', '--recursive', str(local),
                            str(cloud.parent) + '/', '--quiet'], check=True)
    verified = 0
    for local, cloud in roots:
        objects = inventory(cloud)
        for file in local.rglob('*'):
            if not file.is_file():
                continue
            # These two objects are rebased below; subsequent migrations remain resumable.
            if file in {raw / 'manifest.json', prepared / 'load_manifest.json'}:
                continue
            key = cloud.key + '/' + file.relative_to(local).as_posix()
            item = objects.get(key, {})
            digest = base64.b64encode(hashlib.md5(file.read_bytes()).digest()).decode()
            if int(item.get('size', -1)) != file.stat().st_size or item.get('md5Hash') != digest:
                raise ExtractionError(f'No coincide la copia GCS: {key}')
            verified += 1
    raw_cloud, prepared_cloud = roots[0][1], roots[1][1]
    raw_manifest['output_dir'] = str(raw_cloud)
    load_manifest['source_manifest'] = str(raw_cloud / 'manifest.json')
    artifacts = list(load_manifest['resources'])
    artifacts += [load_manifest[key] for key in ('run_file', 'reconciliation_file', 'error_file')
                  if load_manifest.get(key)]
    for item in artifacts:
        # Only the location changes: fingerprints and prior load receipts are preserved.
        item['load_file'] = str(prepared_cloud / Path(item['load_file']).name)
    for path, manifest in [(raw_cloud / 'manifest.json', raw_manifest),
                           (prepared_cloud / 'load_manifest.json', load_manifest)]:
        atomic_write(path, (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode())
    report = {'run_id': run_id, 'verified_files': verified,
              'raw': str(raw_cloud), 'load_manifest': str(prepared_cloud / 'load_manifest.json'),
              'rows': load_manifest['rows_prepared'], 'source_api_calls': 0}
    atomic_write(prepared_cloud / 'gcs_migration.json', json.dumps(report, indent=2).encode())
    emit('gcs_migration_complete', **report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('raw', type=Path)
    parser.add_argument('prepared', type=Path)
    parser.add_argument('--gcs-root', type=artifact_path, default=None)
    parser.add_argument('--already-uploaded', action='store_true')
    args = parser.parse_args()
    destination = args.gcs_root or artifact_path(gcs_root())
    if not isinstance(destination, GCSPath):
        parser.error('--gcs-root debe ser una ruta gs://.')
    migrate(args.raw, args.prepared, destination, not args.already_uploaded)
