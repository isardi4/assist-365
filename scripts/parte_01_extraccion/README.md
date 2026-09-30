# Extracción de la API

Descarga pólizas, siniestros, agencias, productos y tipos de cambio mediante paginación. Guarda respuestas gzip, checksums, manifiesto, checkpoints y errores bajo `.local_data/assist365/raw/<run-id>/`, fuera de Git.

## Uso y recuperación

Desde la raíz del repositorio, con Python 3.10+. El extractor lee el token incluido en [config/assist365.json](../../config/assist365.json), por lo que un clon no necesita un archivo local adicional:

```bash
python3 -m scripts.parte_01_extraccion.run --full --run-id <nuevo-run-id>
```

`--full` solicita el snapshot completo. Sin esa opción, el valor predeterminado es **una página por recurso**, adecuado para una prueba acotada. El cliente espera al menos un segundo entre solicitudes y permite hasta seis reintentos por solicitud.

Repetir un `run_id` reanuda sus checkpoints; una captura nueva requiere otro identificador. El extractor obtiene snapshots: no implementa delta por `updated_since`. La reconstrucción desde archivos existentes y el análisis en BigQuery no necesitan repetir la extracción.

## Datos de referencia

| Recurso | Registros descargados |
|---|---:|
| Pólizas | 1.003.461 |
| Siniestros | 138.962 |
| Agencias | 300 |
| Productos | 12 |
| Tipo de cambio | 5.124 |

El snapshot `smoke-20260929` conserva **1.147.859 registros** y fue conciliado en [raw](../parte_02_carga_bigquery/README.md). Las variaciones de nombres y valores no finitos se preservan; su interpretación se resuelve en staging, según la [documentación de anomalías](../../README.md#anomalías-y-tratamiento).

`api/` contiene el cliente HTTP y `extractor/` implementa paginación y persistencia. [Requisitos y reproducción](../../docs/EJECUCION.md).

`ASSIST365_API_TOKEN` permite reemplazar el valor configurado y `ASSIST365_CONFIG_FILE` seleccionar otro JSON. El Markdown del ejercicio no se lee durante la ejecución. Este token solo autentica la API; BigQuery utiliza la identidad de Google Cloud CLI.
