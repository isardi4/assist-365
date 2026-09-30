"""Prepare and reconcile raw pages for a later BigQuery load."""

from .prepare_load import main


if __name__ == "__main__":
    raise SystemExit(main())
