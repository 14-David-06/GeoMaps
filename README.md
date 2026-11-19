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

En el iPhone, sin cuenta de Apple Developer, GeoMaps se instala desde Safari
como app web (PWA): el mismo codigo Flutter compilado para el navegador y
servido por el backend en `/geomaps/`. Ver [`docs/pwa/README.md`](docs/pwa/README.md).

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
| Mapas offline | **Cache de flutter_map** + **MBTiles** (pendiente) | La zona del satelite que se baja queda en la misma cache de la que el mapa lee sin senal; el MBTiles es el mapa pesado que trae el usuario, todavia sin implementar |
| Reproyeccion | **proj4dart** | Un GeoPDF de topografia casi nunca viene en Web Mercator |
| BD local | **Drift / SQLite** | Waypoints, trazados y el catalogo de capas. Fuente de verdad mientras no hay red |
| GPS | **geolocator**, como servicio en primer plano mientras graba | El trazado sigue grabando con la pantalla apagada |
| Geometria | `core/geo.dart` | Haversine y area sobre WGS84, portado de `sirius_agro` |
| Ruteo | `core/ruteo.dart` | Grafo y Dijkstra sobre las vias del predio, adentro del telefono: en Guaicaramo no hay senal para consultarle la ruta a nadie, y ningun servicio de ruteo conoce las vias internas de una plantacion |
| Voz | **flutter_tts** | El sintetizador del telefono, que habla sin red si la voz en espanol esta instalada. Quien maneja no puede leer la pantalla, y muchos de quienes usan la app no ven bien |
| Export | `core/kml.dart`, `core/gpx.dart` | KML 2.2 y GPX 1.1 escritos a mano; son XML plano |
| PDF | **pdf** | El informe de un levantamiento, armado en el telefono con las fuentes que trae el formato: sin red y sin empaquetar nada |
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

Cada push a `main` y cada pull request corren el analisis y las pruebas de
la app y del backend en GitHub (`.github/workflows/pruebas.yml`). Corren sin
los datos del predio y sin ninguna llave, igual que un clon recien hecho.

Por defecto la app apunta al backend desplegado:
`https://geo-maps-seven.vercel.app`. Para trabajar contra el backend local se
cambia `API_BASE` en `dart_defines.json` (o se pasa
`--dart-define=API_BASE=http://10.0.2.2:8000`); `10.0.2.2` es como el emulador
de Android ve el `localhost` de la maquina, y un celular fisico por USB usa
`http://127.0.0.1:8000` con `adb reverse tcp:8000 tcp:8000`.

## Estado

**Anda hoy, sin senal salvo donde se dice:**

