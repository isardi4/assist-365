"""Verify versioned API configuration without network requests."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.parte_01_extraccion.api.common import read_token
from scripts.shared.common import ExtractionError


class ApiTokenTests(unittest.TestCase):
    def test_environment_takes_precedence(self):
        with patch.dict(os.environ, {"ASSIST365_API_TOKEN": "test-env-token",
                                    "ASSIST365_CONFIG_FILE": "/missing/file"}, clear=True):
            self.assertEqual(read_token(), "test-env-token")

    def test_explicit_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"api_token": "test-config-token"}))
            with patch.dict(os.environ, {"ASSIST365_CONFIG_FILE": str(path)}, clear=True):
                self.assertEqual(read_token(), "test-config-token")

    def test_default_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"api_token": "test-default-token"}))
            with patch.dict(os.environ, {}, clear=True), \
                    patch("scripts.parte_01_extraccion.api.common.DEFAULT_CONFIG_FILE", path):
                self.assertEqual(read_token(), "test-default-token")

    def test_missing_config_has_safe_error(self):
        with patch.dict(os.environ, {"ASSIST365_CONFIG_FILE": "/missing/file"}, clear=True):
            with self.assertRaisesRegex(ExtractionError, "configuración válida"):
                read_token()

    def test_invalid_json_does_not_expose_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text('{"api_token": "sensitive-value"')
            with patch.dict(os.environ, {"ASSIST365_CONFIG_FILE": str(path)}, clear=True):
                with self.assertRaises(ExtractionError) as error:
                    read_token()
                self.assertNotIn("sensitive", str(error.exception))

    def test_invalid_token_not_exposed(self):
        with patch.dict(os.environ, {"ASSIST365_API_TOKEN": "sensitive token"}, clear=True):
            with self.assertRaises(ExtractionError) as error:
                read_token()
            self.assertNotIn("sensitive", str(error.exception))

    def test_wrong_schema_and_empty_token_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            for config in [[], {}, {"api_token": 123}, {"api_token": " \n"}]:
                path.write_text(json.dumps(config))
                with patch.dict(os.environ, {"ASSIST365_CONFIG_FILE": str(path)}, clear=True):
                    with self.assertRaises(ExtractionError):
                        read_token()


if __name__ == "__main__":
    unittest.main()
