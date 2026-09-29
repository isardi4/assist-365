#!/usr/bin/env python3
"""Entry point for the Assist-365 extractor; implementation lives in small modules."""

from .extractor.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
