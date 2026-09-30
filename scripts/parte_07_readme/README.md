# Guía de documentación

| Documento | Contenido |
|---|---|
| [README principal](../../README.md) | Arquitectura, acceso al dashboard y decisiones del modelo. |
| [Ejecución](../../docs/EJECUCION.md) | Requisitos, autenticación, comandos y pruebas reproducibles. |
| [Análisis](../parte_05_analisis/README.md) | Dos queries mensuales e interpretación de resultados. |
| [Tablero](../parte_06_tablero/README.md) | Captura, filtros, métricas y límites de interpretación. |
| [Anomalías](../../README.md#anomalías-y-tratamiento) | Hallazgos, tratamiento y alcance de las exclusiones. |

Los README de cada capa describen su grano, ejecución y decisiones técnicas. Los archivos fuente y credenciales de Google Cloud quedan fuera del repositorio. El token del challenge se incluye en `config/assist365.json` para ejecutar el extractor desde un clon; consultar el análisis solo requiere acceso al warehouse existente.

Se utilizó asistencia de IA para elaborar código, SQL y documentación. La validación se realizó mediante ejecuciones en BigQuery, conciliaciones y pruebas con tablas temporales.
