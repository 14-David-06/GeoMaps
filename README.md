# GeoMaps — mapas georreferenciados offline

App movil tipo **Avenza Maps** para el equipo de campo de Sirius: cargar un mapa
propio (un plano de predio, un levantamiento topografico, una imagen satelital
procesada), verlo **sin senal** y saber en que punto de ese mapa estas parado.

```
app/       Flutter — Android (APK), iOS, y escritorio para pruebas
backend/   FastAPI — convierte mapas, guarda archivos y habla con Airtable
tools/     GDAL — GeoPDF/GeoTIFF -> MBTiles (corre en el servidor, no en el telefono)
docs/      Modelo de datos y despliegue
```

## Que resuelve

Un tecnico en un potrero de Guaicaramo, sin datos, tiene que:

1. **Ver el plano del predio** que le mando topografia, no un mapa generico.
2. **Verse a si mismo** sobre ese plano, con la precision del GPS a la vista.
3. **Llegar** hasta un punto: marca el destino en el mapa y la app traza por
   donde se va **por las vias del predio**, no en linea recta, y la recalcula
   sola si agarro otro camino.
4. **Marcar** puntos (waypoints), **grabar** por donde camino (trazado) y
   **medir** el area de un lote.
5. **Entregar** eso como KML/GPX que abra Google Earth o QGIS, y como PDF.
6. Que todo eso **aparezca en Airtable** cuando el telefono vuelva a tener red.

Los pasos 1-5 funcionan en modo avion. El 6 es el unico que necesita senal, y
la app nunca lo espera: el dato se guarda local primero y se sincroniza despues.

## Stack

| Capa | Tecnologia | Por que |
|---|---|---|
| App | **Flutter 3 + Riverpod 2** | Un solo codigo, APK directo, y es lo que el equipo ya escribe en `sirius_agro` |
| Mapa | **flutter_map 8** | Raster, sin llave, y deja superponer capas del usuario sin pelear con un motor de estilos |
| Mapas offline | **MBTiles** (SQLite) + **FMTC** | El MBTiles es el mapa que trae el usuario; FMTC cachea las regiones que se bajan de un servidor |
| Reproyeccion | **proj4dart** | Un GeoPDF de topografia casi nunca viene en Web Mercator |
| BD local | **Drift / SQLite** | Waypoints, trazados y el catalogo de capas. Fuente de verdad mientras no hay red |
| GPS | **geolocator + flutter_foreground_task** | El trazado sigue grabando con la pantalla apagada |
| Geometria | `core/geo.dart` | Haversine y area sobre WGS84, portado de `sirius_agro` |
| Ruteo | `core/ruteo.dart` | Grafo y Dijkstra sobre las vias del predio, adentro del telefono: en Guaicaramo no hay senal para consultarle la ruta a nadie, y ningun servicio de ruteo conoce las vias internas de una plantacion |
| Export | `core/kml.dart`, `core/gpx.dart` | KML 2.2 y GPX 1.1 escritos a mano; son XML plano |
| PDF | **pdf + printing** | Entregable impreso con la marca Sirius |
| Identidad | **Correo + clave, o Google Sign-In** | Registro abierto por dos puertas. El backend verifica el ID token contra el JWKS de Google, o la clave contra un hash bcrypt, y guarda al usuario en Airtable: ningun proveedor de identidad extra. La puerta de clave existe porque Google Sign-In depende de los servicios de Google Play, que en los telefonos de campo no siempre estan sanos |
| Backend | **FastAPI** en Vercel | Guarda las llaves y aisla los datos de cada cuenta. La app nunca ve el token de Airtable ni las de AWS |
| Registro | **Airtable** | Usuarios, proyectos, mapas, trazados, waypoints y archivos generados |
| Archivos | **AWS S3** (privado) | MBTiles, geometrias, KML, GPX, PDF y fotos. Se accede por URL prefirmada; el APK nunca lleva credenciales de AWS |
| Teselas base | **Esri World Imagery / OSM** | Sin llave y sin facturacion: el mapa no puede quedarse en blanco porque vencio una tarjeta |

## Por que Airtable y no Postgres

Porque el dato de campo lo consume gente, no un servicio: coordinacion abre la
base y ve que predios se levantaron esta semana. Airtable es la capa de
**registro y consulta humana**; la fuente de verdad operativa mientras el
telefono esta en el potrero es el SQLite local. El backend concilia las dos.

Lo que **no** va a Airtable es lo que puede crecer sin techo. Un MBTiles de
400 MB no es un adjunto, y el GeoJSON de un trazado tampoco cabe en un
`Long text` de 100.000 caracteres cuando la jornada se grabo cada 5 segundos.
Todo eso vive en **AWS S3** y Airtable guarda la llave, mas lo que hace
consultable la fila sin bajar nada: bbox, centroide, area, precision y una
vista previa simplificada.

Ver [`docs/airtable-schema.md`](docs/airtable-schema.md).

## Puesta en marcha

```bash
# Backend
cd backend
python -m venv .venv && .venv/Scripts/activate
pip install -e ".[dev]"
cp .env.example .env            # completar llaves
uvicorn app.main:app --reload --port 8000

# App
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # genera drift
flutter run --dart-define-from-file=dart_defines.json
```

Por defecto la app apunta al backend desplegado:
`https://geo-maps-seven.vercel.app`. Para trabajar contra el backend local se
cambia `API_BASE` en `dart_defines.json` (o se pasa
`--dart-define=API_BASE=http://10.0.2.2:8000`); `10.0.2.2` es como el emulador
de Android ve el `localhost` de la maquina, y un celular fisico por USB usa
`http://127.0.0.1:8000` con `adb reverse tcp:8000 tcp:8000`.

## Estado

Estructura inicial. Ningun modulo esta implementado todavia: los archivos de
`app/lib` y `backend/app` llevan el contrato que cada uno tiene que cumplir y
un `TODO` donde va el cuerpo.

## Autoria y propiedad

- **Autor intelectual:** David Hernandez
- **Titular de los derechos:** Sirius Regenerative Solutions S.A.S ZOMAC

Software propietario. Todos los derechos reservados; ver [LICENSE](LICENSE).
