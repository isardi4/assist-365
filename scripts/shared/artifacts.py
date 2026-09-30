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
    """Obtiene la ruta base de GCS desde la configuración o la variable de entorno."""
    config = json.loads((REPOSITORY / 'config/assist365.json').read_text())
    uri = os.environ.get('ASSIST365_GCS_ROOT', config.get('gcs_root', ''))
    if not uri.startswith('gs://'):
        raise ExtractionError('Configurá gcs_root o ASSIST365_GCS_ROOT con una ruta gs://.')
    return uri.rstrip('/')


def _request(url: str, method: str = 'GET', data: bytes | None = None):
    """Hace una petición autenticada a GCS y reintenta los errores transitorios."""
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
    """Representa una ruta GCS y evita sobrescribir cambios concurrentes al guardar."""
    def __init__(self, value: str):
        """Valida la ruta GCS y guarda el bucket y la clave del objeto."""
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
        """Devuelve la ruta completa del objeto con el prefijo gs://."""
        return 'gs://' + self.bucket + ('/' + self.key if self.key else '')

    def __truediv__(self, value):
        """Agrega un segmento relativo a la ruta, rechazando rutas externas."""
        value = str(value)
        if value.startswith('/') or '..' in PurePosixPath(value).parts or '://' in value:
            raise ExtractionError('La ruta de artefacto debe ser relativa.')
        return GCSPath(str(self).rstrip('/') + '/' + value)

    @property
    def name(self):
        """Devuelve el nombre del objeto, incluida su extensión."""
        return PurePosixPath(self.key).name

    @property
    def stem(self):
        """Devuelve el nombre del objeto sin su última extensión."""
        return PurePosixPath(self.key).stem

    @property
    def suffix(self):
        """Devuelve la última extensión del nombre del objeto."""
        return PurePosixPath(self.key).suffix

    @property
    def parent(self):
        """Devuelve el prefijo padre del objeto dentro del mismo bucket."""
        parent = str(PurePosixPath(self.key).parent)
        return GCSPath('gs://' + self.bucket + ('/' + parent if parent != '.' else ''))

    def with_name(self, value):
        """Crea una ruta en el mismo prefijo con otro nombre de objeto."""
        return self.parent / value

    def relative_to(self, other):
        """Calcula la ruta relativa a otro prefijo del mismo bucket."""
        other = artifact_path(other)
        if not isinstance(other, GCSPath) or other.bucket != self.bucket:
            raise ExtractionError('El artefacto está fuera del bucket de la corrida.')
        return PurePosixPath(self.key).relative_to(PurePosixPath(other.key))

    def mkdir(self, **kwargs):
        """Mantiene la interfaz de Path; en GCS no hace falta crear directorios."""
        pass  # GCS prefixes do not need directory objects.

    def metadata(self):
        """Consulta y conserva los metadatos del objeto; devuelve None si no existe."""
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
        """Indica si el objeto existe en GCS según sus metadatos."""
        return self.metadata() is not None

    def is_file(self):
        """Indica si la ruta corresponde a un objeto existente en GCS."""
        return self.exists()

    def stat(self):
        """Devuelve el tamaño del objeto o falla si no existe."""
        meta = self.metadata()
        if meta is None:
            raise FileNotFoundError(str(self))
        return SimpleNamespace(st_size=int(meta['size']))

    def open(self, mode='rb', encoding='utf-8'):
        """Abre la generación consultada del objeto para leer bytes o texto."""
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
        """Lee todo el contenido del objeto como bytes."""
        with self.open('rb') as source:
            return source.read()

    def read_text(self, encoding='utf-8'):
        """Lee el objeto y decodifica su contenido como texto."""
        return self.read_bytes().decode(encoding)

    def write_bytes(self, data):
        """Guarda bytes solo si la generación del objeto no cambió desde la consulta."""
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
        """Codifica el texto y lo guarda con control de cambios concurrentes."""
        return self.write_bytes(text.encode(encoding))


def artifact_path(value):
    """Convierte una ruta en Path local o GCSPath según su prefijo."""
    if isinstance(value, (Path, GCSPath)):
        return value
    return GCSPath(str(value)) if str(value).startswith('gs://') else Path(value)


@contextmanager
def open_gzip(path, mode='rt'):
    """Abre un archivo gzip local o de GCS y cierra sus recursos al terminar."""
    with artifact_path(path).open('rb') as raw:
        with gzip.open(raw, mode, encoding='utf-8' if 't' in mode else None) as stream:
            yield stream


def publish_file(temporary: str, destination):
    """Publica un temporal en su destino y retira la copia temporal al subir a GCS."""
    destination = artifact_path(destination)
    if isinstance(destination, GCSPath):
        try:
            destination.write_bytes(Path(temporary).read_bytes())
        finally:
            Path(temporary).unlink(missing_ok=True)
    else:
        os.replace(temporary, destination)


def append_bytes(path, data: bytes):
    """Agrega bytes al archivo; en GCS controla que el objeto no cambie al guardar."""
    path = artifact_path(path)
    if isinstance(path, GCSPath):
        path.write_bytes((path.read_bytes() if path.exists() else b'') + data)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('ab') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
