# Assist-365 — datos y métricas

> **Estado:** reconocimiento y prueba local acotada completados. La extracción completa, la carga en BigQuery, el modelo y el tablero siguen pendientes.

## Objetivo

Construir un flujo reproducible `API → raw → BigQuery → modelo → Looker Studio` que permita analizar prima, costo y frecuencia de siniestros. Se conserva el payload original y se explicitan las limitaciones de cada métrica. El plan de trabajo detallado está en [PLANIFICACION.md](PLANIFICACION.md).

## Estado por parte del ejercicio

| Parte | Resultado actual |
|---|---|
| 1. Extracción | Extractor local implementado; prueba acotada de 7 GET acumulados y 0 reintentos. Catálogos completos; pólizas y siniestros siguen parciales. |
| 2. Carga raw | Datasets y tablas raw/control creados en `us-central1`; archivos y carga local preparados. Todavía no se cargaron datos. |
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

La prueba local acumuló 7 GET exitosos y ningún reintento. Se completaron los catálogos: productos 12, agencias 300 y tipos de cambio 5.124. Se guardaron dos páginas de pólizas (2.000 filas) y dos páginas de siniestros (1.000 filas); siniestros informó un total de 138.962, unas 278 páginas de 500 filas. La corrida queda `PARTIAL` intencionalmente. Las muestras no prueban que todas las páginas tengan el mismo esquema.

En la documentación y las muestras revisadas, siniestros incluye `occurred_at` y `reported_at`, pero no se observó `created_at`, `updated_at`, una operación `I/U/D` ni un filtro de cambios. `reported_at` describe la fecha del reporte del evento y no debe asumirse como la fecha técnica de creación/modificación del registro. Esta ausencia debe reconfirmarse al perfilar la extracción completa.

### Recomendación para mejorar la API de siniestros

Para evitar descargar a diario las ~278 páginas actuales y detectar cambios con precisión, sugerimos exponer:

- `created_at` y `updated_at` en UTC; `created_at` por sí sola no permite encontrar cambios posteriores.
- Un filtro `updated_since` más cursor estable, junto con operaciones `I/U/D` o un tombstone explícito para bajas.
- Una paginación consistente durante cada extracción (snapshot token o cursor que no omita ni repita registros mientras cambia la fuente).
- `paid_at` para distinguir ocurrencia, reporte, actualización y pago en las métricas de costo.

Hasta que el origen ofrezca un delta confiable, la alternativa observable es comparar snapshots completos por `claim_id` y hash. Las altas/cambios se pueden detectar al comparar; una fila ausente solo será candidata a baja después de conciliar el snapshot y descartar errores de paginación. El raw conservará cada snapshot para auditoría. Esto representa hoy unas 278 llamadas por corrida, no una garantía de que siempre serán necesarias: volveremos a evaluar al inspeccionar todos los registros o si el proveedor confirma campos/filtros adicionales.

Las pólizas sí documentan `updated_since` y operaciones `I/U/D`; allí preservaremos eventos crudos y deduplicaremos solapamientos al construir el estado vigente. Los watermarks solo avanzarán cuando páginas, conteos y cargas hayan conciliado.

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

Desde la raíz del repositorio:

```bash
python3 -m scripts.parte_01_extraccion.run --max-pages-per-resource 1
python3 -m scripts.parte_01_extraccion.run --full --run-id initial-20260929
python3 -m scripts.parte_02_carga_bigquery.prepare_local .local_data/assist365/raw/<run_id>
```

La extracción completa aún no se ejecutó. El token se lee desde `ASSIST365_API_TOKEN` o se solicita sin mostrarlo en pantalla. El run `smoke-20260929` puede continuarse con `--full --run-id smoke-20260929`; los checkpoints evitan repetir páginas ya guardadas.
