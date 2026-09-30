# Ejecución reproducible

## Requisitos

Ejecutar desde la raíz del repositorio. Se necesita Python 3.10 o superior y Google Cloud CLI con `gcloud` y `bq` disponibles en PATH. Los scripts usan la biblioteca estándar de Python: no requieren paquetes pip, dbt ni un servidor MCP.

La identidad debe tener permiso de crear jobs en el proyecto (`roles/bigquery.jobUser`) y leer staging/mart (`roles/bigquery.dataViewer` en esos datasets). Para cargar y reconstruir el flujo necesita escritura en raw/staging/mart/control; `--setup` requiere además crear datasets y actualizar sus esquemas. La autenticación CLI usa credenciales locales de Google Cloud, nunca un archivo de credenciales incluido en Git.

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

## Ejecutar el flujo completo

Desde un clon con acceso al proyecto y al bucket, ejecutar:

```bash
python3 -m scripts.run_pipeline \
  --run-id smoke-20260929 --fecha-corte 2026-09-29
```

Ejecuta preparación, carga/validación raw, staging y gold en orden. No consulta la API, no necesita `.local_data/` ni `EJERCICIO.md`, reutiliza artefactos ya preparados y se detiene ante el primer error. La preparación repetida conserva manifiestos y recibos; si cambió una captura con el mismo identificador, falla para evitar reemplazar un lote cargado. El lote migrado solo se omite después de verificar sus archivos y conteos reales en raw. Gold se reconstruye, manteniendo su mismo grano y criterio comercial.

Para crear/reutilizar también datasets y esquemas, agregar `--setup`. Esta opción actualiza metadatos y demora más; el proyecto entregado ya tiene el entorno creado. Las evidencias de la ejecución se guardan en `gcs_root/pipeline/<run-id>/<ejecucion>/report.json`, además de las evidencias de cada capa.

**Ensayo realizado el 30/09/2026:** el comando anterior terminó SUCCESS desde un clon limpio, sin `.local_data/` ni `EJERCICIO.md`. La creación/reutilización del entorno también se ejecutó por separado. Las pruebas offline y SQL y ambas consultas analíticas terminaron correctamente. [Reporte de verificación](evidence/ensayo_20260930.json).

El ensayo se repitió con el código final (`713111b`): terminó SUCCESS en aproximadamente 6 min 27 s, conservando conteos y contenido gold. El tiempo puede variar por red y ejecución de jobs.

La ruta de referencia usa el snapshot disponible. La extracción completa para una **captura nueva** es un comando independiente, documentado en la parte 1; los cambios de código deben validarse primero con fixtures sin volver a descargar el millón de registros.

## Captura nueva: API → GCS → raw → staging → gold

Una captura nueva usa un `run_id` distinto. El extractor descarga los cinco recursos completos y los guarda en GCS; después `run_pipeline` prepara y carga ese lote en raw, aplica los cambios en staging y reconstruye gold. El identificador debe ser el mismo en ambos comandos.

Con los requisitos y la autenticación anteriores completos, ejecutar desde la raíz en la misma terminal:

```bash
CAPTURE_DATE="$(date -u +%F)"
RUN_ID="snapshot-$(date -u +%Y%m%dT%H%M%SZ)"

python3 -m scripts.parte_01_extraccion.run \
  --full --run-id "$RUN_ID" &&
python3 -m scripts.run_pipeline \
  --run-id "$RUN_ID" --fecha-corte "$CAPTURE_DATE"
```

`--full` es necesario: sin él, el extractor solo solicita una página por recurso. `&&` permite iniciar la carga únicamente si la extracción termina correctamente. La fecha de corte se fija en UTC al iniciar la captura; no se usa la del snapshot anterior. Para crear/reutilizar también los datasets y esquemas en una primera ejecución, agregar `--setup` al comando `run_pipeline`. El bucket debe existir y tener los permisos indicados; estos comandos usan el proyecto entregado.

| Etapa | Resultado esperado |
|---|---|
| Extracción | Snapshot completo bajo `gcs_root/raw/<run-id>/`, con manifiesto y checkpoints. |
| Raw | Agrega el snapshot a las cinco tablas; conserva las capturas anteriores y su trazabilidad. |
| Staging | Historial de pólizas incorpora eventos únicos; estado actual aplica la última I/U/D. Siniestros se insertan/actualizan por clave; ausencias quedan para revisión. Catálogos completos actualizan y retiran ausentes. |
| Gold | Reconstruye el agregado mensual desde staging con el corte indicado; reemplaza su contenido. |

**Al día siguiente:** volver a ejecutar el bloque para asignar otro identificador y fecha. La API sigue entregando snapshots completos; los cambios se resuelven al procesarlos en staging, sin duplicar sus entidades actuales. No hay extracción delta ni calendario desplegado. Una captura parcial o una validación fallida impide completar el flujo.

**Ante una falla:** conservar `RUN_ID` y `CAPTURE_DATE`. Si falló la extracción, repetir su comando con ese mismo identificador para reanudar checkpoints. Si terminó la extracción pero falló una etapa posterior, repetir solo `run_pipeline` con esas mismas variables. No regenerar el identificador al recuperar una captura. Si se cerró la terminal, recuperar los valores del evento `run_started` y de la fecha de corte usada.

**Confirmación:** el último evento debe ser `pipeline_finished` con `status: SUCCESS`; su campo `evidence` indica el prefijo GCS que contiene `report.json`. No avanzar manualmente a staging si raw no fue cargada y verificada. Para consultar el resultado:

```bash
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --max_rows=10000 --maximum_bytes_billed=1073741824 \
  < scripts/parte_03_modelo_bigquery/sql/013_silver_status.sql
bq --project_id=a365-de-ignacio show --format=prettyjson \
  assist365_mart.dashboard_diario
```

La primera consulta muestra estado y filas modificadas en staging; la segunda muestra el inventario de gold, incluidos `numRows` y `numBytes`. Los [comandos de análisis](#camino-rápido-análisis-desde-staging) permiten revisar las métricas. La descarga completa puede tardar decenas de minutos; para una demostración breve se puede ejecutar el [snapshot disponible](#ejecutar-el-flujo-completo), sin consultar nuevamente la API.

## Reconstruir desde archivos ya existentes

El snapshot `smoke-20260929` está disponible en `gs://a365-de-ignacio-assist365-data`. Con permisos de lectura del bucket, un clon puede reutilizarlo sin archivos locales ni nuevas consultas a la API. El proyecto entregado ya lo tiene cargado: el manifiesto conserva esa confirmación y evita duplicarlo. Repetir preparación ahora reutiliza su manifiesto tras validar los artefactos; no lo reemplaza.

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

Pruebas Python offline, sin solicitudes a la API ni mutaciones BigQuery:

```bash
python3 -m unittest discover -s scripts/bonus -p 'test_*.py'
```

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

Para consumo final, abrir el [dashboard y su guía](../scripts/parte_06_tablero/README.md). El análisis no requiere token API. La ejecución entregada es por CLI; el despliegue diario cloud no está implementado. La carga inicial del tablero para abril–junio de 2026 registró 1.405.616 bytes procesados, con [medición y SQL reproducible](../scripts/parte_06_tablero/README.md#medición-de-consumo).

El corte de gold debe corresponder a la captura disponible. Gold acumula los siniestros elegibles de cada cohorte hasta ese corte; al llegar una captura nueva, reconstruir con el corte actualizado. Los filtros de Looker seleccionan meses de emisión completos.
