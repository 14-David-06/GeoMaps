# Datos de predios — no se versionan

Los archivos `*.json` de esta carpeta son **confidenciales** y por eso no estan
en el repositorio, que es publico. Son datos del cliente, no nuestros: dicen
donde estan sus cultivos, por donde se entra y cuanto tiene sembrado.

Esta carpeta existe en git para que el proyecto **compile sin ellos**. Sin los
datos la app arranca igual y el mapa del predio queda marcado como no
disponible; no se rompe nada.

## Para compilar con los datos reales

Se piden las fuentes a coordinacion —el plano del Departamento Agronomico y el
KMZ de topografia— y se corren los generadores:

```bash
pip install pypdf shapely

python tools/perimetro_guaicaramo.py "<ruta>/Acopios Guaicaramo 2026.pdf"
python tools/parcelas_guaicaramo.py  "<ruta>/Acopios Guaicaramo 2026.pdf"
python tools/vias_guaicaramo.py      "<ruta>/vias.kmz"
python tools/acopios_guaicaramo.py   # lee map-security/public/acopios-guaicaramo.geojson
```

Cada uno imprime sus propios controles de calidad al terminar. `tools/README.md`
explica de donde sale cada dato y como se verifica.

**Las fuentes tampoco van al repositorio.** El `.gitignore` ya bloquea los `.kmz`
y los planos en PDF, pero conviene no dejarlos dentro de la carpeta del proyecto.

## Cuidado con el APK

Estos datos viajan **adentro del APK** y de ahi se pueden extraer con
herramientas comunes. Que no esten en el repositorio protege el codigo fuente,
no el instalador: un APK con estos datos se entrega solo a quien corresponde.
