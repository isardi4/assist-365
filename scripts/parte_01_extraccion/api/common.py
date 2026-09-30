"""Shared constants, safe logging, file writes, credentials, and TLS setup."""

from __future__ import annotations

import json
import os
import ssl
import subprocess
import sys
from pathlib import Path

from scripts.shared.common import ExtractionError


BASE_URL = "https://h4zfbym5fd.execute-api.us-east-1.amazonaws.com/v1"
RESOURCES = ("productos", "agencias", "tipo_cambio", "polizas", "siniestros")
DEFAULT_CONFIG_FILE = Path(__file__).resolve().parents[3] / "config/assist365.json"


def ssl_context() -> ssl.SSLContext:
    """Crea un contexto TLS que verifica certificados y admite las raíces de macOS."""
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
    """Lee el token API de la configuración, con prioridad para la variable de entorno."""
    token = os.environ.get("ASSIST365_API_TOKEN", "").strip()
    if not token:
        config_file = Path(os.environ.get("ASSIST365_CONFIG_FILE", str(DEFAULT_CONFIG_FILE))).expanduser()
        try:
            config = json.loads(config_file.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            raise ExtractionError("No se pudo leer config/assist365.json como configuración válida.") from None
        if not isinstance(config, dict) or not isinstance(config.get("api_token"), str):
            raise ExtractionError("La configuración debe contener api_token como texto.")
        token = config["api_token"].strip()
    if not token:
        raise ExtractionError(
            "Falta el token API en config/assist365.json o ASSIST365_API_TOKEN."
        )
    if any(character.isspace() for character in token):
        raise ExtractionError("El token API tiene un formato inválido.")
    return token
