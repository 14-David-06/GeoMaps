# Arquitectura

## El principio que ordena todo: el potrero no tiene senal

Cada decision de abajo sale de la misma regla. **Nada de lo que el tecnico hace
en campo puede depender de una respuesta del servidor.** El backend existe para
guardar llaves, convertir mapas pesados y publicar en Airtable — tres cosas que
pueden esperar a que haya cobertura.

Consecuencias directas:

- SQLite local es la **fuente de verdad** mientras la visita ocurre.
- Airtable es el **registro**, no la base operativa.
- Todo id lo genera el telefono (UUID v4), no Airtable.
- La app arranca y funciona con el backend caido.
- **La sesion guardada manda.** Un JWT vence en una hora y refrescarlo necesita
  red. Exigir un token valido para abrir la app seria pedir login justo en el
  unico lugar donde no se puede hacer.
- **Una sesion vencida tambien entra.** El JWT propio dura 30 dias y se renueva
  solo cada vez que la app ve senal, asi que solo vence a quien paso un mes sin
  cobertura: justo quien no puede volver a entrar. La app lo deja adentro,
  trabajando con lo que hay en el telefono, y le avisa que nada sube hasta que
  entre de nuevo (`EstadoSesion.vencida`). El servidor rechaza el token vencido
  como siempre; lo que cambia es que el telefono no se bloquea. Lo unico que
  saca a alguien de la app es cerrar sesion, o que la cuenta ya no exista o
  este suspendida cuando se intenta renovar.

## Identidad: registro abierto

GeoMaps no es una app interna de Sirius, asi que la identidad no sale de la
nomina: cualquiera crea la suya. Se entra por dos puertas y no hay proveedor de
identidad de por medio — el backend verifica el ID token contra el **JWKS
publico de Google**, o la clave contra un **hash bcrypt**, y guarda la persona
en Airtable, que es la unica plataforma que el equipo opera.

| Puerta | Credencial | `Auth UID` |
|---|---|---|
| Google | ID token firmado por Google | el `sub` del token |
| Correo | correo + clave | `pwd_<uuid4>` |

**Por que las dos y no solo Google.** Google Sign-In necesita los servicios de
Google Play, y los telefonos baratos que se usan en campo no siempre los tienen
al dia — o los tienen rotos de una forma que no se arregla desde la app. Una
cuenta con clave no depende de nada de eso. Google se queda porque para quien
si puede usarlo es un toque en vez de tres campos.

**Lo que cuesta tener contrasenas.** Sin ellas no habia que construir tres
flujos enteros — recuperacion de clave, verificacion de correo y freno de fuerza
bruta — que son justo donde los agujeros de autenticacion se cuelan. Con ellas
hay que pagarlos, y hoy estan pagados a medias:

- **Fuerza bruta**: hecho. 8 fallos seguidos bloquean 15 minutos. El contador
  vive en Airtable, no en memoria: el backend corre en funciones serverless y un
  contador que se reinicia solo no frena nada.
- **Hash**: hecho. bcrypt con sal por usuario.
- **Verificacion de correo**: pendiente. Las cuentas de clave nacen sin
  verificar y nada depende todavia de ese campo.
- **Recuperacion de clave**: pendiente. Hace falta poder mandar correo y este
  backend no manda correo. Por ahora se restablece a mano desde Airtable, y la
  pantalla de registro lo dice.

Despues del login, el backend emite un **JWT propio de 30 dias**. Verificarlo no
cuesta red ni una consulta a Airtable, y eso importa por dos razones: en el
monte no hay con quien validar, y Airtable topa en 5 requests por segundo por
base — un techo que el login no puede gastar porque lo comparte con la
sincronizacion.

