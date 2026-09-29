"""Rate-limited HTTP client with bounded retries and gzip support."""

from __future__ import annotations

import email.utils
import gzip
import http.client
import random
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

from .common import BASE_URL, ExtractionError, emit, ssl_context


RETRYABLE_HTTP = {429, 500, 502, 503, 504}
MAX_RETRIES = 6
MAX_BACKOFF_SECONDS = 60.0
USER_AGENT = "assist365-case-extractor/0.1"


def retry_after_seconds(value: str | None) -> float | None:
    """Parse Retry-After as seconds or an HTTP date, if the server provides it."""
    if not value:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        try:
            parsed = email.utils.parsedate_to_datetime(value)
            now = datetime.now(parsed.tzinfo or timezone.utc)
            return max(0.0, (parsed - now).total_seconds())
        except (TypeError, ValueError, OverflowError):
            return None


class ApiClient:
    """Send sequential authenticated GET requests and track calls and retries."""

    def __init__(self, token: str, min_interval: float, timeout: float, max_retries: int = MAX_RETRIES):
        """Store request settings and initialize a TLS-verifying session state."""
        self._token = token
        self._context = ssl_context()
        self._min_interval = min_interval
        self._timeout = timeout
        self._max_retries = max_retries
        self._last_request_at = 0.0
        self.request_count = 0
        self.retry_count = 0

    def get_json(self, path: str, params: dict[str, str | int]) -> tuple[bytes, Any, int]:
        """Fetch and decompress one JSON response, retrying transient failures only."""
        query = urllib.parse.urlencode(params)
        url = f"{BASE_URL}/{path}?{query}" if query else f"{BASE_URL}/{path}"
        for attempt in range(self._max_retries + 1):
            wait = self._min_interval - (time.monotonic() - self._last_request_at)
            if wait > 0:
                time.sleep(wait)
            request = urllib.request.Request(
                url,
                headers={
                    "Authorization": f"Bearer {self._token}",
                    "Accept": "application/json",
                    "Accept-Encoding": "gzip",
                    "User-Agent": USER_AGENT,
                },
                method="GET",
            )
            self._last_request_at = time.monotonic()
            self.request_count += 1
            try:
                with urllib.request.urlopen(request, timeout=self._timeout, context=self._context) as response:
                    body = response.read()
                    if response.headers.get("Content-Encoding", "").lower() == "gzip":
                        body = gzip.decompress(body)
                    return body, response.headers, response.status
            except urllib.error.HTTPError as exc:
                retryable = exc.code in RETRYABLE_HTTP
                server_delay = retry_after_seconds(exc.headers.get("Retry-After"))
                exc.close()
                if not retryable or attempt >= self._max_retries:
                    raise ExtractionError(f"HTTP {exc.code} en recurso solicitado; reintentos={attempt}.") from None
                self.retry_count += 1
                self._backoff(attempt, server_delay, path)
            except (urllib.error.URLError, TimeoutError, ConnectionError, ssl.SSLError) as exc:
                cert_error = isinstance(exc, ssl.SSLCertVerificationError) or (
                    isinstance(exc, urllib.error.URLError)
                    and isinstance(exc.reason, ssl.SSLCertVerificationError)
                )
                if cert_error:
                    raise ExtractionError(
                        "Falló la validación del certificado TLS; no se reintentó ni se desactivó TLS."
                    ) from None
                if attempt >= self._max_retries:
                    raise ExtractionError(
                        f"Fallo de transporte {type(exc).__name__}; reintentos={attempt}."
                    ) from None
                self.retry_count += 1
                self._backoff(attempt, None, path)
            except (http.client.HTTPException, gzip.BadGzipFile, EOFError) as exc:
                if attempt >= self._max_retries:
                    raise ExtractionError(
                        f"Respuesta HTTP incompleta {type(exc).__name__}; reintentos={attempt}."
                    ) from None
                self.retry_count += 1
                self._backoff(attempt, None, path)
        raise ExtractionError("Se agotaron los reintentos de transporte.")

    @staticmethod
    def _backoff(attempt: int, server_delay: float | None, resource: str) -> None:
        """Wait with jitter and never undercut a server-provided Retry-After."""
        exponential = min(MAX_BACKOFF_SECONDS, 2**attempt)
        delay = max(server_delay or 0.0, random.uniform(exponential * 0.75, exponential * 1.25))
        emit("retry_wait", resource=resource, attempt=attempt + 1, wait_seconds=round(delay, 2))
        time.sleep(delay)
