# Bonus — pruebas de datos y alcance

Se implementaron pruebas en SQL nativo de BigQuery y conciliaciones en los ejecutores. No requieren dbt ni otro framework. Las pruebas funcionales usan tablas temporales y no modifican tablas de negocio.

| Validación | Alcance |
|---|---|
| [Incremental staging](../parte_03_modelo_bigquery/sql/012_incremental_tests.sql) | I/U/D, llegada tardía, repetición, correcciones, ausencias, catálogos y rollback. |
| [Flags de siniestros](../parte_03_modelo_bigquery/claims_audit/flag_tests.sql) | Ocho casos de inferencia, exclusión monetaria y conservación de originales. |
| [Gold](../parte_03_modelo_bigquery/gold/sql/006_functional_tests.sql) | 21 pruebas de población, atribución de cohortes, conversiones y agregación sin duplicar primas. |
| [Configuración API](test_api_token.py) | Siete pruebas de selección del token, formato y errores sin revelar valores; sin llamadas de red. |
| [Extracción CLI](test_extractor.py) | Dos pruebas de paginación cursor/offset, publicación GCS, repetición sin API y decodificación gzip. |
| [Almacenamiento y replay](test_gcs_pipeline.py) | Once pruebas de integridad, checkpoints, preparación repetida, destino migrado y verificación sin errores de origen. |
| Conciliaciones | 29 controles raw, 13 staging y 24 gold para comprobar las publicaciones. |

