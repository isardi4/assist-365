# Parte 2 — Carga raw a BigQuery

- `create_environment.py`: datasets y tablas raw/control.
- `prepare_load.py`: valida archivos locales y produce NDJSON gzip por recurso.
- `load_bigquery.py`: carga archivos verificados con `bq load`.
- `sql/`: DDL, descripciones de tablas y esquemas JSON de las cargas.
- Los entrypoints se ejecutan con `python3 -m scripts.parte_02_carga_bigquery.<módulo>`.

`prepare_load.py` verifica el checksum y el conteo de cada página antes de emitir NDJSON gzip y archivos de conciliación. En `smoke-20260929` detectó 414 valores `NaN` en `siniestros.amount.currency`: los representó explícitamente como `{"__non_finite_number__":"NaN"}` para mantener JSON válido y registró cada ubicación como `NonFiniteJSONNumber`, sin descartar filas. El raw fuente conserva la respuesta original. La preparación produjo cinco archivos de registros y tres archivos de control/errores (ocho cargas esperadas); aún no se ejecutó ninguna carga en BigQuery.
