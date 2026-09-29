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
    """A concise operational error safe to record in logs and ledgers."""


def utc_now() -> str:
    """Return an ISO-8601 UTC timestamp for manifests and structured logs."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def emit(event: str, **fields: Any) -> None:
    """Write one structured log event without source payloads or credentials."""
    print(json.dumps({"timestamp": utc_now(), "event": event, **fields}, ensure_ascii=False), flush=True)


def sha256(data: bytes) -> str:
    """Return a stable SHA-256 fingerprint for source and artifact checks."""
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes) -> None:
    """Write a file through a temporary sibling, then atomically replace it."""
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
