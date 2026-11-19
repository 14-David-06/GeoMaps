# GeoMaps web: la app del iPhone

No hay cuenta de Apple Developer, asi que GeoMaps no va a la App Store. En el
iPhone se instala como **app web (PWA)**: se abre en Safari, Compartir →
"Agregar a pantalla de inicio", y desde ese icono abre como una app y funciona
**sin senal**.

No es otro proyecto ni otro servidor. Es el mismo codigo Flutter compilado
para el navegador, servido como archivos estaticos por el backend que ya esta
en Vercel:

| | |
|---|---|
| App | `https://geo-maps-seven.vercel.app/geomaps/index.html` |
| Pagina de instalacion | `https://geo-maps-seven.vercel.app/geomaps/instalar.html` |
| Codigo QR para imprimir | `docs/qr/instalar-geomaps.png` (y `.svg`) |
| Archivos | `backend/public/geomaps/` (no se versiona, ver abajo) |

La app llama al API en el mismo dominio (`/v1/...`), asi que no hay CORS. Un
despliegue Preview de Vercel habla con su propio backend, no con produccion.

## Que hace y que no

En Android la app no cambia: todo lo de la web va detras de `kIsWeb` o de
`lib/platform/pwa.dart`, que en el telefono es inerte.

| En el iPhone | |
|---|---|
| Entrar con correo y clave; la sesion abre sin senal, igual que en Android | Si |
| Mapa de Guaicaramo: lotes, vias, acopios, perimetro | Si, sin senal (viene dentro de la app) |
| Ubicacion GPS sobre el mapa | Si, con la app abierta (la pantalla no se apaga sola con el mapa abierto) |
| Buscar un acopio por bloque y numero | Si, sin senal |
| Ruta A→B por las vias del predio, con indicaciones habladas | Si, sin senal (el ruteo es local) |
| Iniciar una ruta y calificarla al llegar | Si; sube al volver la senal |
| Marcar puntos, grabar recorridos, medir areas | Si; suben al volver la senal |
| Compartir KML / GPX / PDF | Si, por la hoja de compartir del iPhone |
| Imagen satelital | La que se miro con senal queda guardada; **no** hay "bajar una zona" |
| Entrar con Google | No (ver abajo) |
| Camiones (QR, vueltas) | No |
| Fotos en los puntos | No |
| Importar planos PDF | No (usa el lector nativo de Android) |
| Grabar con la pantalla bloqueada | No: iOS no le da ubicacion a una app web en segundo plano |

Por que cada "No":

- **Google.** En el navegador, `google_sign_in` no entrega el `idToken` por la
  via que usa la app, el `serverClientId` no existe, y Google no acepta las
  direcciones Preview de Vercel (cambian en cada despliegue) como origen.
- **Bajar una zona del satelite.** La app baja de `server.arcgisonline.com`
  (Esri) y la capa de calles es `tile.openstreetmap.org`, cuya politica no
  permite bajar en masa. Hasta tener una fuente de imagenes con licencia para
  guardar zonas enteras, la web no lo ofrece. Esa misma pregunta vale para la
  pantalla "Descargas" de Android.
- **Camiones.** El lector de QR en el navegador baja una libreria de
  unpkg.com (rompe "nada de otros dominios para arrancar"), y la vuelta se
  sigue con la pantalla apagada, que en iOS no se puede.
- **Fotos y planos.** Son archivos del telefono (`dart:io`) y el lector de
  planos es Kotlin.

## Compilar y publicar

```bash
backend/.venv/Scripts/python tools/compilar_pwa.py
```

Compila con `dart_defines.json`, arma el service worker y deja todo en
`backend/public/geomaps/` (ver el docstring del script para el detalle). Con
`--sin-compilar` reusa `app/build/web`: la compilacion web tarda.

Despues **hay que desplegar el backend** para que llegue a los telefonos. Eso
lo hace quien maneja Vercel. No hace falta `vercel.json`: Vercel sirve
`public/` de un proyecto FastAPI como estatico en la raiz
(`public/geomaps/index.html` → `/geomaps/index.html`).

