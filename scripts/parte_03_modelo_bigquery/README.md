# Modelo — staging y construcción gold

`a365-de-ignacio.assist365_staging` transforma los JSON raw en seis tablas físicas. Contiene datos de negocio y flags de calidad; los identificadores de carga permanecen en raw/control.

| Tabla | Grano | Filas | Partición |
|---|---|---:|---|
| `polizas` | Evento por póliza, updated_at y operación I/U/D | 1.003.461 | Mes de emisión |
| `polizas_activas` | Último estado por póliza, excluyendo D | 780.000 | Mes de emisión |
| `siniestros` | Un siniestro | 138.133 | Mes de ocurrencia |
| `agencias` | Una agencia | 300 | Sin partición |
| `productos` | Un producto | 12 | Sin partición |
| `tipo_cambio` | Fecha y moneda | 5.124 | Mes de cotización |

## Resolución de cambios

Ejemplo: una póliza ingresa con operación I y luego recibe una U con una prima distinta. `polizas` conserva ambos eventos; `polizas_activas` muestra el último estado y su nueva prima. Si después llega una D, se conserva el historial y se retira la póliza de `polizas_activas`.

La última U actualiza I según `updated_at`; la última D retira la póliza del estado actual. Un evento tardío no revierte un estado posterior. `polizas` conserva el historial; `polizas_activas` significa **no borradas**, por lo que incluye estados ANULADA y VENCIDA. Gold excluye la última ANULADA.

Las 183.461 U mantienen la vigencia anterior y 50.408 cambian prima o moneda. No se agrega una tabla de versiones por cobertura porque esta captura tiene un solo período por póliza. El historial permite revisar cambios, pero las fechas de cobertura no reconstruyen los atributos conocidos en cada instante. [Diagnóstico de vigencias](policy_period_diagnostic.md).

Siniestros deduplica 829 repeticiones exactas; un conflicto de contenido bloquea la carga. Una ausencia en un snapshot genera `ABSENT_REVIEW` y no borra el siniestro. Los catálogos completos retiran claves ausentes y no se reemplazan con un snapshot antiguo.

## Calidad de siniestros

| Campo | Significado |
|---|---|
| `estado_cobertura` | COINCIDE, FUERA_PERIODO, POLIZA_AUSENTE o COBERTURA_AMBIGUA. |
| `estado_importe` | Clasificación de validez monetaria e inferencia. |
| `moneda_analisis` | Moneda válida de origen o inferida desde la póliza. |
| `origen_moneda_analisis` | FUENTE, INFERIDA_POLIZA o NO_DISPONIBLE. |
| `excluir_calculos` | Retira importe negativo/nulo, moneda irrecuperable o falta de cotización válida. |