| Que | Donde |
|---|---|
| Entrar con Google o con correo y clave; la sesion dura 30 dias y se renueva sola al abrir la app con senal | `state/sesion.dart`, `POST /v1/sesion/renovar` |
| Si la sesion vence estando sin senal, **la persona sigue adentro** y trabaja con lo que hay en el telefono; el inicio le avisa que nada sube hasta que entre de nuevo | `state/sesion.dart`, `ui/home_page.dart` |
| Al cerrar sesion con registros sin subir o un recorrido abierto, avisa y ofrece subirlos ahi mismo | `ui/cerrar_sesion.dart` |
| Letra grande y alto contraste en toda la app, para quien no ve bien: nada por debajo de 15, botones de 52 de alto, y ninguna pantalla se desborda con la letra del telefono al 130%. En el mapa, los botones se apoyan arriba de la tarjeta de abajo midiendola (`ui/mapa/medido.dart`): con la letra agrandada la tarjeta crece y antes los tapaba | `ui/theme.dart`, `test/letra_grande_test.dart` |
| Mapa satelital y de calles con la posicion, la precision, la escala y el giro tipo navegador. La pantalla (`ui/mapa_page.dart`) decide que se dibuja y que tarjeta va abajo; lo demas esta en piezas sueltas en `ui/mapa/`: la camara que sigue a la posicion (`seguidor.dart`), la barra del GPS, los botones y las hojas de herramientas y de cuenta. La pantalla entera se abre en una prueba, con una ubicacion de mentira: que llegue el fix, que se trace y se suelte la ruta, y que al salir no quede nada colgado | `ui/mapa_page.dart`, `ui/mapa/`, `test/mapa_page_test.dart` |
| Mapa de Guaicaramo: lotes, vias, acopios, y ruta por las vias con recalculo. La ruta del mapa -trazarla, seguirla, decirla, guardarla, calificarla- no necesita la pantalla para andar y tiene sus pruebas | `core/ruteo.dart`, `ui/mapa/navegacion.dart`, `test/navegacion_mapa_test.dart` |
| Buscar un acopio por su numero y elegir el bloque con un toque, en letra grande y con el mas cercano primero | `ui/capa_acopios.dart` |
| Planos de topografia y **PDF cartograficos** (vias, planchas) importados como capa: lee la georreferencia de Adobe y la de TerraGo, tambien en archivos comprimidos o de varias hojas, y al terminar encuadra el mapa sobre el plano | `core/geopdf.dart`, `ui/importar_mapa_page.dart` |
| **Las hojas grandes se leen de cerca**: un pliego entra como una imagen de 4096 pixeles, que son menos de 90 puntos por pulgada y deja los rotulos hechos una mancha. A esas hojas se les dibuja ademas el **detalle** -la misma hoja al doble, en cuadros de 1024- de fondo, con el plano ya puesto en el mapa; de cerca se ponen solo los cuadros que caen en la pantalla. Si la app se cierra en la mitad, sigue la proxima vez. No se le hace a un plano que ya salio nitido ni a una ortofoto | `core/detalle_plano.dart`, `state/afinado.dart`, `ui/capa_pdf.dart` |
| **Bajar una zona del satelite** para verla sin senal (necesita red para bajarla) | `ui/descargar_region_page.dart` |
| Donde el satelite no tiene imagen del nivel pedido (el cartel "Map data not yet available") o no hay senal, el mapa muestra la del nivel anterior ampliada | `core/fuente_teselas.dart` |
| **El mapa no espera a la red**: cada imagen aparece en el acto con lo que el telefono tenga guardado -aunque este vencida o sea la del nivel de arriba- y se cambia sola por la buena cuando la red contesta. Con una raya de senal abre igual de rapido que con wifi | `core/fuente_teselas.dart`, `ui/proveedor_teselas.dart` |
| **Iniciar una ruta** y, al llegar o terminarla, **calificar** de 1 a 5 el camino por donde se paso; la nota queda con el recorrido grabado | `ui/calificar_ruta.dart` |
| **Indicaciones habladas** en una ruta iniciada: el giro que viene ("en 150 metros, gira a la derecha"), cuanto falta y la llegada, con la voz del telefono y sin red. En una vuelta de camion avisa al llegar a los vagones y al volver. Se apaga con el parlante | `core/indicaciones.dart`, `core/voz.dart` |
| **Grabar un recorrido** con la pantalla apagada, y verlo dibujarse | `state/grabacion.dart` |
| **Proyectos**: se elige en cual se trabaja y lo que se levante -recorridos, areas, puntos y fotos- queda en ese, en el telefono y en Airtable. Se crean sin senal y suben antes que lo que cuelga de ellos | `state/proyecto_activo.dart`, `ui/proyectos_page.dart` |
| **Marcar puntos** con simbolo y nota, con el GPS o a mano | `ui/waypoint_page.dart` |
| **Fotos en los puntos**: se toman en el lote, achicadas para que suban por red rural, y se ven desde la tarjeta del punto. Suben solas despues de su punto, directo al bucket con una URL que firma el backend | `ui/fotos_punto.dart`, `data/archivos_repository.dart`, `POST /v1/fotos` |
| **Medir** distancia y area sobre el mapa, y guardar el area | `ui/medicion.dart` |
| **Compartir** recorridos, areas y puntos como KML, GPX o GeoJSON | `core/exportador.dart` |
| **Informe PDF** de un area o un recorrido, para imprimir o mandar a quien no usa mapas: las medidas, la forma a escala con el norte, los puntos marcados y -como nota, no en letra chica- con que precision se levanto | `core/informe_pdf.dart` |
| Subir recorridos, areas, rutas y puntos a Airtable y S3 al volver la red | `state/sincronizador.dart` |
| Anotar en el telefono los fallos de la app -con la version y el modelo del telefono- y subirlos a la tabla `Errores` al volver la red | `core/errores.dart`, `POST /v1/errores` |
| Camiones: escanear el QR y tomar una vuelta firmando solo con la clave (sin cedula). **Una vuelta a la vez**: hay que llegar a los vagones y volver al punto de salida para finalizarla, y hasta entonces no se toma otra. Cada paso -tomada, llegada, regreso, finalizada- queda en la tabla `Vueltas` (tomar y devolver necesitan senal; lo demas funciona sin ella) | `lib/camiones/`, `backend/app/services/viajes.py` |

**Falta:**

- **MBTiles** propios (el mapa pesado que convierte el backend) y su descarga.
- Las fotos adentro de lo que se comparte (KMZ) y del informe PDF.
- Bajar a un telefono los proyectos que ya estan en Airtable (`GET /v1/proyectos`): hoy suben, pero quien cambia de telefono no los ve.
- Recuperacion de clave y verificacion de correo (ver `docs/arquitectura.md`).

## Autoria y propiedad

- **Autor intelectual:** David Hernandez
- **Titular de los derechos:** Sirius Regenerative Solutions S.A.S ZOMAC

Software propietario. Todos los derechos reservados; ver [LICENSE](LICENSE).
