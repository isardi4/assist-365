"""Artifact paths backed by local files or Cloud Storage using Google Cloud CLI identity."""
from __future__ import annotations

import gzip
import io
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from types import SimpleNamespace

from .common import ExtractionError

REPOSITORY = Path(__file__).resolve().parents[2]
_token = None
_token_at = 0.0
_context = None


def gcs_root() -> str:
    config = json.loads((REPOSITORY / 'config/assist365.json').read_text())
    uri = os.environ.get('ASSIST365_GCS_ROOT', config.get('gcs_root', ''))
    if not uri.startswith('gs://'):
        raise ExtractionError('Configurá gcs_root o ASSIST365_GCS_ROOT con una ruta gs://.')
    return uri.rstrip('/')


def _request(url: str, method: str = 'GET', data: bytes | None = None):
    global _token, _token_at, _context
    if _context is None:
        from scripts.parte_01_extraccion.api.common import ssl_context
        _context = ssl_context()
    for attempt in range(4):
        if _token is None or time.monotonic() - _token_at > 2700:
            try:
                result = subprocess.run(['gcloud', 'auth', 'print-access-token'],
                                        capture_output=True, text=True, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                raise ExtractionError('No se pudo obtener la identidad gcloud para GCS.') from None
            if result.returncode or not result.stdout.strip():
                raise ExtractionError('Autenticá Google Cloud CLI para acceder a GCS.')
            _token, _token_at = result.stdout.strip(), time.monotonic()
        request = urllib.request.Request(url, data=data, method=method,
                                         headers={'Authorization': 'Bearer ' + _token,
                                                  'Content-Type': 'application/octet-stream'})
        try:
            return urllib.request.urlopen(request, timeout=120, context=_context)
        except urllib.error.HTTPError as error:
            code = error.code
            error.close()
            if code == 401 and attempt < 3:
                _token = None
                continue
            if code == 404:
                raise FileNotFoundError('Objeto GCS no encontrado.') from None
            if code == 412:
                raise ExtractionError('El objeto GCS cambió durante la operación; reanudá la corrida.') from None
            if code in {429, 500, 502, 503, 504} and attempt < 3:
                time.sleep(2 ** attempt)
                continue
            raise ExtractionError(f'Falló la operación GCS (HTTP {code}); revisá bucket e IAM.') from None
        except (OSError, urllib.error.URLError):
            if method != 'GET' or attempt == 3:
                raise ExtractionError('Falló la conexión con GCS; reanudá desde el checkpoint.') from None
            time.sleep(2 ** attempt)
    raise ExtractionError('No se pudo completar la operación GCS.')


class GCSPath:
    """Minimal Path interface; writes use object-generation preconditions."""
    def __init__(self, value: str):
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme != 'gs' or not re.fullmatch(r'[a-z0-9][a-z0-9._-]+', parsed.netloc):
            raise ExtractionError('Ruta GCS inválida.')
        if parsed.query or parsed.fragment:
            raise ExtractionError('Las rutas GCS no admiten query ni fragmento.')
        self.bucket = parsed.netloc
        self.key = parsed.path.lstrip('/').rstrip('/')
        if '..' in PurePosixPath(self.key).parts:
            raise ExtractionError('La ruta GCS no admite segmentos .. .')
        self._checked = False
        self._meta = None

    def __str__(self):
        return 'gs://' + self.bucket + ('/' + self.key if self.key else '')

    def __truediv__(self, value):
        value = str(value)
        if value.startswith('/') or '..' in PurePosixPath(value).parts or '://' in value:
            raise ExtractionError('La ruta de artefacto debe ser relativa.')
        return GCSPath(str(self).rstrip('/') + '/' + value)

    @property
    def name(self):
        return PurePosixPath(self.key).name

    @property
    def stem(self):
        return PurePosixPath(self.key).stem

    @property
    def suffix(self):
        return PurePosixPath(self.key).suffix

    @property
    def parent(self):
        parent = str(PurePosixPath(self.key).parent)
        return GCSPath('gs://' + self.bucket + ('/' + parent if parent != '.' else ''))

    def with_name(self, value):
        return self.parent / value

    def relative_to(self, other):
        other = artifact_path(other)
        if not isinstance(other, GCSPath) or other.bucket != self.bucket:
            raise ExtractionError('El artefacto está fuera del bucket de la corrida.')
        return PurePosixPath(self.key).relative_to(PurePosixPath(other.key))

    def mkdir(self, **kwargs):
        pass  # GCS prefixes do not need directory objects.

    def metadata(self):
        if not self._checked:
            url = 'https://storage.googleapis.com/storage/v1/b/' + self.bucket + '/o/'
            try:
                with _request(url + urllib.parse.quote(self.key, safe='')) as response:
                    self._meta = json.load(response)
            except FileNotFoundError:
                self._meta = None
            self._checked = True
        return self._meta

    def exists(self):
        return self.metadata() is not None

    def is_file(self):
        return self.exists()

    def stat(self):
        meta = self.metadata()
        if meta is None:
            raise FileNotFoundError(str(self))
        return SimpleNamespace(st_size=int(meta['size']))

    def open(self, mode='rb', encoding='utf-8'):
        if mode not in {'rb', 'r', 'rt'}:
            raise ExtractionError('Usá atomic_write o append_bytes para escribir en GCS.')
        meta = self.metadata()
        if meta is None:
            raise FileNotFoundError(str(self))
        url = ('https://storage.googleapis.com/storage/v1/b/' + self.bucket + '/o/'
               + urllib.parse.quote(self.key, safe='') + '?alt=media&generation=' + meta['generation'])
        stream = _request(url)
        return stream if mode == 'rb' else io.TextIOWrapper(stream, encoding=encoding)

    def read_bytes(self):
        with self.open('rb') as source:
            return source.read()

    def read_text(self, encoding='utf-8'):
        return self.read_bytes().decode(encoding)

    def write_bytes(self, data):
        meta = self.metadata()
        generation = meta['generation'] if meta else '0'
        query = urllib.parse.urlencode({'uploadType': 'media', 'name': self.key,
                                       'ifGenerationMatch': generation})
        url = 'https://storage.googleapis.com/upload/storage/v1/b/' + self.bucket + '/o?' + query
        with _request(url, 'POST', data) as response:
            self._meta = json.load(response)
        self._checked = True
        return len(data)

    def write_text(self, text, encoding='utf-8'):
        return self.write_bytes(text.encode(encoding))


def artifact_path(value):
    if isinstance(value, (Path, GCSPath)):
        return value
    return GCSPath(str(value)) if str(value).startswith('gs://') else Path(value)


@contextmanager
def open_gzip(path, mode='rt'):
    with artifact_path(path).open('rb') as raw:
        with gzip.open(raw, mode, encoding='utf-8' if 't' in mode else None) as stream:
            yield stream


def publish_file(temporary: str, destination):
    """Publish an ephemeral preparation file; only GCS is durable in cloud mode."""
    destination = artifact_path(destination)
    if isinstance(destination, GCSPath):
        try:
            destination.write_bytes(Path(temporary).read_bytes())
        finally:
            Path(temporary).unlink(missing_ok=True)
    else:
        os.replace(temporary, destination)


def append_bytes(path, data: bytes):
    path = artifact_path(path)
    if isinstance(path, GCSPath):
        path.write_bytes((path.read_bytes() if path.exists() else b'') + data)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('ab') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
