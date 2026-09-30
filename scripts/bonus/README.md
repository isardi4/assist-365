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

[Requisitos y comandos para ejecutarlas](../../docs/EJECUCION.md#validaciones). Las pruebas SQL se ejecutan manualmente; para configuración API usar `python3 -m unittest scripts.bonus.test_api_token`. No hay workflow de GitHub Actions.

Se entrega una [skill de análisis](../../SKILL.md) con glosario, tablas/granos, métricas, reglas de población/FX y cinco preguntas de ejemplo. Para usarla, indicar al asistente que lea `SKILL.md` y consulte BigQuery con esas definiciones. El archivo está versionado en el repositorio; su instalación y conexión dependen del entorno del asistente. **El bonus semántico está parcial:** las cinco preguntas todavía no tienen ejecuciones verificadas vía MCP. Una ejecución con `bq` no acredita ese requisito. CI y video no se implementaron.

Las pruebas offline de almacenamiento cubren páginas/checkpoints en GCS, recuperación sin API, conflictos de generación, integridad de preparación, ledger de errores, URI de carga y omisión de snapshots ya migrados:

```bash
python3 -m unittest discover -s scripts/bonus -p 'test_*.py'
```
