# Operación del pipeline

El flujo entregado se ejecuta con `python3 -m scripts.run_pipeline --run-id smoke-20260929 --fecha-corte 2026-09-29`: **archivos verificados → raw → staging → gold**. Conserva controles y evidencias por corrida y se detiene ante el primer error; `--setup` crea/reutiliza el entorno. Los [comandos de ejecución](../../docs/EJECUCION.md) permiten reconstruirlo desde un snapshot disponible; los análisis consumen BigQuery sin consultar la API.

## Qué ejecuta el comando

El archivo [scripts/run_pipeline.py](../run_pipeline.py), función `run`, coordina estos pasos en orden. Parte de una descarga ya disponible en GCS; no llama a la API.

| Archivo o función | Cuándo se usa: ejemplo | Qué hace |
|---|---|---|
| `create_environment` de [create_environment.py](../parte_02_carga_bigquery/create_environment.py) | Se ejecuta con `--setup` para preparar el entorno. | Crea o reutiliza datasets y tablas raw/control. |
| `prepare_run` de [prepare_load.py](../parte_02_carga_bigquery/prepare_load.py) | Hay una descarga terminada que debe pasar a BigQuery. | Verifica sus páginas y prepara los archivos de carga. |
| `load_run` de [load_bigquery.py](../parte_02_carga_bigquery/load_bigquery.py) | Los archivos de carga están preparados. | Carga raw o reutiliza cargas ya confirmadas cuando corresponde. |
| `verify_raw` de [verify_raw.py](../parte_02_carga_bigquery/verify_raw.py) | Se terminó de cargar raw. | Compara el lote de origen con el destino antes de continuar. |
| `apply` de [apply_staging.py](../parte_03_modelo_bigquery/apply_staging.py) | Raw pasó la verificación. | Aplica las altas, cambios y bajas a staging, y recalcula los flags de calidad. |
| `apply` de [apply_gold.py](../parte_03_modelo_bigquery/gold/apply_gold.py) | Staging está actualizado. | Reconstruye y publica la tabla que consume el dashboard. |
| `run` de [run_pipeline.py](../run_pipeline.py) | Una etapa termina o falla. | Registra el resultado y guarda el informe final en GCS. Si hay un error, detiene las etapas siguientes. |

## Repetición y recuperación

| Etapa | Comportamiento |
|---|---|
| Extracción | Snapshot completo; el mismo `run_id` reanuda checkpoints y otro identifica una captura nueva. |
| Raw | Verifica archivos y reutiliza jobs de carga confirmados mientras exista su historial en BigQuery. |
| Staging | MERGE transaccional; omite lotes idénticos confirmados y conserva checkpoints junto con los datos. |
| Gold | Reconstrucción completa para incorporar correcciones históricas; una falla anterior al commit conserva los datos publicados. |

La última I/U/D determina el estado de la póliza. Los catálogos completos retiran ausentes; la ausencia de un siniestro genera revisión, no una baja automática. Los checkpoints raw→staging no equivalen a extracción incremental de API.

El corte gold debe corresponder a la captura validada: `--fecha-corte 2026-09-29` para los datos de referencia. No se sustituye automáticamente por la fecha del equipo.

## Alcance cloud

GCS está desplegado en `us-central1`, con acceso público bloqueado. Cloud Run Job y Cloud Scheduler **no están desplegados**. El diseño previsto consiste en un Job invocado por Scheduler, con etapas secuenciales, salida ante fallas, identidad de servicio y almacenamiento persistente de archivos/checkpoints.

La implementación actual persiste páginas, checkpoints, archivos de carga y evidencias en GCS; usa el token API de `config/assist365.json` y credenciales CLI para Google Cloud. Se entrega el comportamiento de recuperación del pipeline; no un servicio diario automatizado ni delta de API por `updated_since`.

## Diseño diario propuesto

Cloud Scheduler invocaría un Cloud Run Job en `us-central1`, a las 06:00 de `America/Argentina/Buenos_Aires` (`0 6 * * *`). Un contenedor con Python y Google Cloud CLI ejecutaría una sola tarea secuencial. Esta es una propuesta de despliegue, no una configuración instalada. [Integración oficial de Scheduler y Cloud Run Jobs](https://docs.cloud.google.com/run/docs/execute/jobs-on-schedule).

1. **Identificar la captura:** asignar un `run_id` diario y fijar su fecha de corte al iniciar. Adquirir un bloqueo con precondición de generación en GCS para impedir ejecuciones superpuestas; conservar ese identificador en todos los reintentos.
2. **Extraer:** ejecutar el extractor completo hacia `raw/<run_id>/`; reanudar páginas confirmadas ante errores transitorios. Una captura parcial no habilita las etapas siguientes. La descarga diaria nueva no está habilitada en la entrega actual.
3. **Procesar:** ejecutar `scripts.run_pipeline` con ese identificador y corte. Preparar NDJSON, cargar y verificar raw, aplicar MERGE staging y reconstruir gold. Un error detiene el flujo; el estado diario solo se confirma después de publicar gold.
4. **Supervisar:** conservar logs estructurados, IDs de jobs, conteos, bytes y reporte final en GCS/control. Alertar por ejecución fallida, captura incompleta o ausencia del SUCCESS esperado; una aceptación de Scheduler no prueba que el procesamiento terminó. Liberar el bloqueo al terminar y definir recuperación explícita de bloqueos abandonados.

Scheduler usaría una identidad con permiso para invocar el Job; el contenedor, otra identidad con permisos GCS y BigQuery descritos en la [guía de ejecución](../../docs/EJECUCION.md). La identidad del Job reemplazaría el login interactivo; no se copiarían credenciales de usuario a la imagen. El token se leería de la configuración entregada. [Identidad y ejecución de Jobs](https://docs.cloud.google.com/run/docs/execute/jobs).

**Segunda corrida:** otro día implica un snapshot completo y un nuevo lote raw; no se promete delta `updated_since`. Staging aplica cambios por clave y mantiene historia; gold se recompone. Reintentar el mismo día conserva el lote y los checkpoints: no debe generar otro identificador ni duplicar cargas confirmadas. Para recuperación fuera de la retención de jobs se requiere una política adicional de deduplicación/restauración, todavía pendiente.

Antes de activar el calendario se deben construir/publicar la imagen, validar dos ejecuciones consecutivas, probar bloqueo y fallas, establecer timeout/reintentos y medir el costo de la extracción completa. El ensayo sobre el snapshot existente valida el flujo de datos; no acredita esos componentes futuros.
