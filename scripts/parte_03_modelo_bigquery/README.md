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
  .local_data/assist365/bigquery-load/<run-id>/load_manifest.json
```

`--resources polizas` permite un delta de pólizas; los otros recursos requieren captura completa. `--replay` reprocesa un lote confirmado. MERGE modifica registros nuevos o distintos; un lote idéntico se omite según checksum y versión SQL. Datos, conciliaciones y checkpoints se confirman juntos en una transacción. El límite es 4 GiB facturables por script.

## Validación y consumo

Las **13 conciliaciones** verifican la publicación. Las pruebas incrementales cubren I/U/D, llegada tardía, repetición, correcciones, ausencias, catálogos y rollback; ocho pruebas adicionales cubren flags. [Mapa SQL](#scripts-sql) y [comandos de pruebas](../../docs/EJECUCION.md#validaciones).

Las particiones usan fechas de negocio; acotar fechas y columnas reduce lecturas. [Gold](../../README.md#capa-gold) y las [queries de análisis](../parte_05_analisis/README.md) consumen estas tablas, excluyendo pólizas D/ANULADA y sus siniestros. Los checkpoints corresponden a raw→staging, no a una extracción delta de API.

## Construcción gold

Después de staging, ejecutar desde la raíz con permisos sobre staging/mart/control:

```bash
python3 -m scripts.parte_03_modelo_bigquery.gold.apply_gold --fecha-corte 2026-09-29
```

Reconstruye el agregado mensual completo y confirma datos/control en una transacción. Valida integridad y tamaño antes de publicar, con límite de 4 GiB facturables para la construcción y 50.000.000 bytes para la tabla. Actualizar el corte con una nueva captura validada. [Definición, dimensiones y métricas gold](../../README.md#capa-gold).

## Scripts SQL

| Archivo | Función |
|---|---|
| [010_silver_tables.sql](sql/010_silver_tables.sql) | Esquema de staging y controles separados. |
| [011_incremental_silver.sql](sql/011_incremental_silver.sql) | Transformación, MERGE, conciliaciones y commit. |
| [012_incremental_tests.sql](sql/012_incremental_tests.sql) | Pruebas con tablas temporales. |
| [013_silver_status.sql](sql/013_silver_status.sql) | Estado de cargas y filas modificadas. |
| [014_utc_boundary_test.sql](sql/014_utc_boundary_test.sql) | Prueba de fechas en límites UTC. |
| [015_policy_period_diagnostic.sql](sql/015_policy_period_diagnostic.sql) | Diagnóstico de vigencias/cobertura por lectura y temporales. |
| [016_claim_business_flags.sql](sql/016_claim_business_flags.sql) | Flags integrados en la carga; no ejecutar como cargador independiente. |
| [gold/sql/](gold/sql/) | Construcción, publicación y pruebas del agregado mart. |

Los ejecutores ordenan los scripts. `020_retire_legacy_staging.sql` es una migración de retirada, fuera de la reconstrucción habitual. Las [pruebas del bonus](../bonus/README.md) y la [guía de ejecución](../../docs/EJECUCION.md) permiten validar el modelo.
