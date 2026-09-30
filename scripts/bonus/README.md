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

Cada test construye un escenario conocido, ejecuta código del proyecto y compara el resultado con lo esperado. Si una modificación rompe ese comportamiento, la prueba falla y el comando termina con error.

- `test_api_token.py`: comprueba cómo se selecciona y valida el token, con configuraciones temporales y valores ficticios.
- `test_extractor.py`: simula respuestas paginadas de la API y verifica extracción, gzip y repetición de una captura completa sin volver a consultar la fuente.
- `test_gcs_pipeline.py`: usa un almacenamiento en memoria y llamadas BigQuery simuladas para verificar checkpoints, integridad, recuperación y cargas repetidas. Por ejemplo, rechaza sobrescribir un checkpoint con una generación desactualizada.

No descargan datos reales ni requieren credenciales Google, token API, paquetes externos o conexión a esos servicios. Verifican el comportamiento del código ante casos controlados; la disponibilidad de la fuente y los resultados del warehouse se comprueban mediante las validaciones SQL y los ensayos de ejecución documentados.

## CI offline con GitHub Actions

El [workflow](../../.github/workflows/ci-offline.yml) corre en cada push y pull request, y permite ejecución manual desde [Actions → CI offline](https://github.com/isardi4/assist-365/actions/workflows/ci-offline.yml) → **Run workflow**. En Ubuntu, con Python 3.10 y 3.13, valida el diff (espacios sobrantes y errores de whitespace), compila los scripts para detectar errores de sintaxis y ejecuta las veinte pruebas. No ejecuta el pipeline, consultas SQL ni llamadas a la API/GCS/BigQuery.

En Actions, abrir una ejecución y luego cada job para ver las pruebas y su resultado. Un job rojo indica un error que debe corregirse; un job verde confirma estos controles offline. Esto no configura una restricción de merge en GitHub.

Para reproducir los controles desde la raíz, con Python 3.10 o superior:

```bash
python3 -m compileall -q scripts
python3 -m unittest discover -s scripts/bonus -p 'test_*.py' -v
git diff --check
```

El último comando revisa los cambios locales sin preparar; el CI compara los commits del push o del pull request. Las pruebas SQL permanecen manuales para conservar el CI independiente del acceso al proyecto cloud.
