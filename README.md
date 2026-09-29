# Assist-365 — datos y métricas

> **Estado:** extracción completa guardada y conciliada localmente. La carga de datos en BigQuery, el modelo y el tablero siguen pendientes.

## Objetivo

Construir un flujo reproducible `API → raw → BigQuery → modelo → Looker Studio` que permita analizar prima, costo y frecuencia de siniestros. Se conserva el payload original y se explicitan las limitaciones de cada métrica. El plan de trabajo detallado está en [PLANIFICACION.md](PLANIFICACION.md).

## Estado por parte del ejercicio

| Parte | Resultado actual |
|---|---|
| 1. Extracción | Completa localmente: cinco recursos, 1.147.859 filas y cero registros en cuarentena. |
| 2. Carga raw | Datasets y tablas raw/control creados en `us-central1`; 1.285 páginas verificadas y archivos locales listos para carga. Todavía no se cargaron datos. |
| 3. Modelo | Pendiente de perfilar raw. |
| 4. Orquestación | Pendiente; primero se validará el flujo local y la carga. |
| 5. Análisis | Pendiente; no hay métricas de negocio calculadas. |
| 6. Tablero | Pendiente; el límite de 50 MB deberá medirse. |
| 7. Documentación | Se actualiza junto con cada parte; este README resume decisiones y hallazgos. |

## Organización del código

Los directorios bajo `scripts/` corresponden a las siete partes del ejercicio; `shared/` contiene utilidades comunes:

| Carpeta | Contenido |
|---|---|
| `parte_01_extraccion/` | Conexión API (`api/`), paginación/checkpoints (`extractor/`) y entrypoint `run.py`. |
| `parte_02_carga_bigquery/` | Preparación local, DDL, carga raw y creación de datasets. |
| `parte_03_modelo_bigquery/` | Reservada para modelos; no se define el esquema antes de observar raw. |
| `parte_04_orquestacion/` | Reservada para ejecución diaria y despliegue. |
| `parte_05_analisis/` | Reservada para consultas analíticas reproducibles. |
| `parte_06_tablero/` | Reservada para consultas/preagregaciones y configuración de Looker Studio. |
| `parte_07_readme/` | El documento final permanece en la raíz para encontrarlo fácilmente. |
| `shared/` | Logs estructurados, errores, timestamps, hashes y escritura atómica compartidos por las partes. |

Cada parte del ejercicio reúne su código y recursos: la carga usa `scripts/parte_02_carga_bigquery/` (SQL y esquemas en su subcarpeta `sql/`) y el modelado usará `scripts/parte_03_modelo_bigquery/`. Cada función y clase explica su responsabilidad en un docstring breve.

## Hallazgos de datos que condicionan el diseño

La extracción completa `smoke-20260929` terminó en `SUCCESS` y permanece solo en `.local_data/assist365/raw/smoke-20260929/`; todavía no se cargaron datos a BigQuery. Se guardaron 1.003.461 pólizas (1.004 páginas), 138.962 siniestros (278 páginas, coinciden con el total reportado por la API), 300 agencias, 12 productos y 5.124 tipos de cambio. Las 1.147.859 filas quedaron sin registros en cuarentena y las páginas tienen continuidad numérica y archivos presentes. Los campos de primer nivel conservaron su forma y tipo observados entre páginas.

La preparación local verificó los hashes y conteos de las 1.285 páginas y reconcilió 1.147.859 filas; todos los controles finalizaron `PASS`. Detectó 414 valores no finitos `NaN` en `siniestros.amount.currency`. Ningún registro se descartó: en el NDJSON para BigQuery cada valor se codificó con el marcador JSON `{"__non_finite_number__":"NaN"}`, se mantuvo el hash del registro fuente y cada ocurrencia quedó en el ledger `NonFiniteJSONNumber` con ubicación del registro. Los archivos raw originales preservan el token recibido. También figuran cuatro errores transitorios de transporte ya resueltos. Revisaremos con el proveedor qué semántica espera para `amount.currency` antes de diseñar métricas que usen ese campo.

El perfil anidado de siniestros encontró tres formas en `detail`: 83.505 registros con claves en español (`ciudad_atencion`, `diagnostico`, `proveedor`), 41.538 con claves en inglés (`city`, `diagnosis`, `proveedor`) y 13.919 solo con `proveedor`. Entre los registros en español, `diagnostico` es `null` en 20.955 y texto en 62.550; `amount.currency` es texto en 138.548 y `NaN` en 414. El raw preserva estas variantes. Staging deberá perfilar los valores, acordar alias bilingües sin borrar campos fuente y tratar explícitamente los datos ausentes y no finitos antes de calcular métricas.

