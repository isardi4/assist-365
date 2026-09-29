# Parte 2 — Carga raw a BigQuery

- `create_environment.py`: datasets y tablas raw/control.
- `prepare_load.py`: valida archivos locales y produce NDJSON gzip por recurso.
- `load_bigquery.py`: carga archivos verificados con `bq load`.
- `sql/`: DDL, descripciones de tablas y esquemas JSON de las cargas.
- Los entrypoints se ejecutan con `python3 -m scripts.parte_02_carga_bigquery.<módulo>`.
