# Guía de documentación

| Documento | Situación de ejemplo | Qué explica |
|---|---|---|
| [README principal](../../README.md) | Se recibe el repositorio y se quiere entender el alcance de la entrega. | Arquitectura, partes implementadas y pendientes, decisiones del modelo y acceso al dashboard. |
| [Ejecución](../../docs/EJECUCION.md) | Se quiere correr el proyecto por primera vez o repetir una carga. | Requisitos, autenticación, comandos en orden y validaciones. |
| [Modelo](../parte_03_modelo_bigquery/README.md) | Se quiere entender qué SQL carga staging y cuál publica gold. | Tablas, cambios de registros y propósito de cada archivo del modelo. |
| [Análisis](../parte_05_analisis/README.md) | Se necesita comparar países, planes o canales. | Dos queries mensuales, reglas de cálculo y ejemplos de interpretación. |
| [Tablero](../parte_06_tablero/README.md) | Se quiere usar los gráficos o revisar cuánto consumen sus consultas. | Filtros, fórmulas, límites de interpretación y medición de consumo. |
| [Anomalías](../../README.md#anomalías-y-tratamiento) | Se encuentra un importe negativo o una moneda ausente. | Hallazgos, tratamiento aplicado y alcance de las exclusiones. |
| [Bonus](../bonus/README.md) | Se quiere saber qué comprueba el CI y cómo ejecutar las pruebas. | Escenarios de las 20 pruebas offline, validaciones SQL y controles automáticos. |

Los README de cada capa describen su grano, ejecución y decisiones técnicas. Los archivos fuente y credenciales de Google Cloud quedan fuera del repositorio. El token del challenge se incluye en `config/assist365.json` para ejecutar el extractor desde un clon; consultar el análisis solo requiere acceso al warehouse existente.

Se utilizó asistencia de IA para elaborar código, SQL y documentación. La validación se realizó mediante ejecuciones en BigQuery, conciliaciones y pruebas con tablas temporales.

## Uso de IA

Se trabajó por etapas: primero contratos y extracción, después cargas/modelo y finalmente análisis/documentación. Se aportaron como contexto el ejercicio, la planificación y el código existente; las decisiones se contrastaron con los datos y las ejecuciones, en vez de aceptar resultados solo por su redacción.

Ejemplos de instrucciones utilizadas, resumidas: generar dos queries mensuales desde staging por país/plan y país/canal; incluir la moneda inferida válida y excluir importes negativos; atribuir prima y siniestros a cohortes de emisión; probar el proyecto desde un clon sin datos locales. La IA ayudó a implementar esas reglas, localizar fallas y escribir pruebas y documentación. Los resultados publicados se respaldan con evidencia SQL y reportes de ejecución.