Eso trae una consecuencia que atraviesa todo el diseno: **la base deja de ser de
una sola empresa.** Airtable no tiene seguridad por fila y el PAT ve todo, asi
que lo unico que separa los predios de un usuario de los de otro es que el
backend filtre por `Dueno Auth UID` en cada consulta. Ver
[`airtable-schema.md`](airtable-schema.md#aislamiento-entre-cuentas).

## Las tres capas

```
┌─────────────────────────── TELEFONO (Flutter) ────────────────────────────┐
│  ui/      pantallas                                                        │
│  state/   Riverpod: lo que la pantalla necesita saber                      │
│  data/    Drift (SQLite) + repositorios + sincronizador                    │
│  core/    geometria, MBTiles, KML/GPX, GPS, cliente HTTP                   │
└────────────────────────────────┬───────────────────────────────────────────┘
                    │ HTTPS  ·  X-API-Key (quien llama)
                    │        ·  Bearer JWT (quien es)      solo con red
┌───────────────────▼────────────────────────────────────────────────────────┐
│  backend/ FastAPI en Vercel                                                │
│    services/auth.py            verifica el JWT y aisla por dueno           │
│    services/teselas.py         GeoPDF/GeoTIFF -> MBTiles (llama a GDAL)    │
│    services/almacenamiento.py  firma URLs de S3 (subida y descarga)        │
│    services/airtable.py        upsert por UUID                             │
└────┬──────────────────┬──────────────────────┬─────────────────────────────┘
     │                  │                      │ solo en el login
┌────▼──────────┐ ┌─────▼──────────┐ ┌─────────▼────────┐
│ AWS S3 privado│ │    Airtable    │ │  JWKS de Google  │
│ MBTiles       │ │  usuarios      │ │  claves publicas │
│ geometrias    │ │  llaves S3     │ │  para verificar  │
│ KML, GPX, PDF │ │  bbox, area,   │ │  el ID token     │
│ fotos         │ │  vista previa  │ │                  │
└───────────────┘ └────────────────┘ └──────────────────┘
```

## Por que el backend convierte los mapas y no el telefono

Un GeoPDF de topografia trae vectores, capas y una matriz de georreferenciacion
en un SRC local (en Colombia casi siempre MAGNA-SIRGAS). Convertirlo a teselas
es trabajo de GDAL: reproyectar, rasterizar y cortar en piramide. Eso no corre
en un telefono, y aunque corriera, dejarlo correr media hora quemando bateria en
un lote es la peor version posible.

El flujo es: coordinacion sube el mapa desde la web -> el backend lo convierte y
lo deja como MBTiles en el bucket -> el telefono lo descarga una vez, con wifi,
antes de salir a campo.

`tools/` guarda los comandos de GDAL para poder correr la conversion a mano
cuando el archivo es tan grande que no pasa por el endpoint.

## Por que MBTiles y no una carpeta de teselas

Un mapa de un municipio son decenas de miles de archivos `.png` de 10 KB.
Android tarda mas en abrir 40.000 archivos sueltos que en leer un SQLite de
400 MB, y copiar esa carpeta entre telefonos es inviable. MBTiles es un solo
archivo: se descarga, se verifica su tamano, y o esta completo o no esta.

## Reproyeccion: donde se decide

`core/proyeccion.dart` solo se usa para **leer metadatos** y avisar. Las teselas
del MBTiles ya salen del backend en Web Mercator (EPSG:3857), porque es lo que
`flutter_map` sabe dibujar. `proj4dart` esta en el telefono para el caso
contrario: cuando el usuario teclea una coordenada en el SRC del proyecto y hay
que llevarla a WGS84 para ponerla en el mapa.

## Sincronizacion

`state/sincronizador.dart` corre cuando `connectivity_plus` reporta red y hay
registros con `sincronizado = false`. Sube en este orden, porque Airtable
necesita los enlaces resueltos:

```
Proyectos -> Mapas -> Trazados -> Waypoints -> Archivos -> Sincronizaciones
```

Cada paso es un upsert por UUID. Si el tercero falla, los dos primeros ya
quedaron y el reintento no los duplica.

## Lo que se porta de sirius_agro sin tocar

| Archivo | Que trae |
|---|---|
| `core/geo.dart` | Haversine y area de poligono sobre WGS84, con el mismo radio que usa Google Earth. Ya tiene pruebas |
| `core/kml.dart` | KML 2.2 escrito a mano, con el orden `lon,lat,alt` que cuesta una tarde si se olvida |
| `core/ubicacion.dart` | GPS con filtro de precision y de distancia minima |
| `state/red.dart` | Indicador de conectividad |
| `ui/theme.dart`, `ui/marca.dart` | Museo Slab y la marca Sirius |

Se copian, no se importan: son dos apps con ciclos de vida distintos y una
dependencia cruzada entre repos privados haria que un cambio en agro rompa
GeoMaps sin aviso.
