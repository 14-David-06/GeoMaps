# Base de datos Airtable — GeoMaps

Base sugerida: **Sirius GeoMaps** (crear aparte de `Sirius Agro App`; el
telefono de GeoMaps no tiene por que poder escribir visitas agronomicas).

Convenciones, las mismas del resto de los proyectos Sirius:

- Nombres de campo **sin tildes ni ñ**.
- Fechas ISO (`YYYY-MM-DD`), horas en `America/Bogota`.
- Todo registro creado desde el telefono trae un **UUID generado offline**. El
  backend hace *upsert* contra ese UUID, nunca `create` a ciegas: reintentar
  una sincronizacion no puede duplicar un trazado.
- Los archivos **no** viven en Airtable. Van a **S3** y Airtable guarda la
  `Llave S3` + `Tamano (MB)`. Eso incluye los binarios pesados (MBTiles) y
  tambien la geometria de los trazados, que es texto pero crece sin techo.
- Airtable guarda **punteros y resumenes**, nunca el dato completo cuando el
  dato completo puede crecer. Ver [Que va en S3 y que en Airtable](#que-va-en-s3-y-que-en-airtable).

## Flujo que soporta el modelo

```
USUARIO -> PROYECTO -> MAPA (capa base offline)
                    -> TRAZADO (ruta / poligono)  -> ARCHIVO (KML, GPX, PDF)
                    -> WAYPOINT                   -> FOTO
        -> SINCRONIZACION (log de cada subida)
        -> VUELTA (camiones: tomada, llegada, regreso, finalizada)
```

## Tablas

| Tabla | Para que sirve |
|---|---|
| `Usuarios` | Quien usa la app y con que permiso |
| `Dispositivos` | Que telefono tiene que copia de que mapa |
| `Proyectos` | Agrupador: un predio, un municipio, un contrato |
| `Mapas` | Ficha de cada capa base offline (MBTiles) |
| `Trazados` | Rutas y poligonos capturados en campo |
| `Waypoints` | Puntos marcados |
| `Archivos` | Todo lo que la app genera: KML, GPX, PDF, fotos |
| `Sincronizaciones` | Log de cada subida, para poder explicar un dato perdido |
| `Vueltas` | Seguimiento de las vueltas de camiones: quien tomo cada una, cuando llego a los vagones, cuando volvio y cuando la finalizo |
| `Errores` | Los fallos que la app anota en el telefono, con la version del APK y el modelo del telefono |

---

### `Usuarios`

| Campo | Tipo | Nota |
|---|---|---|
| `Auth UID` | Single line text | El `sub` del ID token de Google, o `pwd_<uuid4>` si la cuenta es de clave. **Clave real de la identidad y del upsert** |
| `Codigo usuario` | Single line text | UUID interno, para los enlaces de las demas tablas |
| `Nombre` | Single line text | Lo que trajo Google, o lo que escribio la persona al registrarse |
| `Correo` | Email | **Unico en la tabla.** Siempre en minusculas |
| `Proveedor` | Single select | `Google` / `Correo`. Por cual puerta entra esta cuenta |
| `Hash clave` | Single line text | bcrypt. **Vacio en las cuentas de Google.** Nunca sale de Airtable |
| `Correo verificado` | Checkbox | Verdadero en las de Google. Falso en las de clave: no hay envio de correo todavia |
| `Intentos fallidos` | Number (entero) | Contador de logins con clave errada. Se pone en 0 al entrar bien |
| `Ultimo intento fallido` | Date with time | Con el anterior, arma el bloqueo temporal |
| `Foto` | URL | El avatar de Google, si lo hay. Vacio en las cuentas de clave |
| `Rol` | Single select | `Usuario` / `Soporte` / `Admin`. Toda cuenta nueva nace `Usuario` |
| `Estado` | Single select | `Activa` / `Suspendida` / `Baja pedida` |
| `Perfiles` | Multiple select | `Plantacion` / `Camiones`. Que herramientas ve en la app. **Vacio = Plantacion**, asi las cuentas viejas no pierden nada. Se asigna a mano; llega al telefono la proxima vez que abre la app con senal (`POST /v1/sesion/renovar`), o al tocar "Actualizar mi cuenta". Ya no hace falta cerrar sesion |
| `Cedula` | Single line text | Solo digitos. **Opcional, y la carga un administrador**: a la persona ya no se le pide. Si esta, enlaza la cuenta con el conductor de SiriusFleet que tenga ese documento (`operadores.documento`) y las vueltas que tome quedan con su nombre en la columna Conductor de la planilla |
| `Espacio usado (MB)` | Number (1 decimal) | Suma de lo que ocupa en S3. Contra `CUOTA_MB_POR_USUARIO` |
| `Registrado en` | Date with time | |
| `Ultimo acceso` | Date with time | |
| `Dispositivos` | Link -> Dispositivos | |
| `Proyectos` | Link -> Proyectos | Los **suyos**, no los que le asignaron |

**Dos puertas, una fila.** Se entra con cuenta de Google o con correo y clave.
Con Google, el backend verifica el ID token contra el JWKS publico y saca el
`sub`. Con clave, compara contra `Hash clave`. En los dos casos el resultado es
la misma fila y el mismo JWT de 30 dias.

**Una cuenta no puede tener las dos.** El correo es unico y `Proveedor` dice
cual manda. Registrarse con clave usando un correo que ya entra con Google
responde 409 diciendo cual es la puerta correcta, y al reves tambien.

**`Hash clave` no se mira ni se edita a mano.** Es bcrypt, no es reversible y
no sirve de nada leerlo. Lo unico razonable que se puede hacer desde Airtable es
borrarlo — lo que deja la cuenta sin poder entrar — o pegarle un hash nuevo
generado a proposito, que es el procedimiento manual de "olvide mi clave"
mientras no haya envio de correo.

**`Correo verificado` todavia no controla nada.** Las cuentas de clave nacen en
falso y siguen asi. El dia que algo dependa de este campo (avisos, recuperacion
automatica), primero hay que construir el envio de correo.

**El `Auth UID` es el `sub`, no el correo.** Alguien puede cambiar la direccion
de su cuenta de Google y seguir siendo la misma persona; colgar los proyectos
del correo haria que ese cambio le borre su trabajo de la vista.

**Con Google, el registro no tiene formulario propio.** La primera vez que
llega un `Auth UID` que no existe en esta tabla, el backend crea la fila:
registrarse y entrar por primera vez son el mismo evento. Con clave si hay
formulario, porque el nombre hay que preguntarlo — pero `POST /v1/registro`
devuelve la sesion abierta, no un "ya te podes loguear": mandar a alguien a un
segundo formulario desperdicia el unico rato con senal que va a tener ese dia.

**Camiones: la planilla vive en SiriusFleet, el seguimiento aca.** La lista
de vueltas pendientes esta en la planilla de vagones de SiriusFleet
(Supabase). GeoMaps la lee y, al tomar una, anota alla la hora de salida
(`backend/app/services/supabase.py`). Lo que pasa despues -si llego a los
vagones, si volvio, cuando la finalizo- queda en la tabla [`Vueltas`](#vueltas)
de esta base, y el recorrido del GPS sube como un `Trazado` con `Metodo =
Automatico`.

**Que hace falta para que un conductor tome vueltas.** Una sola cosa: que la
cuenta tenga `Camiones` en `Perfiles`. Sin eso la app ni muestra el modulo y
el backend responde 403.

**La cedula ya no se pide.** La vuelta se firma con la clave de GeoMaps, en
cada vuelta, a las cuentas que tienen una (`Proveedor = Correo`). Las de
Google no tienen clave y confirman con la sesion. La vuelta queda a nombre de
**la cuenta**, y en la planilla de SiriusFleet se ve asi:

1. Si la cuenta tiene `Cedula` cargada, o se llama exactamente igual que un
   conductor activo de SiriusFleet, queda ese conductor en la columna
   Conductor.
2. Si no, la columna Conductor queda en blanco y el nombre de la cuenta va en
   Observaciones (`GeoMaps: Fulano`), sin borrar lo que despacho hubiera
   escrito ahi.

**Una vuelta a la vez.** Mientras una cuenta tenga una fila de `Vueltas` en
`En camino` o `En el punto`, el backend no le deja tomar otra (423). La cierra
finalizandola -lo que exige haber llegado a los vagones y haber vuelto al punto
de salida- o devolviendola antes de llegar ("No la voy a recoger"): ahi el
backend le borra la hora de salida en la planilla y vuelve a la lista.

**Para destrabar a un conductor** -el acopio tenia mal la coordenada, se le
rompio el telefono a mitad de camino- alguien de coordinacion cambia el
`Estado` de su fila en `Vueltas` a `Finalizada` o `Devuelta`. Con eso ya puede
tomar otra, y la app le ofrece cerrar el viaje que tenia abierto.

**`Perfiles` no es `Rol`.** El rol dice quien puede ver datos ajenos; el
perfil dice que hace la persona en campo y por lo tanto que modulos ve. Viaja en
el JWT, asi que la app lo lee sin red, y un endpoint de un solo modulo lo revisa
con `auth.exigir_perfil`: esconder el boton en la app no protege nada.

**`Rol` ya no reparte permisos sobre proyectos ajenos.** Antes, con nomina, un
Coordinador veia el trabajo de todo el equipo. Con registro abierto eso seria
un agujero: `Usuario` ve lo suyo y nada mas. `Soporte` y `Admin` son para
operar el servicio, y quien los tenga puede leer datos de clientes — se asignan
a mano en Airtable, nunca desde la app.

### `Dispositivos`

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo dispositivo` | Single line text | UUID que genera la app en el primer arranque |
| `Usuario` | Link -> Usuarios | |
| `Modelo` | Single line text | |
| `Version app` | Single line text | `1.0.0+1` |
| `Almacenamiento libre (GB)` | Number | Lo reporta la app al sincronizar. Sirve para saber a quien no le cabe un mapa nuevo |
| `Mapas descargados` | Link -> Mapas | |
| `Ultima sincronizacion` | Date with time | |

Existe por una pregunta operativa concreta: *el tecnico que va manana al lote 7,
tiene el mapa nuevo en el telefono?* Sin esta tabla la respuesta es llamarlo.

### `Proyectos`

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo proyecto` | Single line text | UUID |
| `Nombre` | Single line text | |
| `Cliente` | Single line text | |
| `Municipio` | Single line text | |
| `Centro lat` / `Centro lon` | Number (precision 6) | Donde abre el mapa |
| `Estado` | Single select | `Activo` / `Cerrado` |
| `Dueno Auth UID` | Single line text | **Quien puede ver esto.** Denormalizado a proposito: el filtro de aislamiento tiene que poder correr sin resolver un enlace |
| `Mapas` | Link -> Mapas | |
| `Trazados` | Link -> Trazados | |
| `Dueno` | Link -> Usuarios | El mismo dato, para navegar la base a mano |

**El proyecto `local`.** El mapa hoy se abre sin proyecto y lo que se guarda en
el telefono cae en `proyectoCodigo = 'local'`, la misma cadena en todos los
telefonos. Al subir, el backend lo traduce a un proyecto por cuenta,
`Codigo proyecto = local-<Auth UID>` con `Nombre = Sin proyecto`, creado la
primera vez con su dueno. Asi no se mezclan las rutas de distintas cuentas ni
sus prefijos de S3.

`Dueno Auth UID` se repite como texto plano aunque ya exista el enlace `Dueno`.
No es redundancia por descuido: `filterByFormula` sobre un campo de enlace en
Airtable compara contra el *nombre* del registro, que puede cambiar. Comparar
contra un UID literal es lo unico que no se rompe el dia que alguien edita su
nombre de perfil.

### `Mapas`

La ficha de una capa base offline. **El MBTiles no se adjunta**: se sube a S3 y
aqui queda su llave.

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo mapa` | Single line text | UUID |
| `Nombre` | Single line text | |
| `Proyecto` | Link -> Proyectos | |
| `Formato origen` | Single select | `GeoPDF` / `GeoTIFF` / `KMZ` / `MBTiles` |
| `Llave S3` | Single line text | Del MBTiles ya convertido |
| `Llave S3 original` | Single line text | Del archivo que mando topografia, tal como llego. Se conserva para poder reconvertir con otros parametros sin volver a pedirlo |
| `Tamano (MB)` | Number (1 decimal) | La app lo muestra antes de descargar |
| `SRC origen` | Single line text | EPSG del archivo que mando topografia, p. ej. `EPSG:3116` (MAGNA-SIRGAS Bogota) |
| `Zoom min` / `Zoom max` | Number | |
| `Bbox` | Long text | `minLon,minLat,maxLon,maxLat` en WGS84 |
| `Miniatura` | Attachment | Lo unico binario que si va en Airtable |
| `Estado` | Single select | `Procesando` / `Listo` / `Fallido` |
| `Error` | Long text | Que dijo GDAL cuando fallo |
| `Subido por` | Link -> Usuarios | |
| `Creado en` | Date with time | |

`SRC origen` esta porque es el campo que mas caro sale olvidar: un plano en
MAGNA-SIRGAS interpretado como WGS84 se dibuja unos cientos de metros corrido,
abre sin error, y nadie lo nota hasta que alguien camina al punto equivocado.

### `Trazados`

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo trazado` | Single line text | UUID generado en campo |
| `Nombre` | Single line text | |
| `Proyecto` | Link -> Proyectos | |
| `Tipo` | Single select | `Ruta` / `Poligono` |
| `Llave geometria` | Single line text | Llave S3 del GeoJSON completo: `proyectos/<codigo>/geometrias/<codigo trazado>.geojson`. **Es la geometria de verdad** |
| `Bbox` | Single line text | `minLon,minLat,maxLon,maxLat`. Permite filtrar por zona sin bajar el archivo |
| `Centro lat` / `Centro lon` | Number (precision 6) | Centroide. Es lo que hace que una fila de Airtable se pueda abrir en Google Maps de un clic |
| `Vista previa` | Long text | GeoJSON **simplificado** a un maximo de 50 vertices. No es el dato: es para ver la forma sin salir de Airtable |
| `Puntos` | Number | Cuantos vertices tiene el archivo real |
| `Distancia (m)` | Number (1 decimal) | |
| `Area (ha)` | Number (4 decimales) | Solo poligonos. Calculada con el radio WGS84 de `core/geo.dart`, el mismo que usa Google Earth |
| `Precision media (m)` | Number (1 decimal) | Que tan bueno era el GPS. Un poligono levantado bajo arboles con 30 m de error no sirve para un lindero |
| `Metodo` | Single select | `Automatico` / `Manual` / `Mixto` / `Calculada`. `Calculada` es una ruta del ruteo por vias guardada desde el mapa: nadie la camino, no tiene `Precision media` y no sirve como lindero |
| `Iniciado en` / `Terminado en` | Date with time | |
| `Calificacion` | Number (entero) o Rating | De 1 a 5. Como califico la ruta quien la recorrio, al terminarla: una ruta iniciada desde el mapa o el viaje de un camion. Vacio si no se califico. **Hay que crear este campo y los dos de abajo a mano**: mientras no existan, el recorrido sube igual y la calificacion queda solo en el GeoJSON de S3 (`properties.calificacion`) |
| `Motivos calificacion` | Single line text | Por que salio mal, separados por coma: `Via en mal estado`, `Barro o agua`, `Paso cerrado`, `Dio mucha vuelta`, `Mando por donde no era`. Solo se preguntan con 3 estrellas o menos |
| `Comentario calificacion` | Long text | Lo que escribio la persona, si escribio algo |
| `Capturado por` | Link -> Usuarios | |
| `Archivos` | Link -> Archivos | Sus KML/GPX/PDF |
| `Waypoints` | Link -> Waypoints | |

**La geometria vive en S3, no en Airtable.** El `Long text` de Airtable tope en
100.000 caracteres: un recorrido de 800 vertices entra (unos 20 KB), pero una
jornada completa grabada cada 5 segundos son decenas de miles de puntos y no
entra. El limite se alcanza sin aviso util, y el trazado que lo cruza es
justamente el que mas trabajo costo levantar.

Lo que **si** queda en Airtable es lo que hace consultable la fila sin bajar
nada: `Bbox`, el centroide, el conteo de puntos y una `Vista previa`
simplificada. Esa distincion importa por la premisa del proyecto — coordinacion
abre la base y ve que se levanto esta semana. Si la fila fuera solo una llave de
S3, Airtable dejaria de servir para mirar y quedaria como un indice ciego.

La `Vista previa` se genera con Douglas-Peucker hasta 50 vertices. Es
deliberadamente **no** el dato: nadie puede medir un area sobre ella. Por eso se
llama asi y no `Geometria`.

### `Waypoints`

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo waypoint` | Single line text | UUID |
| `Nombre` | Single line text | |
| `Proyecto` | Link -> Proyectos | |
| `Trazado` | Link -> Trazados | Opcional |
| `Latitud` / `Longitud` | Number (precision 6) | |
| `Altitud (m)` | Number (1 decimal) | |
| `Precision (m)` | Number (1 decimal) | |
| `Simbolo` | Single select | `Generico` / `Muestra` / `Arbol` / `Fuente de agua` / `Infraestructura` / `Riesgo` |
| `Nota` | Long text | |
| `Fotos` | Link -> Archivos | |
| `Marcado en` | Date with time | Hora del GPS, no la del telefono |
| `Marcado por` | Link -> Usuarios | |

### `Archivos`

Todo lo que la app **genera**. Una fila por entregable.

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo archivo` | Single line text | UUID |
| `Nombre` | Single line text | Como se llama en el bucket |
| `Tipo` | Single select | `KML` / `KMZ` / `GPX` / `GeoJSON` / `PDF` / `Foto` |
| `Llave S3` | Single line text | Donde esta en el bucket |
| `Adjunto` | Attachment | Airtable lo copia desde una URL prefirmada al momento de escribir. Solo para PDF y fotos: sirve para verlo en la base sin descargar nada |
| `Tamano (MB)` | Number (1 decimal) | |
| `Proyecto` | Link -> Proyectos | |
| `Trazado` | Link -> Trazados | |
| `Waypoint` | Link -> Waypoints | |
| `Generado en` | Date with time | |
| `Generado por` | Link -> Usuarios | |

Las fotos se guardan bajo el prefijo del proyecto
(`proyectos/<codigo>/fotos/<uuid>.jpg`) por la misma razon que en `sirius_agro`:
borrar el proyecto tiene que llevarse sus archivos.

### `Sincronizaciones`

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo sync` | Single line text | UUID del intento |
| `Dispositivo` | Link -> Dispositivos | |
| `Usuario` | Link -> Usuarios | |
| `Inicio` / `Fin` | Date with time | |
| `Registros enviados` | Number | |
| `Registros fallidos` | Number | |
| `Estado` | Single select | `Ok` / `Parcial` / `Fallida` |
| `Detalle` | Long text | Que fallo y por que |

Existe para poder responder *el trazado del martes no aparece* sin adivinar.

### `Vueltas`

El seguimiento de las vueltas de camiones. **Una fila es una vuelta tomada por
una cuenta**: si la devuelve y la toma otro, son dos filas.

Se crea con `python backend/scripts/crear_tabla_vueltas.py --aplicar` (sin
`--aplicar` solo dice que haria). **Si la tabla no existe el backend sigue
dejando tomar vueltas, pero sin control**: no impide tomar una segunda ni
guarda los pasos. La app lo sabe por `control` en `GET /v1/camiones/vueltas`.

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo viaje` | Single line text | UUID que genera el backend al tomar la vuelta. Campo primario |
| `Nombre` | Single line text | `Vuelta #23 · B.3-P.4 · 11A`: se reconoce sin abrir nada |
| `Estado` | Single select | `En camino` / `En el punto` / `Finalizada` / `Devuelta`. Los dos primeros son "abierta": la cuenta no puede tomar otra. **Se puede cambiar a mano** para destrabar a alguien |
| `Conductor` | Single line text | Como quedo en la planilla: el conductor de SiriusFleet si la cuenta esta enlazada, y si no el nombre de la cuenta |
| `Jornada` | Date | La de la planilla |
| `Consecutivo` | Number (entero) | El "No." de la planilla |
| `Acopio` | Single line text | Donde estaban los vagones: `B.3-P.4 · 11A` |
| `Tomada en` | Date with time | Cuando la tomo |
| `Llegada en` | Date with time | Cuando el telefono entro a 100 m del acopio |
| `Regreso en` | Date with time | Cuando, ya habiendo llegado, volvio a 150 m del punto de salida |
| `Finalizada en` | Date with time | Cuando la finalizo |
| `Devuelta en` | Date with time | Cuando la devolvio a la lista, si la devolvio |
| `Distancia al punto (m)` | Number (entero) | A cuanto del acopio estaba al contarse la llegada |
| `Distancia a la salida (m)` | Number (entero) | A cuanto del punto de salida estaba al finalizar |
| `Recorrido (m)` | Number (entero) | Lo que anduvo, segun el GPS |
| `Salida lat` / `Salida lon` | Number (precision 6) | Donde estaba el camion al tomarla: el punto al que tiene que volver |
| `Avisos` | Long text | Lo que conviene mirar: por ejemplo, una llegada marcada a mano porque el acopio no tenia coordenada |
| `Codigo trazado` | Single line text | El `Codigo trazado` del recorrido en `Trazados`: ahi esta el GPS completo |
| `Vuelta ID` | Single line text | El `id` del renglon en `viajes_vagones` de SiriusFleet |
| `Usuario` | Link -> Usuarios | Quien la tomo |
| `Auth UID` | Single line text | El mismo dato como texto, para filtrar sin resolver el enlace |

**Las horas las pone el telefono, no el servidor.** El lote no tiene senal: la
llegada se detecta ahi y sube despues, a veces horas despues. Cada paso trae
su propia hora y su posicion, y viaja dos veces: en un aviso directo cuando hay
senal (`POST /v1/camiones/viajes/{codigo}/seguimiento`) y adentro del recorrido
cuando sube (`POST /v1/sync`, campo `viaje`), que es el que no se pierde.

**Las reglas de distancia las aplica el telefono** (`app/lib/camiones/
seguimiento.dart`), que es el que tiene el GPS. El backend guarda lo que le
reportan y cuida el orden: no acepta un "finalizada" de una vuelta que nunca
llego a los vagones.

### `Errores`

Los fallos que la app anota en el telefono. **Una fila es un error**, no una
vez que ocurrio: si se repite mientras espera subir, viaja una sola vez con
`Veces`. Una pantalla que falla al dibujarse falla en cada cuadro.

Se crea con `python backend/scripts/crear_tabla_errores.py --aplicar` (sin
`--aplicar` solo dice que haria). **Si la tabla no existe la app no pierde
nada**: guarda hasta cuarenta informes en el telefono y los reintenta cada vez
que engancha senal.

| Campo | Tipo | Nota |
|---|---|---|
| `Codigo error` | Single line text | UUID que genera el telefono. Campo primario; el upsert es por aca |
| `Mensaje` | Long text | El error, como lo dio Dart |
| `Veces` | Number (entero) | Cuantas veces se repitio antes de subir |
| `Ocurrio en` | Date with time | La primera vez, con la hora del telefono |
| `Version` | Single line text | `0.2.7+11`: nombre y versionCode del APK |
| `Sistema` | Single line text | `OPPO CPH2637 · Android 14` |
| `Persona` | Single line text | El nombre de la cuenta, o el correo si no tiene |
| `Donde` | Single line text | En que parte de la app salto, cuando Flutter lo sabe |
| `Traza` | Long text | Hasta 8.000 caracteres |
| `Recibido en` | Date with time | Cuando llego al backend: la diferencia con `Ocurrio en` es cuanto estuvo sin senal |
| `Version code` | Number (entero) | Para filtrar "todo lo anterior a la 11" |
| `Auth UID` | Single line text | De quien es. Es por donde la baja de cuenta los borra |
| `Estado` | Single select | `Nuevo` / `Visto` / `Arreglado`. **Lo lleva quien revisa**: el backend no lo escribe |

No lleva enlace a `Usuarios` a proposito: resolverlo costaria una consulta mas
por tanda, y el cupo de Airtable lo comparte con la sincronizacion.

Lo que **no** se anota: los cortes de red (`SocketException`, tiempos de
espera) y las imagenes del mapa que no cargaron. Sin senal son miles por
jornada y no son fallos de la app.

---

## Que va en S3 y que en Airtable

La linea divisoria no es *binario vs. texto*, es **si el dato puede crecer sin
techo**. Un GeoJSON es texto plano y aun asi va a S3, porque un recorrido de
jornada completa no cabe en un `Long text`.

| Dato | Donde | Por que |
|---|---|---|
| MBTiles | S3 | Cientos de MB |
| Original de topografia (GeoPDF/GeoTIFF) | S3 | Pesado, y se conserva para reconvertir |
| GeoJSON del trazado | S3 | Crece con los vertices, sin techo |
| KML / KMZ / GPX / PDF | S3 | Entregables, pueden pesar |
| Fotos | S3 | Binario |
| Miniatura del mapa | Airtable (Attachment) | Unos KB, y es lo que hace legible la tabla |
| PDF y fotos, ademas | Airtable (Attachment) | Copia para poder verlos en la base. S3 sigue siendo el original |
| Bbox, centroide, area, distancia, conteo, precision | Airtable | Tamano fijo, y es lo que se consulta y se filtra |
| Vista previa simplificada | Airtable | 50 vertices como maximo. Para ver la forma, no para medir |

### Estructura del bucket

Todo cuelga del proyecto. No es cosmetica: borrar un proyecto tiene que poder
llevarse **todo** lo suyo con un solo `delete` por prefijo, sin ir a buscar
archivos sueltos por otras carpetas.

```
s3://sirius-geomaps/
  proyectos/<codigo proyecto>/
    mapas/<codigo mapa>.mbtiles
    mapas/originales/<codigo mapa>.pdf
    mapas/miniaturas/<codigo mapa>.png
    geometrias/<codigo trazado>.geojson
    kml/<nombre>.kml
    gpx/<nombre>.gpx
    pdf/<nombre>.pdf
    fotos/<codigo waypoint>/<uuid>.jpg
```

### Como se lee un trazado completo

1. Airtable da la fila: nombre, area, precision, `Llave geometria`.
2. El backend firma una URL de lectura de esa llave (`GET`, TTL corto).
3. Quien consulta baja el GeoJSON.

El telefono **no** hace ese viaje para trabajar: su copia local en SQLite tiene
la geometria completa y es la fuente de verdad mientras esta en campo. El
archivo de S3 es para el resto del mundo.

### Acceso a S3

El bucket es **privado**. Nada se sirve publico:

- La app sube con una **URL prefirmada de escritura** que pide al backend. Asi
  el telefono nunca tiene credenciales de AWS adentro del APK.
- La app descarga mapas con una **URL prefirmada de lectura**, con TTL largo
  (una descarga de 400 MB sobre red rural tarda).
- Airtable recibe una prefirmada de lectura solo para los `Attachment`. Airtable
  **copia** el archivo a su propio almacenamiento al momento de escribir, asi
  que el adjunto sigue funcionando despues de que la URL expire.

---

## Aislamiento entre cuentas

Con registro abierto, la base deja de ser de una sola empresa: guarda predios de
gente que no se conoce entre si. **Airtable no tiene seguridad por fila.** El
PAT ve la base entera, siempre.

Lo unico que separa a un usuario de los linderos de otro es que ese PAT vive
solo en el backend y que **el backend filtra por `Dueno Auth UID` en cada
consulta**. Un solo endpoint que se olvide del filtro entrega datos ajenos.

Por eso el filtro no se escribe a mano en cada servicio: sale de una sola
funcion (`services/auth.py:formula_del_duenno`) y toda lectura pasa por ella.
Es la clase de regla que no se sostiene con disciplina, se sostiene con que no
haya otra forma de escribir la consulta.

Los mismos dos cuidados que trae abrir el registro:

- **Cuota por cuenta** (`CUOTA_MB_POR_USUARIO`). Registro abierto mas subida
  libre a S3 es una factura de AWS pagada por cuenta ajena. El limite tiene que
  existir antes que el primer abuso, no despues.

  La verificacion de correo que haria falta con registro por contrasena aca no
  aplica: Google ya entrega el correo verificado.

## Baja de cuenta

Si alguien pide borrar su cuenta hay que poder cumplirlo, y con esta estructura
se puede porque todo cuelga del proyecto y el proyecto cuelga del `Auth UID`:

1. Borrar en S3 cada prefijo `proyectos/<codigo>/` de sus proyectos.
2. Borrar sus filas en Airtable, de las hojas a la raiz.
3. Borrar su fila de `Usuarios`.

El orden importa: borrar primero al usuario deja archivos en S3 sin forma de
saber de quien eran. No hay que dar de baja nada en Google — la cuenta es de la
persona, nosotros solo dejamos de reconocer su `sub`.

Lo hace `DELETE /v1/cuenta` (`services/cuenta.py`), que la app llama desde
"Mi cuenta > Eliminar mi cuenta". Tambien borra sus `Sincronizaciones`,
sus `Dispositivos` y sus `Errores` (estos por `Auth UID`, no por enlace). Las cuentas `Soporte` y `Admin` no se dan de baja solas: pueden
ser duenas de proyectos de la empresa, y esas se borran a mano. Quien pide la
baja por correo (ver `/eliminar-cuenta`) se da de baja a mano siguiendo estos
mismos pasos.

---

## Reglas que aplica el backend, no el modelo

0. **Los Single select se traducen en un solo lugar.** El telefono manda el
   `.name` de Dart (`ruta`, `calculada`) y `backend/app/schemas_sync.py` lo
   pasa a la opcion de aca (`Ruta`, `Calculada`). Lo que no esta en esa tabla
   se rechaza: con `typecast` un valor sin traducir no falla, crea una opcion
   nueva al lado de la buena.

1. **Upsert por UUID, siempre.** Buscar por `Codigo X` y actualizar si existe.
   La red movil rural corta a mitad de un POST mas seguido de lo que parece.
2. **Un trazado sin `Precision media` no se marca como apto para lindero.** El
   dato existe, pero la app lo muestra con aviso.
3. **`Area (ha)` la calcula el telefono, no Airtable.** Si la recalcula el
   backend con otra formula, el numero del papel y el de la base no coinciden y
   ninguno de los dos es creible.
4. **Un `Mapa` en estado `Procesando` no se le ofrece al telefono.** Descargar
   un MBTiles a medio escribir deja la app con un mapa corrupto y sin error.
5. **Primero S3, despues Airtable.** El GeoJSON se sube y se confirma ANTES de
   escribir la fila del trazado. Al reves, una fila con `Llave geometria`
   apuntando a un objeto que no existe es un trazado que en la base parece estar
   y al abrirlo no esta — peor que no tenerlo.
6. **La `Llave geometria` no se reescribe: se versiona.** Editar un trazado
   escribe `<codigo>.geojson` de nuevo con versionado de S3 activo. Sobrescribir
   sin versiones deja sin forma de recuperar un lindero que alguien borro por
   error, y eso en campo no se puede volver a levantar sin caminarlo otra vez.