La moneda inferida válida se incluye; un negativo inferido se excluye por el importe. Los originales no se sobrescriben. Los flags se recalculan después de los MERGE, incluso si cambia la póliza y no el siniestro. [Anomalías, cantidades y fundamentos](../../README.md#anomalías-y-tratamiento).

## Ejecutar

Desde la raíz, con Google Cloud CLI autenticada y un manifiesto cargado y conciliado en raw:

```bash
python3 -m scripts.parte_03_modelo_bigquery.apply_staging \
  gs://a365-de-ignacio-assist365-data/bigquery-load/<run-id>/load_manifest.json
```

`--resources polizas` permite un delta de pólizas; los otros recursos requieren captura completa. `--replay` reprocesa un lote confirmado. MERGE modifica registros nuevos o distintos; un lote idéntico se omite según checksum y versión SQL. Datos, conciliaciones y checkpoints se confirman juntos en una transacción. El límite es 4 GiB facturables por script. Las evidencias quedan en `gcs_root/silver/<run-id>/`; gold las guarda en `gcs_root/gold/`.

## Validación y consumo

Las **13 conciliaciones** verifican la publicación. Las pruebas incrementales cubren I/U/D, llegada tardía, repetición, correcciones, ausencias, catálogos y rollback; ocho pruebas adicionales cubren flags. [Mapa SQL](#scripts-sql) y [comandos de pruebas](../../docs/EJECUCION.md#validaciones).

Las particiones usan fechas de negocio; acotar fechas y columnas reduce lecturas. [Gold](../../README.md#capa-gold) y las [queries de análisis](../parte_05_analisis/README.md) consumen estas tablas, excluyendo pólizas D/ANULADA y sus siniestros. Los checkpoints corresponden a raw→staging, no a una extracción delta de API.

## Construcción gold

Después de staging, ejecutar desde la raíz con permisos sobre staging/mart/control:

```bash
python3 -m scripts.parte_03_modelo_bigquery.gold.apply_gold --fecha-corte 2026-09-29
```

Reconstruye el agregado mensual completo y confirma datos/control en una transacción. Valida integridad antes de publicar y mantiene el límite de 4 GiB facturables para la construcción. El tamaño real de la tabla se registra como información, sin bloquear la publicación. El requisito de 50 MB corresponde al escaneo por carga de Looker y se comprueba mediante sus jobs reales: [medición del dashboard](../parte_06_tablero/README.md#medición-de-consumo). Actualizar el corte con una nueva captura validada. [Definición, dimensiones y métricas gold](../../README.md#capa-gold).

## Scripts SQL

Los comandos Python ejecutan los SQL de construcción en el orden necesario. No hace falta lanzarlos uno por uno. Las consultas de diagnóstico y las pruebas se ejecutan por separado; las tablas siguientes distinguen ambos usos.

### Staging

| Archivo | Cuándo se usa: ejemplo | Qué hace |
|---|---|---|
| [010_silver_tables.sql](sql/010_silver_tables.sql) | Se prepara staging por primera vez. | Crea las tablas de datos y sus tablas de control si todavía no existen; no carga registros. |
| [011_incremental_silver.sql](sql/011_incremental_silver.sql) | Llega un lote raw con pólizas nuevas, actualizadas o borradas. | Lee sus JSON, convierte los campos a sus tipos y aplica altas, cambios y bajas. Conserva el historial y actualiza el estado actual; registra los controles junto con los datos. |
| [012_incremental_tests.sql](sql/012_incremental_tests.sql) | Se quiere comprobar que una actualización o una repetición funcionen correctamente. | Prueba altas, cambios, bajas, llegada tardía y recuperación ante fallas con tablas temporales; no modifica las tablas de negocio. |
| [013_silver_status.sql](sql/013_silver_status.sql) | Se necesita saber cómo terminó una carga staging. | Muestra ejecuciones, resultados de los controles y cantidades modificadas. |
| [014_utc_boundary_test.sql](sql/014_utc_boundary_test.sql) | Una fecha cerca de medianoche podría quedar asignada a otro día. | Comprueba cómo se interpretan las fechas UTC con ejemplos temporales. |
| [015_policy_period_diagnostic.sql](sql/015_policy_period_diagnostic.sql) | Se quiere saber si una actualización cambia la vigencia o si un siniestro queda dentro de cobertura. | Consulta esos casos y sus cantidades; no modifica los datos de negocio. |
| [016_claim_business_flags.sql](sql/016_claim_business_flags.sql) | Se necesita entender cómo se marca un importe negativo o una moneda inferida. | Documenta las reglas de clasificación incluidas en 011. No se ejecuta como una carga adicional. |
| [020_retire_legacy_staging.sql](sql/020_retire_legacy_staging.sql) | Se migra una instalación que conserva tablas o vistas del modelo anterior. | Retira esos objetos antiguos. No forma parte de la corrida habitual. |

### Gold

| Archivo | Cuándo se usa: ejemplo | Qué hace |
|---|---|---|
| [000_control.sql](gold/sql/000_control.sql) | Comienza un intento de construcción gold. | Crea las tablas de control necesarias y registra el inicio del intento. |
| [001_dashboard_table.sql](gold/sql/001_dashboard_table.sql) | Se necesita preparar la tabla que consulta Looker. | Define sus columnas y su organización por fechas y campos de consulta. |
| [002_build_dashboard.sql](gold/sql/002_build_dashboard.sql) | Se quiere calcular los indicadores después de actualizar staging. | Prepara el resultado mensual por mes de emisión, convierte importes a USD y comprueba su consistencia antes de publicarlo. |
| [003_publish_dashboard.sql](gold/sql/003_publish_dashboard.sql) | El resultado preparado pasó los controles. | Reemplaza el contenido de gold y confirma el estado de la carga en una misma operación; si falla antes de confirmar, conserva lo publicado. |
| [004_country_ranking.sql](gold/sql/004_country_ranking.sql) | Se quiere comparar la siniestralidad entre países. | Consulta los indicadores por país desde gold; no modifica tablas. |
| [005_premium_comparison.sql](gold/sql/005_premium_comparison.sql) | Se quiere comparar planes premium y no premium. | Consulta sus indicadores por tipo de producto desde gold; no modifica tablas. |
| [006_functional_tests.sql](gold/sql/006_functional_tests.sql) | Se quiere comprobar que gold aplique las reglas de población y cálculo. | Ejecuta 21 pruebas con tablas temporales, incluida la suma de cada prima una sola vez. |
| [007_dashboard_consumption.sql](gold/sql/007_dashboard_consumption.sql) | Se necesita un ejemplo de consulta de gold con un período acotado. | Consulta indicadores de país y premium. No mide el consumo real del dashboard; esa medición está en la Parte 6. |

`apply_gold.py` ejecuta **000 → 002 → 001 → 003**: registra el intento, construye/valida el candidato, asegura el destino y publica. Los SQL 004–007 no forman parte de esa ejecución. La medición real del conector está en la Parte 6.

### Auditoría de siniestros

| Archivo | Cuándo se usa: ejemplo | Qué hace |
|---|---|---|
| [diagnose.sql](claims_audit/diagnose.sql) | Hay siniestros con cobertura, importe o moneda dudosos. | Consulta las anomalías para identificar y contar los casos. |
| [currency_recovery.sql](claims_audit/currency_recovery.sql) | Un siniestro no informa moneda y podría obtenerse de su póliza. | Evalúa esa posibilidad y la disponibilidad de una cotización; no modifica ni completa datos. |
| [register_reviews.sql](claims_audit/register_reviews.sql) | Se necesita dejar constancia de casos pendientes de revisión. | Registra motivos y estado de revisión en el dataset de control. Se ejecuta manualmente. |
| [flag_tests.sql](claims_audit/flag_tests.sql) | Se quiere verificar qué casos quedan incluidos o excluidos de los cálculos. | Prueba ocho ejemplos de moneda inferida e importes inválidos con tablas temporales. |

## Ejecutores y archivos de apoyo

| Archivo | Cuándo se usa: ejemplo | Qué hace |
|---|---|---|
| [apply_staging.py](apply_staging.py), función `apply` | Raw ya está cargado y se quiere actualizar staging. | Valida el manifiesto —el archivo que describe el lote—, ejecuta 010 y 011 y guarda los resultados de la carga. |
| [gold/apply_gold.py](gold/apply_gold.py), función `apply` | Staging ya está actualizado y se quiere renovar el dashboard. | Coordina la construcción y publicación de gold; registra el tamaño real de la tabla y los resultados. |
| [profile_local.py](profile_local.py) | Se necesita explorar qué contienen los archivos raw. | Resume una captura de GCS o una ruta local indicada explícitamente; no carga staging. |
| [claims_audit/profile_raw.py](claims_audit/profile_raw.py) | Se quiere revisar los siniestros antes de interpretar sus anomalías. | Lee los archivos preparados en GCS y publica informes de diagnóstico. |
| [silver_schema.json](silver_schema.json) / [field_descriptions.json](field_descriptions.json) | Se necesita consultar las columnas y descripciones esperadas de staging. | Define el esquema de referencia y las explicaciones de sus campos. |
| [gold/schema.json](gold/schema.json) | Se necesita consultar las columnas de la tabla del dashboard. | Define el esquema y las descripciones aplicados al mart. |
| [policy_period_diagnostic.md](policy_period_diagnostic.md) | Se quiere entender por qué no se agregó una tabla de versiones por cobertura. | Explica los resultados del diagnóstico de vigencias y la decisión de modelado. |

Las [pruebas del bonus](../bonus/README.md) y la [guía de ejecución](../../docs/EJECUCION.md) incluyen requisitos y comandos para validar el modelo.
