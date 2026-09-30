# Bonus — pruebas de datos y alcance

Se implementaron pruebas en SQL nativo de BigQuery y conciliaciones en los ejecutores. No requieren dbt ni otro framework. Las pruebas funcionales usan tablas temporales y no modifican tablas de negocio.

| Validación | Alcance |
|---|---|
| [Incremental staging](../parte_03_modelo_bigquery/sql/012_incremental_tests.sql) | I/U/D, llegada tardía, repetición, correcciones, ausencias, catálogos y rollback. |
| [Flags de siniestros](../parte_03_modelo_bigquery/claims_audit/flag_tests.sql) | Ocho casos de inferencia, exclusión monetaria y conservación de originales. |
| [Gold](../parte_03_modelo_bigquery/gold/sql/006_functional_tests.sql) | 21 pruebas de población, atribución de cohortes, conversiones y agregación sin duplicar primas. |
| [Configuración API](test_api_token.py) | Siete pruebas de selección del token, formato y errores sin revelar valores; sin llamadas de red. |
| Conciliaciones | 29 controles raw, 13 staging y 24 gold para comprobar las publicaciones. |

[Requisitos y comandos para ejecutarlas](../../docs/EJECUCION.md#validaciones). Las pruebas SQL se ejecutan manualmente; para configuración API usar `python3 -m unittest scripts.bonus.test_api_token`. No hay workflow de GitHub Actions.

La capa semántica con SKILL.md y cinco preguntas vía MCP, CI y video no se implementaron. Se priorizó validar las métricas y completar el dashboard antes de sumar estas capacidades. Las definiciones de negocio están en el [README principal](../../README.md#capa-gold).
