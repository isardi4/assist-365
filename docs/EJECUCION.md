# Ejecución reproducible

## Requisitos

Ejecutar desde la raíz del repositorio. Se necesita Python 3.10 o superior y Google Cloud CLI con `gcloud` y `bq` disponibles en PATH. Los scripts usan la biblioteca estándar de Python: no requieren paquetes pip, dbt ni un servidor MCP.

La identidad debe tener permiso de crear jobs en el proyecto (`roles/bigquery.jobUser`) y leer staging/mart (`roles/bigquery.dataViewer` en esos datasets). Para reconstruir modelos también necesita escribir en staging/mart/control. La autenticación CLI usa credenciales locales de Google Cloud, nunca un archivo de credenciales incluido en Git.

```bash
gcloud auth login
gcloud config set project a365-de-ignacio
bq version
```

Para leer el snapshot se requiere `roles/storage.objectViewer` sobre el bucket; para extracción, preparación y evidencias se requiere `roles/storage.objectUser`. La identidad que ejecuta jobs BigQuery también necesita leer los objetos que carga. Si se usa una identidad de servicio, concederle esos mismos permisos.

`config/assist365.json` define `gcs_root`; `ASSIST365_GCS_ROOT` lo puede reemplazar. Cambiar el bucket exige crearlo en una región compatible y conceder sus permisos.

La autenticación debe completarla la persona que ejecuta el proyecto. Esta guía no concede permisos ni comparte datos automáticamente.

## Configuración de la API

[config/assist365.json](../config/assist365.json) contiene el token del challenge y está versionado. El extractor lo lee automáticamente al clonar el repositorio; no usa Secret Manager, el Markdown del ejercicio ni un archivo local de secretos. `ASSIST365_API_TOKEN` permite sustituir el token y `ASSIST365_CONFIG_FILE` seleccionar otro JSON con `api_token`.

El token solo sirve para extraer desde la API. Cargas, modelos y queries usan la identidad de `gcloud` con permisos BigQuery y GCS. La ruta de análisis siguiente no consulta la API.

## Camino rápido: análisis desde staging

No necesita token API ni archivos descargados. Abrir y ejecutar cualquiera de las [dos queries](../scripts/parte_05_analisis/README.md) en BigQuery, cambiando las fechas de emisión y el corte de ocurrencia declarados al inicio. Devuelven resultados mensuales directamente, sin exportadores ni tablas adicionales.

```bash
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --max_rows=10000 --maximum_bytes_billed=2147483648 \
  < scripts/parte_05_analisis/sql/001_siniestralidad_pais_plan.sql
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --max_rows=10000 --maximum_bytes_billed=2147483648 \
  < scripts/parte_05_analisis/sql/002_siniestralidad_canal_pais.sql
```

Los resultados se agrupan por mes de emisión (`mes_cohorte`). Desde/hasta seleccionan pólizas; los siniestros posteriores se incluyen hasta `fecha_corte`. Los SQL referencian el proyecto del challenge; cambiar el proyecto requiere cambiar sus referencias. El límite de consulta no representa el límite por carga de Looker.

## Reconstruir desde archivos ya existentes

El snapshot `smoke-20260929` está disponible en `gs://a365-de-ignacio-assist365-data`. Con permisos de lectura del bucket, un clon puede reutilizarlo sin archivos locales ni nuevas consultas a la API. El proyecto entregado ya lo tiene cargado: el manifiesto conserva esa confirmación y evita duplicarlo. No volver a preparar un lote ya cargado; reutilizar su manifiesto.

```bash
python3 -m scripts.parte_02_carga_bigquery.create_datasets --location us-central1
python3 -m scripts.parte_02_carga_bigquery.load_bigquery \
  gs://a365-de-ignacio-assist365-data/bigquery-load/smoke-20260929/load_manifest.json \
  --location us-central1
python3 -m scripts.parte_02_carga_bigquery.verify_raw \
  gs://a365-de-ignacio-assist365-data/bigquery-load/smoke-20260929/load_manifest.json \
  --location us-central1
python3 -m scripts.parte_03_modelo_bigquery.apply_staging \
  gs://a365-de-ignacio-assist365-data/bigquery-load/smoke-20260929/load_manifest.json
python3 -m scripts.parte_03_modelo_bigquery.gold.apply_gold --fecha-corte 2026-09-29
```

Los ejecutores raw/silver/gold están vinculados al proyecto `a365-de-ignacio`; cambiar `gcloud config` no cambia sus destinos. Las queries de análisis también referencian explícitamente este proyecto. Migrar el pipeline completo a otro proyecto requiere parametrizar esos ejecutores y referencias SQL; no se presenta como una capacidad existente.

Ejecutar los comandos en orden y detenerse ante un código de salida distinto de cero. Las migraciones de retirada no forman parte de la reconstrucción de un entorno nuevo.

Para una captura **nueva**, preparar primero sus páginas en GCS con `python3 -m scripts.parte_02_carga_bigquery.prepare_load gs://a365-de-ignacio-assist365-data/raw/<nuevo-run-id>`. El destino predeterminado es `gcs_root/bigquery-load/<nuevo-run-id>/`. La preparación usa temporales efímeros para comprimir NDJSON, los elimina tras publicarlos y no requiere archivos locales persistentes. BigQuery carga directamente las URI GCS. `--output-dir` permite seleccionar otro prefijo.

## Validaciones

Las pruebas SQL usan tablas temporales y no descargan datos ni modifican las tablas productivas.

```bash
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --maximum_bytes_billed=4294967296 \
  < scripts/parte_03_modelo_bigquery/sql/012_incremental_tests.sql
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --maximum_bytes_billed=4294967296 \
  < scripts/parte_03_modelo_bigquery/gold/sql/006_functional_tests.sql
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --maximum_bytes_billed=4294967296 \
  < scripts/parte_03_modelo_bigquery/claims_audit/flag_tests.sql
```

Para consumo final, abrir el [dashboard y su guía](../scripts/parte_06_tablero/README.md). El análisis no requiere token API. La ejecución entregada es por CLI; el despliegue diario cloud no está implementado y el escaneo real por carga del tablero no se presenta como medido.

El corte de gold debe corresponder a la captura disponible. Gold acumula los siniestros elegibles de cada cohorte hasta ese corte; al llegar una captura nueva, reconstruir con el corte actualizado. Los filtros de Looker seleccionan meses de emisión completos.