[Requisitos y comandos para ejecutarlas](../../docs/EJECUCION.md#validaciones). Las pruebas SQL se ejecutan manualmente en BigQuery; las veinte pruebas Python se ejecutan automáticamente en el CI offline.

Se entrega una [skill de análisis](../../SKILL.md) con glosario, tablas/granos, métricas, reglas de población/FX y cinco preguntas de ejemplo. Para usarla, indicar al asistente que lea `SKILL.md` y consulte BigQuery con esas definiciones. El archivo está versionado en el repositorio; su instalación y conexión dependen del entorno del asistente. **El bonus semántico está parcial:** las cinco preguntas todavía no tienen ejecuciones verificadas vía MCP. Una ejecución con `bq` no acredita ese requisito. El video no está implementado.

## Qué prueban los archivos Python

Los tres archivos contienen **20 pruebas automáticas**. Cada una prepara una situación de ejemplo y comprueba que el programa responda como corresponde. Si algo funciona distinto de lo esperado, la prueba falla. También se prueba que el programa detenga operaciones incorrectas, como intentar cargar un archivo dañado.

Las pruebas usan datos inventados y simulan la API, el almacenamiento de Google Cloud (GCS) y BigQuery. No necesitan accesos a esos servicios ni modifican datos reales.

### Lectura del token: `test_api_token.py` — 7 pruebas

El token es la clave que permite acceder a la API. Estas pruebas revisan cómo lo obtiene el programa, usando claves ficticias.

| Función de prueba | Situación de ejemplo | Qué debe hacer el programa |
|---|---|---|
| `test_environment_takes_precedence` | Se configura un token directamente en el entorno de ejecución. | Usar ese token antes que el del archivo de configuración. |
| `test_explicit_config` | Se indica un archivo de configuración específico. | Leer el token de ese archivo. |
| `test_default_config` | No se indica ninguna configuración especial. | Buscar el token en el archivo predeterminado. La prueba usa un archivo temporal, no el token real del repositorio. |
| `test_missing_config_has_safe_error` | El archivo de configuración no existe. | Detenerse con un mensaje que explique el problema. |
| `test_invalid_json_does_not_expose_contents` | El archivo está mal escrito y no puede leerse como JSON. | Informar el error sin mostrar su contenido ni el token. |
| `test_invalid_token_not_exposed` | El token contiene espacios y tiene un formato inválido. | Rechazarlo sin mostrar su valor en el mensaje. |
| `test_wrong_schema_and_empty_token_rejected` | Falta el token, está vacío o tiene un tipo incorrecto, como un número. | Rechazar la configuración. |

Estas pruebas verifican la lectura del token; no comprueban que la API lo acepte.

### Descarga de datos: `test_extractor.py` — 2 pruebas

| Función de prueba | Situación de ejemplo | Qué debe hacer el programa |
|---|---|---|
| `test_full_cli_writes_gcs_and_complete_resume_does_not_call_api` | La API entrega los datos en varias páginas y luego se repite la misma descarga ya terminada. | Recorrer las páginas correctamente y guardar el resultado. En el ejemplo recibe dos registros de pólizas y 501 siniestros. Al repetir, no vuelve a consultar la API ni cambia el registro de la descarga. |
| `test_http_client_decodes_gzip_with_fixture_response` | La API entrega una respuesta comprimida para reducir su tamaño. | Descomprimirla y recuperar el contenido original. |

La descarga de ejemplo usa siete respuestas simuladas. Cualquier intento de conexión HTTP real durante esa prueba hace que falle.

### Guardado y carga: `test_gcs_pipeline.py` — 11 pruebas

Estas pruebas simulan archivos guardados en GCS y respuestas de BigQuery. Comprueban que el proceso pueda recuperarse y repetirse sin perder información.

| Función de prueba | Situación de ejemplo | Qué debe hacer el programa |
|---|---|---|
| `test_page_and_manifest_round_trip_without_local_directory` | Se guarda una página de datos y después se vuelve a leer. | Recuperar el mismo contenido y la información de avance de la descarga. |
| `test_pending_page_recovers_without_source_api_call` | Una página ya se guardó, pero quedó marcada como pendiente. | Recuperarla de lo guardado, sin pedirla otra vez a la API. |
| `test_prepare_reads_gcs_and_publishes_verified_gcs_files` | Se preparan los archivos para BigQuery y después se daña uno de ellos. | Prepararlos correctamente y detectar el archivo dañado antes de cargarlo. |
| `test_stale_manifest_cannot_overwrite_a_newer_checkpoint` | Un proceso intenta guardar información de avance antigua cuando ya existe una versión más reciente. | Rechazar la escritura para no perder el avance nuevo. |
| `test_error_ledger_preserves_both_entries` | Ocurren dos errores consecutivos. | Conservar ambos en el registro de errores, en su orden original. |
| `test_bigquery_uses_gcs_uri_and_persists_receipt_in_gcs` | Se solicita cargar un archivo en BigQuery. | Indicar el archivo ubicado en GCS y guardar una constancia de carga que identifique la tabla. |
| `test_migrated_snapshot_is_not_loaded_again` | Una descarga figura como ya cargada y las cantidades en destino coinciden. | Comprobar las cantidades y evitar volver a cargarla. |
| `test_migration_confirmation_rejects_missing_destination_rows` | Una descarga figura como ya cargada, pero faltan registros en destino. | Detectar la diferencia y detenerse, en lugar de dar la carga por correcta. |
| `test_preparation_reuses_manifest_without_overwriting_receipts` | Se repite la preparación de archivos de la misma descarga. | Reutilizar lo preparado sin sobrescribir los archivos ni las constancias existentes. |
| `test_preparation_rejects_changed_source_with_same_run_id` | Cambia la información de origen, pero se conserva el mismo identificador de descarga (`run_id`). | Rechazar la preparación para no mezclar dos versiones bajo el mismo identificador. |
| `test_raw_verifier_publishes_gzip_report_without_an_error_ledger` | La descarga no tuvo errores y se genera el informe de verificación. | Publicar igualmente el informe y sus 29 controles de comparación entre origen y destino. |

La última prueba usa respuestas inventadas de BigQuery: comprueba que se genere el informe, no que los 29 controles hayan pasado sobre las tablas reales.

Para verificar conexión, transformaciones SQL y resultados reales se utilizan los ensayos del pipeline, las pruebas SQL y las comparaciones de cantidades descritas en la [guía de ejecución](../../docs/EJECUCION.md#validaciones).

## CI offline con GitHub Actions

El [workflow](../../.github/workflows/ci-offline.yml) corre en cada push y pull request, y permite ejecución manual desde [Actions → CI offline](https://github.com/isardi4/assist-365/actions/workflows/ci-offline.yml) → **Run workflow**. En Ubuntu, con Python 3.10 y 3.13, revisa problemas de espacios en los cambios, comprueba que los scripts Python estén escritos con sintaxis válida y ejecuta las veinte pruebas. No ejecuta el pipeline, consultas SQL ni llamadas a la API/GCS/BigQuery.

Además de los tests, el workflow ejecuta dos controles independientes:

| Control | Qué detecta y qué no verifica |
|---|---|
| `python -m compileall -q scripts` | Detecta errores de sintaxis Python, como un `:` faltante después de un `if`. No ejecuta el pipeline ni valida lógica SQL. |
| `git diff --check` | Detecta problemas de espacios en los cambios, como espacios al final de una línea y marcadores de conflicto introducidos. No evalúa la lógica ni el formato SQL completo. |

En Actions, abrir una ejecución y luego el bloque de Python 3.10 o 3.13 para ver las pruebas y su resultado. El color rojo indica un error que debe corregirse; el verde confirma que estos controles pasaron. El resultado informa el estado, pero no bloquea automáticamente la incorporación de cambios al repositorio.

Para reproducir los controles desde la raíz, con Python 3.10 o superior:

```bash
python3 -m compileall -q scripts
python3 -m unittest discover -s scripts/bonus -p 'test_*.py' -v
git diff --check
```

El último comando revisa los cambios locales sin preparar; el CI compara los commits del push o del pull request. Las pruebas SQL permanecen manuales para conservar el CI independiente del acceso al proyecto cloud.

Verificación publicada: [CI exitoso del 30/09/2026](https://github.com/isardi4/assist-365/actions/runs/36792623622), con veinte pruebas aprobadas en cada versión de Python, sintaxis y diff correctos.