El manifiesto conserva conteos, tamaños y hashes de respuesta por página; el ledger contiene cuatro errores de transporte previos, todos resueltos al reanudar desde el checkpoint. Los contadores globales de solicitudes/reintentos corresponden a la última invocación que reanudó la corrida, por lo que no se interpretan como acumulados de todo el proceso. La extracción fue espaciada al menos dos segundos entre solicitudes y usó hasta dos reintentos por solicitud.

En todas las páginas extraídas de siniestros se observaron `occurred_at` y `reported_at`, pero no `created_at`, `updated_at`, una operación `I/U/D` ni un filtro de cambios. `reported_at` describe la fecha del reporte del evento y no debe asumirse como la fecha técnica de creación/modificación del registro.

### Recomendación para mejorar la API de siniestros

Para evitar descargar a diario las ~278 páginas actuales y detectar cambios con precisión, sugerimos exponer:

- `created_at` y `updated_at` en UTC; `created_at` por sí sola no permite encontrar cambios posteriores.
- Un filtro `updated_since` más cursor estable, junto con operaciones `I/U/D` o un tombstone explícito para bajas.
- Una paginación consistente durante cada extracción (snapshot token o cursor que no omita ni repita registros mientras cambia la fuente).
- `paid_at` para distinguir ocurrencia, reporte, actualización y pago en las métricas de costo.

Hasta que el origen ofrezca un delta confiable, la alternativa observable es comparar snapshots completos por `claim_id` y hash. Las altas/cambios se pueden detectar al comparar; una fila ausente solo será candidata a baja después de conciliar el snapshot y descartar errores de paginación. El raw conservará cada snapshot para auditoría. Esto representa hoy unas 278 llamadas por corrida, no una garantía de que siempre serán necesarias: volveremos a evaluar al inspeccionar todos los registros o si el proveedor confirma campos/filtros adicionales.

La API de pólizas documenta `updated_since` y operaciones `I/U/D`, pero el extractor actual todavía no los envía ni consume como delta. Cuando se implemente ese modo, preservaremos eventos crudos y deduplicaremos solapamientos al construir el estado vigente. Los watermarks solo avanzarán cuando páginas, conteos y cargas hayan conciliado.

### ¿Puede darse de baja un siniestro?

Como hecho de negocio, un evento atendido normalmente no deja de haber ocurrido. Sí puede corregirse una carga errónea, detectarse un duplicado o anularse un reclamo; eso debería quedar como cambio de estado o tombstone auditable, no borrarse físicamente del historial. `RECHAZADO` tampoco significa que el registro haya sido eliminado. Por eso no interpretaremos la ausencia en un snapshot como baja real: primero la reportaremos como anomalía/candidata y pediremos al proveedor la semántica de correcciones y bajas.

## Calidad y manejo de fallas

Cada corrida conserva páginas gzip originales, manifiesto, conteos, hashes y ledger de errores bajo `.local_data/`, que está excluido de Git. No se registra el token. La prueba encontró cuatro fallos de transporte del entorno aislado; al reanudar las mismas posiciones, las respuestas se guardaron y las fallas quedaron marcadas `resolved_on_resume` en el ledger. Una etapa solo puede marcarse completa después de verificar paginación, filas, checksums y errores; las filas inválidas se conservan en raw y se reportan, no se corrigen silenciosamente.

Los esquemas y el cargador batch están preparados en `scripts/parte_02_carga_bigquery/`. El procesamiento local no vuelve a llamar la API para preparar una carga. Todavía no se ejecutó una carga de datos en BigQuery.

Cada tabla de BigQuery debe tener una descripción funcional de al menos 200 caracteres y cada campo una descripción de al menos 70 caracteres. El DDL documenta las tablas raw/control y los seis esquemas JSON describen sus 57 campos; `create_environment.py` aplica por tabla toda la metadata en una sola actualización para reducir operaciones y respetar los límites de BigQuery. Las tablas nuevas de staging y mart deberán cumplir el mismo criterio desde su DDL.

## GCP y costos

La comparación considerada fue:

| Opción | Motivo | Decisión |
|---|---|---|
| `us-central1` (Iowa), región única | GCS Standard publicado a ~USD 0,020/GiB-mes. Permite ubicar BigQuery y el futuro bucket juntos. | **Elegida:** priorizamos costo; no necesitamos baja latencia ni réplica geográfica. |
| `US` multi-región | Más cobertura/resiliencia geográfica, pero GCS Standard publicado a ~USD 0,026/GiB-mes. | Descartada: esa redundancia no aporta al alcance actual. |
| `southamerica-east1` (São Paulo) | Alternativa cercana a Argentina. | Descartada: la latencia no es requisito y no ofrece una ventaja necesaria para este caso. |

