"""Shared error, logging, hashing, timestamp, and atomic-file utilities."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class ExtractionError(RuntimeError):
    """Representa un error operativo que puede registrarse sin exponer datos sensibles."""


def utc_now() -> str:
    """Devuelve la fecha y hora actuales en UTC para manifiestos y logs."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def emit(event: str, **fields: Any) -> None:
    """Escribe un evento JSON con su fecha UTC y los campos recibidos."""
    print(json.dumps({"timestamp": utc_now(), "event": event, **fields}, ensure_ascii=False), flush=True)


def sha256(data: bytes) -> str:
    """Calcula la huella SHA-256 de los bytes para comprobar su integridad."""
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes) -> None:
    """Guarda bytes de forma atómica, en GCS o mediante un archivo temporal local."""
    if str(path).startswith('gs://'):
        path.write_bytes(data)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise
