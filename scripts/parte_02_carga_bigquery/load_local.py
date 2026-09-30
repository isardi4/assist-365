"""Load a verified Assist-365 run into the raw BigQuery dataset."""

from .load_bigquery import main


if __name__ == "__main__":
    raise SystemExit(main())
