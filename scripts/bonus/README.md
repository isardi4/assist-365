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

Los tres archivos contienen **20 pruebas**. Cada test construye un escenario conocido, ejecuta código del proyecto y compara el resultado con lo esperado. Una prueba también aprueba cuando el código rechaza correctamente un caso inválido, como un archivo corrupto. Si no obtiene el resultado esperado, el comando termina con error y el job del CI falla.

### Configuración: `test_api_token.py` — 7 pruebas

Usa valores ficticios, variables de entorno aisladas y archivos temporales.

| Prueba | Escenario y resultado esperado |
|---|---|
| `test_environment_takes_precedence` | Token en el entorno y archivo inexistente: devuelve el token del entorno. |
| `test_explicit_config` | Selecciona un JSON con `ASSIST365_CONFIG_FILE`: devuelve su token. |
| `test_default_config` | Sin variables de entorno, usa la ruta predeterminada, sustituida por un archivo temporal. No valida el token real versionado. |
| `test_missing_config_has_safe_error` | Archivo inexistente: devuelve un error de configuración comprensible. |
| `test_invalid_json_does_not_expose_contents` | JSON incompleto: falla sin revelar el contenido sensible ficticio. |
| `test_invalid_token_not_exposed` | Token con espacios: lo rechaza sin mostrar su valor en el error. |
| `test_wrong_schema_and_empty_token_rejected` | Rechaza una lista, un objeto sin token, un token numérico y uno vacío. |

Comprueba selección y validación de configuración; no verifica que la API acepte el token.

### Extracción: `test_extractor.py` — 2 pruebas

| Prueba | Escenario y resultado esperado |
|---|---|
| `test_full_cli_writes_gcs_and_complete_resume_does_not_call_api` | API y GCS simulados: captura tres catálogos, dos páginas de pólizas y dos de siniestros. Verifica `SUCCESS`, siete solicitudes, dos registros de pólizas, 501 siniestros, cursor y offsets `0`/`500`. Al repetir, conserva el manifiesto y no crea otro cliente API. |
| `test_http_client_decodes_gzip_with_fixture_response` | Respuesta HTTP ficticia comprimida: devuelve el contenido original descomprimido y código `200`. |

La primera prueba bloquea cualquier solicitud HTTP real: un intento de conexión hace fallar el test.

### Almacenamiento y carga: `test_gcs_pipeline.py` — 11 pruebas

`MemoryGCS` representa un bucket en memoria con objetos y generaciones; las llamadas a `bq` también se simulan. Permite probar recuperaciones y conflictos sin servicios externos.

| Prueba | Escenario y resultado esperado |
|---|---|
| `test_page_and_manifest_round_trip_without_local_directory` | Guarda y recupera página gzip y manifiesto: conserva contenido, conteo y ruta GCS. |
| `test_pending_page_recovers_without_source_api_call` | Página guardada marcada como pendiente: la recupera sin llamar a la API. |
| `test_prepare_reads_gcs_and_publishes_verified_gcs_files` | Prepara archivos desde raw: verifica URI GCS, contenido e integridad. Después corrompe un archivo y comprueba que sea rechazado. |
| `test_stale_manifest_cannot_overwrite_a_newer_checkpoint` | Intenta escribir desde una versión antigua del manifiesto: rechaza sobrescribir la versión más reciente. |
| `test_error_ledger_preserves_both_entries` | Agrega dos errores: conserva ambos y su orden. |
| `test_bigquery_uses_gcs_uri_and_persists_receipt_in_gcs` | Carga simulada exitosa: el comando recibe la URI GCS y el recibo guardado identifica la tabla. |
| `test_migrated_snapshot_is_not_loaded_again` | Lote marcado como migrado y conteos coincidentes: verifica destino sin invocar otra carga. |
| `test_migration_confirmation_rejects_missing_destination_rows` | Lote marcado como migrado, pero sin filas esperadas en destino: falla por diferencia de conteos. |
| `test_preparation_reuses_manifest_without_overwriting_receipts` | Repite preparación de un lote existente: mantiene la ruta y todos los objetos sin cambios. |
| `test_preparation_rejects_changed_source_with_same_run_id` | Cambia la huella de una página de origen bajo el mismo `run_id`: rechaza la preparación y conserva los objetos existentes. |
| `test_raw_verifier_publishes_gzip_report_without_an_error_ledger` | Captura sin archivo de errores y respuestas BigQuery simuladas: publica reporte `PASS` y archivo gzip con 29 conciliaciones. |

La última prueba verifica el funcionamiento del verificador y la publicación del reporte; no acredita 29 conciliaciones contra BigQuery real.

Estas pruebas no descargan datos reales ni requieren credenciales Google, token API, paquetes externos o conexión a esos servicios. Verifican comportamientos controlados del código. La conectividad se comprueba con ensayos de ejecución; las transformaciones y resultados del warehouse, con validaciones SQL y conciliaciones reales.

## CI offline con GitHub Actions

El [workflow](../../.github/workflows/ci-offline.yml) corre en cada push y pull request, y permite ejecución manual desde [Actions → CI offline](https://github.com/isardi4/assist-365/actions/workflows/ci-offline.yml) → **Run workflow**. En Ubuntu, con Python 3.10 y 3.13, valida el diff (espacios sobrantes y errores de whitespace), compila los scripts para detectar errores de sintaxis y ejecuta las veinte pruebas. No ejecuta el pipeline, consultas SQL ni llamadas a la API/GCS/BigQuery.

Además de los tests, el workflow ejecuta dos controles independientes:

| Control | Qué detecta y qué no verifica |
|---|---|
| `python -m compileall -q scripts` | Detecta errores de sintaxis Python, como un `:` faltante después de un `if`. No ejecuta el pipeline ni valida lógica SQL. |
| `git diff --check` | Detecta problemas de espacios en los cambios, como espacios al final de una línea y marcadores de conflicto introducidos. No evalúa la lógica ni el formato SQL completo. |

En Actions, abrir una ejecución y luego cada job para ver las pruebas y su resultado. Un job rojo indica un error que debe corregirse; un job verde confirma estos controles offline. Esto no configura una restricción de merge en GitHub.

Para reproducir los controles desde la raíz, con Python 3.10 o superior:

```bash
python3 -m compileall -q scripts
python3 -m unittest discover -s scripts/bonus -p 'test_*.py' -v
git diff --check
```

El último comando revisa los cambios locales sin preparar; el CI compara los commits del push o del pull request. Las pruebas SQL permanecen manuales para conservar el CI independiente del acceso al proyecto cloud.

Verificación publicada: [CI exitoso del 30/09/2026](https://github.com/isardi4/assist-365/actions/runs/36792623622), con veinte pruebas aprobadas en cada versión de Python, sintaxis y diff correctos.
