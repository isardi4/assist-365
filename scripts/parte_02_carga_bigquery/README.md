# Preparación y carga raw en BigQuery

Convierte las páginas locales verificadas en NDJSON gzip y las carga en `a365-de-ignacio.assist365_raw`, región `us-central1`. Cada recurso tiene su tabla: `polizas`, `siniestros`, `agencias`, `productos` y `tipo_cambio`. Raw conserva el JSON original y los metadatos de carga; ejecuciones, errores y conciliaciones se guardan en `assist365_control`.

## Ejecutar

Requiere Google Cloud CLI autenticada y un snapshot local completo. Desde la raíz del repositorio:

```bash
python3 -m scripts.parte_02_carga_bigquery.create_datasets --location us-central1
python3 -m scripts.parte_02_carga_bigquery.prepare_load \
  .local_data/assist365/raw/<run-id>
python3 -m scripts.parte_02_carga_bigquery.load_local \
  .local_data/assist365/bigquery-load/<run-id>/load_manifest.json \
  --location us-central1
python3 -m scripts.parte_02_carga_bigquery.verify_raw \
  .local_data/assist365/bigquery-load/<run-id>/load_manifest.json \
  --location us-central1 --maximum-bytes-billed 1073741824
```

Ejecutar en orden y detenerse ante una salida no exitosa. [Permisos y requisitos](../../docs/EJECUCION.md).

## Integridad y reintentos

Preparación valida checksum y cantidad de filas de cada página; carga valida todos los artefactos antes del primer envío. Los jobs se identifican por destino, archivo y esquema. Los recibos locales permiten reutilizar una carga terminada sin errores y con destino correcto mientras BigQuery conserve su historial; esto no constituye deduplicación permanente de raw.

Los valores no finitos se codifican con un marcador explícito, por ejemplo `{"__non_finite_number__":"NaN"}`, y se registran en control. No se descartan filas ni se reemplazan valores comerciales. La interpretación monetaria pertenece a staging.

La verificación remota compara registros, páginas, posiciones y controles del lote mediante un dry run y una consulta acotada por particiones/run_id, con límite de 1 GiB facturable. La extracción exitosa y la carga conciliada son controles distintos.

## Resultado y archivos

El snapshot `smoke-20260929` cargó **1.147.859 registros** y pasó **29 controles remotos**. SQL, recibos e informes se conservan junto al manifiesto, fuera de Git. La carga usa archivos locales directamente; no depende de GCS ni consulta la API.

- `create_datasets.py`: crea datasets y tablas mediante `create_environment.py`.
- `prepare_load.py`: preparación; `load_local.py` / `load_bigquery.py`: carga; `verify_raw.py`: conciliación.
- `sql/`: DDL y esquemas. `003_split_raw_resources.sql` es una migración histórica ya aplicada, fuera del flujo de reconstrucción.

Un lote conciliado puede continuar con la [carga staging](../parte_03_modelo_bigquery/README.md).