**El mismo dia que un APK.** El backend bloquea a los 10 dias las versiones
viejas segun `X-App-Version`, y la web manda el mismo `versionCode` del
`pubspec.yaml`. Si se publica un APK nuevo y no la web, a los 10 dias los
iPhone quedan bloqueados.

### `backend/public/geomaps/` no se versiona

El build lleva adentro `assets/zonas/*.json` (lotes, vias y acopios), que son
del cliente, y este repositorio es publico. Por eso esta en `.gitignore`: se
despliega desde la maquina que lo compilo, con `vercel` desde `backend/` (la
CLI sube lo que hay en la carpeta; no usa el `.gitignore`).

Si el proyecto de Vercel se conecta a GitHub para desplegar solo, la carpeta no
va a estar ahi y la app web desaparece del despliegue.

**Quien abre la URL baja esos datos sin iniciar sesion**, igual que hoy quien
baja el APK por `/descargar`. Lo mismo pasa con `API_KEY`, que queda legible
en `main.dart.js`. Protegerlos de verdad pide servir las zonas desde el API con
sesion, que es un cambio de backend.

## Como funciona sin senal

### El service worker (`sw.js`)

Lo escribe `compilar_pwa.py` desde `tools/pwa/sw_plantilla.js` con la lista
real del build: cada archivo con su peso y su sha256.

- **Al instalarse guarda la app entera** (unos 14 MB, 38 archivos): `index.html`, el
  codigo, CanvasKit, las fuentes, los datos del predio, `sqlite3.wasm` y
  `drift_worker.js`. Si un solo archivo falla, la instalacion falla completa y
  se reintenta la proxima vez que se abra con senal. Mientras tanto, el inicio
  muestra "Guardando GeoMaps en el telefono: N %" y al terminar "Listo. Ya
  podes usar GeoMaps sin senal".
- **Sirve la app desde lo guardado**, con o sin senal. Toda navegacion dentro
  de `/geomaps/` responde con `index.html` (las pantallas van despues del
  `#`), salvo `instalar.html`. Las respuestas se guardan sin redireccion:
  Safari no acepta una respuesta "redirected" en una navegacion.
- **No toca** `/v1/...` ni las imagenes del mapa de Esri u OSM.

### Actualizaciones

1. Al abrir con senal (y cada 30 minutos con la app abierta) el navegador
   pregunta si cambio `sw.js`. Como la version es un hash del build, solo
   cambia si cambio algo.
2. La version nueva se baja **entera** en segundo plano, en su propia cache.
   Los archivos que no cambiaron (CanvasKit, por ejemplo) se copian de la
   version anterior por su sha256, sin volver a bajarlos.
3. El inicio muestra "Hay una version nueva de GeoMaps" con **Actualizar
   ahora**. Nunca se recarga sola: no puede pasar en mitad de un recorrido.
4. Al aceptar, la version nueva se activa, borra las caches de versiones
   anteriores y la app recarga. **No se borra** lo guardado por la persona: la
   base local (puntos, recorridos, pendientes, sesion) y la cache de imagenes
   del mapa (`geomaps-teselas`) viven aparte.

### La base local

Es la misma base drift de Android, con el mismo esquema: SQLite compilado a
WebAssembly (`sqlite3.wasm`) en un worker (`drift_worker.js`), guardado en el
almacen del navegador (OPFS o IndexedDB, el que tenga el iPhone). Lo que se
marca sin senal queda ahi y sube con el mismo sincronizador de siempre al
volver la red; el backend hace upsert por UUID, asi que un reintento no
duplica.

Los dos archivos tienen que ser de la version de `sqlite3` y `drift` del
`pubspec.lock`: el script baja uno y compila el otro, y los guarda en
`tools/salida/pwa/` para no repetirlo.

### Las fuentes

En el navegador no hay letra del sistema, y Flutter baja Roboto de
fonts.gstatic.com la primera vez que pinta texto: sin senal la app abria sin
letras. La app trae Roboto en `app/web/fuentes/` (Apache 2.0, del SDK de
Flutter), la carga antes del primer cuadro, y el motor la pide al mismo
dominio (`fontFallbackBaseUrl` en `web/flutter_bootstrap.js`).

