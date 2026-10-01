# Preparación y carga raw en BigQuery

Convierte las páginas verificadas de GCS en NDJSON gzip y las carga en `a365-de-ignacio.assist365_raw`, región `us-central1`. Cada recurso tiene su tabla: `polizas`, `siniestros`, `agencias`, `productos` y `tipo_cambio`. Raw conserva el JSON original y los metadatos de carga; ejecuciones, errores y conciliaciones se guardan en `assist365_control`.

## Ejecutar

Requiere Google Cloud CLI autenticada y un snapshot completo en GCS. Desde la raíz del repositorio:

```bash
python3 -m scripts.parte_02_carga_bigquery.create_datasets --location us-central1
python3 -m scripts.parte_02_carga_bigquery.prepare_load \
  gs://a365-de-ignacio-assist365-data/raw/<run-id>
python3 -m scripts.parte_02_carga_bigquery.load_bigquery \
  gs://a365-de-ignacio-assist365-data/bigquery-load/<run-id>/load_manifest.json \
  --location us-central1
python3 -m scripts.parte_02_carga_bigquery.verify_raw \
  gs://a365-de-ignacio-assist365-data/bigquery-load/<run-id>/load_manifest.json \
  --location us-central1 --maximum-bytes-billed 1073741824
```

Estos comandos corresponden a un lote nuevo. Para `smoke-20260929`, reutilizar el `load_manifest.json` existente: preparación comprueba y reutiliza los archivos sin reemplazar confirmaciones. El cargador verifica los conteos del lote migrado antes de omitirlo. Ejecutar en orden y detenerse ante una salida no exitosa. [Permisos y requisitos](../../docs/EJECUCION.md).

## Integridad y reintentos

Preparación valida checksum y cantidad de filas de cada página; carga valida todos los artefactos antes del primer envío. Los jobs se identifican por destino, archivo y esquema. Si un lote ya preparado tiene páginas diferentes, preparación falla y exige otro run_id/destino; no reemplaza un manifiesto publicado. Los recibos en GCS permiten reutilizar una carga terminada sin errores y con destino correcto mientras BigQuery conserve su historial; esto no constituye deduplicación permanente de raw.

Los valores no finitos se codifican con un marcador explícito, por ejemplo `{"__non_finite_number__":"NaN"}`, y se registran en control. No se descartan filas ni se reemplazan valores comerciales. La interpretación monetaria pertenece a staging.

La verificación remota compara registros, páginas, posiciones y controles del lote mediante un dry run y una consulta acotada por particiones/run_id, con límite de 1 GiB facturable. La extracción exitosa y la carga conciliada son controles distintos.

## Resultado y archivos

El snapshot `smoke-20260929` cargó **1.147.859 registros** y pasó **29 controles remotos**. SQL, recibos e informes se conservan junto al manifiesto, fuera de Git. La carga usa URI `gs://` directamente y no consulta la API. El bucket es `gs://a365-de-ignacio-assist365-data`: páginas en `raw/` y archivos preparados en `bigquery-load/`. Los temporales de compresión se eliminan tras publicarlos.

### Qué hace cada archivo

| Archivo | Cuándo se usa: ejemplo | Qué hace |
|---|---|---|
| [create_datasets.py](create_datasets.py) / [create_environment.py](create_environment.py) | Se prepara el entorno por primera vez. | Crea o reutiliza los datasets y las tablas raw/control, y aplica sus esquemas y descripciones. |
| [prepare_load.py](prepare_load.py) | La descarga terminó y hay páginas guardadas en GCS. | Comprueba que estén completas e íntegras y genera los archivos de carga y el listado que los describe. |
| [load_bigquery.py](load_bigquery.py) | Los archivos preparados están listos para subir a raw. | Valida los archivos, solicita su carga desde GCS y guarda las constancias de los jobs de BigQuery. |
| [verify_raw.py](verify_raw.py) | La carga terminó y se quiere comprobar que no falten registros. | Compara cantidades y páginas del lote con BigQuery y publica el informe de sus 29 controles. |
| [prepare_local.py](prepare_local.py) / [load_local.py](load_local.py) | Se encuentra uno de estos nombres en una ejecución anterior. | Son entradas alternativas a la misma preparación/carga; su nombre no implica que los datos deban estar en el equipo local. |
| [migrate_to_gcs.py](migrate_to_gcs.py) | Existe una descarga antigua guardada en el equipo local. | Copia y verifica sus archivos en GCS, y actualiza las rutas conservando las constancias de carga. No se necesita para descargas nuevas. |
| [001_raw_and_control_tables.sql](sql/001_raw_and_control_tables.sql) | El creador del entorno necesita las tablas iniciales. | Define las tablas raw por recurso y las tablas de control. |
| [002_table_descriptions.sql](sql/002_table_descriptions.sql) y [esquemas JSON](sql/) | Se necesita consultar o aplicar las descripciones de tablas y campos. | Contienen las definiciones de estructura y documentación; el creador del entorno aplica los esquemas JSON y descripciones. |
| [003_split_raw_resources.sql](sql/003_split_raw_resources.sql) | Se migra el antiguo modelo con todos los recursos juntos. | Separa los recursos en tablas raw individuales. Es una migración ya aplicada, fuera del flujo habitual. |

`migrate_to_gcs.py <raw-local> <preparado-local>` permite copiar un snapshot existente, verificar tamaño/MD5 y actualizar solo sus rutas, conservando checksums y recibos. La migración de referencia verificó 1.316 archivos, además de los dos manifiestos. Una carga de prueba de los cinco recursos desde GCS reprodujo exactamente los 1.147.859 registros de raw; las tablas de prueba se eliminaron y no se agregaron filas a producción.

Un lote conciliado puede continuar con la [carga staging](../parte_03_modelo_bigquery/README.md).
