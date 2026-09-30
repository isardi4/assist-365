# Operación del pipeline

El flujo entregado se ejecuta por CLI: **archivos verificados → raw → staging → gold**. Conserva controles y evidencias por corrida. Los [comandos de ejecución](../../docs/EJECUCION.md) permiten reconstruirlo desde un snapshot disponible; los análisis consumen BigQuery sin consultar la API.

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

Cloud Run Job, Cloud Scheduler y GCS **no están desplegados**. El diseño previsto consiste en un Job invocado por Scheduler, con etapas secuenciales, salida ante fallas, identidad de servicio y almacenamiento persistente de archivos/checkpoints.

La implementación actual usa archivos locales, el token API de `config/assist365.json` y credenciales CLI para Google Cloud. Se entrega el comportamiento de recuperación del pipeline; no un servicio diario automatizado ni delta de API por `updated_since`.
