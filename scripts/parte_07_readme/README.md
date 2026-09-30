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

## Uso de IA

Se trabajó por etapas: primero contratos y extracción, después cargas/modelo y finalmente análisis/documentación. Se aportaron como contexto el ejercicio, la planificación y el código existente; las decisiones se contrastaron con los datos y las ejecuciones, en vez de aceptar resultados solo por su redacción.

Ejemplos de instrucciones utilizadas, resumidas: generar dos queries mensuales desde staging por país/plan y país/canal; incluir la moneda inferida válida y excluir importes negativos; atribuir prima y siniestros a cohortes de emisión; probar el proyecto desde un clon sin datos locales. La IA ayudó a implementar esas reglas, localizar fallas y escribir pruebas y documentación. Los resultados publicados se respaldan con evidencia SQL y reportes de ejecución.