Los valores de GCS son aproximados, derivados de la tarifa horaria publicada; revisar precios vigentes antes de crear el bucket. La ubicación del dataset BigQuery es fija y alinear bucket/dataset evita transferencias entre ubicaciones. [Precios de Cloud Storage](https://cloud.google.com/storage/pricing), [ubicaciones de BigQuery](https://docs.cloud.google.com/bigquery/docs/locations).

La lectura inicial encontró cero datasets y no mostró buckets existentes. Se crearon `assist365_raw`, `assist365_staging` y `assist365_mart`, junto con `records`, `ingestion_runs`, `ingestion_errors`, `reconciliations`, `watermarks` y `snapshot_diffs` en raw, todos en `us-central1`. No se cargaron registros ni se creó el bucket; GCS queda para después de validar la operación local. Batch load desde archivos locales es una opción documentada por BigQuery, por lo que no hace falta crear el bucket para probar esa etapa. [Cargas por lotes desde archivos locales](https://docs.cloud.google.com/bigquery/docs/batch-loading-data).

## Ejecución local

Los ejemplos usan una espera mínima de 2 segundos y hasta 2 reintentos por solicitud. Ejecutalos desde la raíz del repositorio, con el token disponible en `ASSIST365_API_TOKEN` o ingresándolo cuando el CLI lo solicite.

### 1. Primera extracción completa desde cero

```bash
RUN_ID="full-$(date -u +%Y%m%dT%H%M%SZ)"
if [ -e ".local_data/assist365/raw/$RUN_ID" ]; then echo "El run_id ya existe; elegí otro."; exit 1; fi
python3 -m scripts.parte_01_extraccion.run --full --run-id "$RUN_ID" --min-interval-seconds 2 --max-retries 2
```

Este ID nuevo permite empezar desde la primera página de cada recurso. Guardá su valor o la ruta de la corrida (`.local_data/assist365/raw/$RUN_ID`): lo vas a necesitar si hay que reanudar.

### 2. Reanudar una extracción interrumpida

Repetí el comando de la corrida interrumpida con **el mismo `--run-id`**:

```bash
RUN_ID="full-20260930T090000Z"  # Reemplazar por el ID de la corrida interrumpida.
python3 -m scripts.parte_01_extraccion.run --full --run-id "$RUN_ID" --min-interval-seconds 2 --max-retries 2
```

El checkpoint está en `.local_data/assist365/raw/<run-id>/manifest.json`. La extracción retoma el cursor de pólizas y el offset de siniestros guardados allí; conserva las páginas ya descargadas y omite recursos que figuren completos. Si ese `run_id` ya terminó con éxito, volver a ejecutarlo no crea una captura nueva ni vuelve a descargar esos recursos.

### 3. Captura diaria nueva

Para ejecutar una corrida nueva al día siguiente, asignale un **`--run-id` nuevo** y usá `--full`:

```bash
RUN_ID="daily-$(date -u +%Y%m%dT%H%M%SZ)"
if [ -e ".local_data/assist365/raw/$RUN_ID" ]; then echo "El run_id ya existe; elegí otro."; exit 1; fi
python3 -m scripts.parte_01_extraccion.run --full --run-id "$RUN_ID" --min-interval-seconds 2 --max-retries 2
python3 -m scripts.parte_02_carga_bigquery.prepare_local ".local_data/assist365/raw/$RUN_ID"
```

Esto crea un snapshot completo nuevo. **No es lo mismo que reanudar el checkpoint de ayer y hoy no es todavía una extracción delta**: el extractor actual no envía `updated_since` ni consume operaciones `I/U/D`, así que vuelve a pedir todos los datos disponibles (incluidas las 278 páginas actuales de siniestros). Para una nueva captura del mismo día, elegí otro ID único.

La carga actual de BigQuery agrega los registros a raw con el `run_id`/`snapshot_id`; no aplica todavía ABM ni reemplaza el estado previo. `source_key` y `record_hash` quedan disponibles para comparar snapshots. El ABM debe implementarse después en staging/modelo: para pólizas, una vez que el extractor use el delta documentado por la API; para siniestros, comparando snapshots completos hasta que el proveedor ofrezca un filtro de cambios. Una ausencia de siniestro en un snapshot no se debe tratar automáticamente como baja.

El comando sin opciones tiene valores por defecto distintos: una página por recurso, espera de 1 segundo y hasta 6 reintentos por solicitud. No lo uses para una extracción completa o diaria sin especificar las opciones anteriores.
