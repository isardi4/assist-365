"""Shared constants, safe logging, file writes, credentials, and TLS setup."""

from __future__ import annotations

import os
import ssl
import subprocess
import sys
from getpass import getpass
from pathlib import Path

from scripts.shared.common import ExtractionError, emit


BASE_URL = "https://h4zfbym5fd.execute-api.us-east-1.amazonaws.com/v1"
RESOURCES = ("productos", "agencias", "tipo_cambio", "polizas", "siniestros")


def ssl_context() -> ssl.SSLContext:
    """Build a verifying TLS context, falling back to macOS system root certificates."""
    context = ssl.create_default_context()
    paths = ssl.get_default_verify_paths()
    if (paths.cafile and Path(paths.cafile).is_file()) or (paths.capath and Path(paths.capath).is_dir()):
        return context
    for candidate in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
        if Path(candidate).is_file():
            return ssl.create_default_context(cafile=candidate)
    if sys.platform == "darwin":
        result = subprocess.run(
            ["/usr/bin/security", "find-certificate", "-a", "-p",
             "/System/Library/Keychains/SystemRootCertificates.keychain"],
            capture_output=True,
            check=False,
        )
        if result.returncode == 0 and result.stdout:
            try:
                context.load_verify_locations(cadata=result.stdout.decode("ascii"))
                return context
            except (UnicodeDecodeError, ssl.SSLError):
                pass
    raise ExtractionError(
        "No se encontró un bundle de certificados TLS confiable. Configurá SSL_CERT_FILE; "
        "la validación TLS no se desactiva."
    )


def read_token() -> str:
    """Read the API token from the environment or hidden terminal input."""
    token = os.environ.get("ASSIST365_API_TOKEN", "").strip()
    if not token and sys.stdin.isatty():
        token = getpass("Token API Assist-365 (entrada oculta): ").strip()
    if not token:
        raise ExtractionError("Falta ASSIST365_API_TOKEN (o ingresarlo en una terminal interactiva).")
    return token
