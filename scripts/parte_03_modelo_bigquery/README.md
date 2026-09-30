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

Los ejecutores seleccionan y ordenan los SQL de construcción. Las consultas diagnósticas y las pruebas se ejecutan por separado.

### Staging

| Archivo | Función |
|---|---|
| [010_silver_tables.sql](sql/010_silver_tables.sql) | Crea tablas físicas staging y controles si no existen. |
| [011_incremental_silver.sql](sql/011_incremental_silver.sql) | Lee el lote raw, tipa JSON, aplica MERGE y confirma datos/control. |
| [012_incremental_tests.sql](sql/012_incremental_tests.sql) | Prueba cambios I/U/D, repetición y rollback con tablas temporales. |
| [013_silver_status.sql](sql/013_silver_status.sql) | Consulta ejecuciones, conciliaciones y filas modificadas. |
| [014_utc_boundary_test.sql](sql/014_utc_boundary_test.sql) | Comprueba fechas UTC con casos temporales de borde. |
| [015_policy_period_diagnostic.sql](sql/015_policy_period_diagnostic.sql) | Revisa vigencias y coincidencia de cobertura; no modifica negocio. |
| [016_claim_business_flags.sql](sql/016_claim_business_flags.sql) | Referencia de los flags incluidos en 011; no es un cargador separado. |
| [020_retire_legacy_staging.sql](sql/020_retire_legacy_staging.sql) | Migración de retirada de vistas/tablas heredadas; fuera del flujo habitual. |

### Gold

| Archivo | Función |
|---|---|
| [000_control.sql](gold/sql/000_control.sql) | Crea el control gold y registra el inicio del intento. |
| [001_dashboard_table.sql](gold/sql/001_dashboard_table.sql) | Define esquema, partición y clustering del mart mensual. |
| [002_build_dashboard.sql](gold/sql/002_build_dashboard.sql) | Construye el candidato por cohorte, convierte a USD y concilia. |
| [003_publish_dashboard.sql](gold/sql/003_publish_dashboard.sql) | Reemplaza gold y confirma el control en una transacción. |
| [004_country_ranking.sql](gold/sql/004_country_ranking.sql) | Consulta indicadores y siniestralidad por país desde gold. |
| [005_premium_comparison.sql](gold/sql/005_premium_comparison.sql) | Compara premium/no premium por tipo de producto desde gold. |
| [006_functional_tests.sql](gold/sql/006_functional_tests.sql) | Ejecuta 21 pruebas de reglas gold sobre tablas temporales. |
| [007_dashboard_consumption.sql](gold/sql/007_dashboard_consumption.sql) | Ejemplos de consultas de país y premium con filtro temporal; no mide los jobs reales de Looker. |

`apply_gold.py` ejecuta **000 → 002 → 001 → 003**: registra el intento, construye/valida el candidato, asegura el destino y publica. Los SQL 004–007 no forman parte de esa ejecución. La medición real del conector está en la Parte 6.

### Auditoría de siniestros

| Archivo | Función |
|---|---|
| [diagnose.sql](claims_audit/diagnose.sql) | Consulta anomalías de cobertura, importes y moneda. |
| [currency_recovery.sql](claims_audit/currency_recovery.sql) | Evalúa inferencia de moneda y disponibilidad de FX; no imputa datos. |
| [register_reviews.sql](claims_audit/register_reviews.sql) | Registra motivos y estado de revisión en control; ejecución manual. |
| [flag_tests.sql](claims_audit/flag_tests.sql) | Prueba ocho casos de flags con tablas temporales. |

## Ejecutores y archivos de apoyo

| Archivo | Función |
|---|---|
| [apply_staging.py](apply_staging.py) | Valida el manifiesto, ejecuta 010/011 y guarda evidencia silver. |
| [gold/apply_gold.py](gold/apply_gold.py) | Ejecuta la construcción/publicación y registra tamaño real y evidencia gold. |
| [profile_local.py](profile_local.py) | Perfila una captura raw de GCS o una ruta local explícita; no carga staging. |
| [claims_audit/profile_raw.py](claims_audit/profile_raw.py) | Revisa siniestros preparados en GCS y publica informes diagnósticos. |
| [silver_schema.json](silver_schema.json) / [field_descriptions.json](field_descriptions.json) | Esquema esperado de staging y descripciones de sus campos. |
| [gold/schema.json](gold/schema.json) | Esquema y descripciones aplicados al mart. |
| [policy_period_diagnostic.md](policy_period_diagnostic.md) | Resultados del diagnóstico de vigencias y decisión de modelado. |

Las [pruebas del bonus](../bonus/README.md) y la [guía de ejecución](../../docs/EJECUCION.md) incluyen requisitos y comandos para validar el modelo.