### Nada de otros dominios para arrancar

La app abre sin pedirle nada a otro dominio: CanvasKit, las fuentes, la base
y los datos del predio salen del mismo `/geomaps/`. La unica excepcion era el
plugin web de Google Sign-In, que baja `accounts.google.com/gsi/client` apenas
arranca aunque la app web no ofrezca entrar con Google. `index.html` lo
bloquea con una regla CSP que solo deja cargar scripts del mismo dominio
(`script-src-elem 'self' 'unsafe-inline'`): el navegador ni lo pide. Las
imagenes del mapa base (Esri, OSM) se piden recien al mirar el mapa con senal.

## Agregar una zona para usar sin senal

Los datos de un predio no se bajan aparte: entran en la app al compilar, desde
`app/assets/zonas/` (ver `app/assets/zonas/LEEME.md` y los scripts de
`tools/`). Para una zona nueva:

1. Generar sus JSON con los scripts de `tools/` (igual que para Android).
2. Agregar la zona en el codigo como se hizo con Guaicaramo.
3. `tools/compilar_pwa.py` y desplegar. Cada iPhone la baja con la proxima
   actualizacion.

## Diagnostico

En el iPhone no se puede inspeccionar Safari sin una Mac. En la app web, en
**Mi cuenta**, la ultima linea es la version ("GeoMaps web 0.2.6"): tocada
**siete veces seguidas** abre el diagnostico, con la version de la app y la
guardada, si esta instalada o en Safari, si funciona sin senal y desde cuando,
el espacio usado y disponible, como abrio la base local (si dice "Solo en
memoria", lo que se marque se pierde), cuantas imagenes del mapa hay
guardadas, si esta la zona Guaicaramo y cuantos registros faltan por subir.

## Limitaciones de iOS

- **Hay que abrirla desde el icono.** Safari y la app instalada guardan en
  almacenes distintos: lo hecho en la pestana no pasa a la app. Por eso,
  abierta en Safari, la app pide instalarla antes de dejar entrar.
- **iOS puede borrar lo guardado** si el telefono se queda sin espacio. La
  app pide almacenamiento persistente (`navigator.storage.persist()`), que
  Safari concede a las apps de la pantalla de inicio, pero no es una promesa
  absoluta.
- **Sin GPS en segundo plano.** Con la pantalla bloqueada o con otra app
  adelante, la ubicacion se corta. Con el mapa abierto la pantalla no se apaga
  sola (Wake Lock, iOS 18.4 o mas nuevo).
- **Sin Background Sync.** Lo pendiente sube cuando la app esta abierta y con
  senal, no sola despues.
- **Primer fix lento sin datos.** Sin internet el GPS no tiene ayuda de la red
  y la primera posicion puede tardar minutos al aire libre.
- **La voz** sale con el sintetizador de iOS; la primera frase puede necesitar
  un toque previo en la pantalla.

## Probarla en la maquina

```bash
backend/.venv/Scripts/python tools/compilar_pwa.py --sin-compilar
cd backend/public && python -m http.server 8123
```

y abrir `http://localhost:8123/geomaps/index.html` en Chrome (localhost cuenta
como HTTPS para el service worker). Para probar sin senal: DevTools →
Application → Service workers → Offline, o apagar el servidor y recargar. El
API no esta en ese servidor, asi que entrar no funciona ahi; para eso hay que
probar en el Preview de Vercel.

## Volver atras

- Borrar `backend/public/geomaps/` y desplegar el backend: la app web
  desaparece y el resto del backend queda exactamente como estaba (no se toco
  ninguna ruta, variable ni `vercel.json`).
- En la app: los cambios para web son `app/web/`, `app/lib/platform/`,
  `app/lib/ui/pwa/`, `app/lib/state/pwa.dart` y lineas detras de `kIsWeb`;
  revertirlos no cambia nada en Android.
- Los iPhone que ya la instalaron se quedan con la ultima version guardada
  hasta que se borre el icono.
