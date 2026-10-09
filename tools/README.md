# tools — conversion de mapas

Aca viven los comandos de GDAL que convierten lo que manda topografia en el
MBTiles que lee el telefono. **No corren en Vercel ni en el telefono**: Vercel
no trae GDAL y una funcion serverless no tiene ni el tiempo ni el disco para
cortar la piramide de un raster de 2 GB.

Se usan de dos formas: el worker los invoca, y una persona los corre a mano
cuando el archivo es demasiado grande para pasar por el endpoint.

## Requisito

GDAL 3.8+ **con soporte de PDF**: el driver no viene en todas las
compilaciones. Si ya tienes QGIS instalado, no hace falta nada mas -lo trae
completo, y `convertir_mapa.py` lo encuentra solo-. Si no:

```bash
conda install -c conda-forge gdal
gdalinfo --formats | grep -i pdf     # tiene que aparecer PDF
```

## La forma corta: convertir_mapa.py

Hace las cuatro pasadas de abajo, sube el MBTiles y el original al bucket y
deja la ficha en la tabla `Mapas` en `Listo`. Desde ahi la app lo ve en el
catalogo del proyecto.

```bash
backend/.venv/Scripts/python tools/convertir_mapa.py "plano.pdf"     --proyecto <codigo del proyecto> --nombre "Acopios 2026"
```

Con `--simular` convierte y mide sin subir ni tocar Airtable: es la forma de
probar un DPI antes de gastar el ancho de banda.

**El DPI es la unica decision irreversible**, porque es el detalle que va a
existir para siempre en las teselas. Un plano del predio de Guaicaramo
(36 x 24 km, carta doble) da:

| `--dpi` | Zoom maximo | Pesa |
|---|---|---|
| 150 | 13 | 1,2 MB |
| 300 | 14 | 3,2 MB |
| 600 | 15 | 8,2 MB |

Zoom 15 son unos 3 m por pixel: alcanza para leer los rotulos de bloque, no
para distinguir dos palmas. Subir el DPI cuesta el cuadrado en peso, asi que
600 es el techo razonable para un plano de predio completo.

`--zoom-max N` corta por arriba cuando el archivo da mas detalle del que hace
falta. No se le pide al driver de MBTiles -no tiene esa opcion y la ignora en
silencio-: se impone remuestreando a los metros por pixel de ese nivel.

## Las cuatro pasadas, a mano

Lo que hace el script. Sirve para depurar un archivo raro.

```bash
# 1. Ver que trae el archivo. Lo que se busca es el SRC y si tiene capas.
gdalinfo entrada.pdf

# 2. Rasterizar a GeoTIFF en Web Mercator.
#    -dpi 300 porque por debajo de eso el texto del plano no se lee al hacer
#    zoom, que es justo para lo que se carga un plano de topografia.
gdal_translate -of GTiff --config GDAL_PDF_DPI 300 entrada.pdf paso1.tif

# 3. Reproyectar. -s_srs SOLO si el archivo no declara el suyo; si lo declara,
#    forzarlo a mano es como se corren los mapas unos cientos de metros.
#    -dstalpha porque el plano queda girado al reproyectar: sin banda alfa las
#    esquinas que sobran se rellenan de negro, y esto va ENCIMA del satelital.
gdalwarp -t_srs EPSG:3857 -r bilinear -dstalpha paso1.tif paso2.tif

# 4. Cortar la piramide y empacar en MBTiles.
gdal_translate -of MBTILES -co TYPE=overlay paso2.tif salida/mapa.mbtiles
gdaladdo -r average salida/mapa.mbtiles 2 4 8 16 32
```

El `gdaladdo` no es opcional: sin los niveles bajos, alejar el mapa en el
telefono deja la pantalla en blanco.

## GeoTIFF -> MBTiles

Igual, desde el paso 3.

## KMZ -> GeoJSON

Para las capas vectoriales (vias, linderos). Se sirven como GeoJSON, no como
teselas: son pocos KB y se dibujan encima de cualquier mapa base.

```bash
ogr2ogr -f GeoJSON salida/vias.geojson entrada.kmz
```

`map-security` tiene un conversor sin dependencias para este caso
(`scripts/kmz-a-geojson.mjs`) si no se quiere instalar GDAL solo para esto.

## Verificar antes de publicar

```bash
gdalinfo salida/mapa.mbtiles     # bbox en WGS84, zoom min y max
```

Ese bbox y esos zooms son los que van a la ficha del mapa en Airtable. Si no
coinciden con lo que la app tiene registrado, el encuadre inicial abre en el
lugar equivocado.

## Perimetro de un predio (para habilitar su mapa por ubicacion)

`perimetro_guaicaramo.py` genera el asset con el borde del predio, que es lo que
decide si su mapa se habilita en el telefono. **Ese asset no esta en el
repositorio**: son datos del cliente. Ver `app/assets/zonas/LEEME.md`.

```bash
pip install pypdf shapely
python tools/perimetro_guaicaramo.py "<ruta del plano>.pdf"
```

Normalmente no existe ningun archivo con "el borde del predio". El unico dato
duro son los poligonos de parcela de la capa `PARCELA` del plano del
Departamento Agronomico, que es un PDF geoespacial.

De un monton de lotes sueltos a un perimetro, en tres pasos:

1. **Union** de los poligonos de parcela.
2. **Cierre de 120 m** (dilatar y volver a contraer). Cose los lotes separados
   por vias y canales internos. Sin esto, un tractorista parado en la via de su
   propio bloque quedaria "fuera" de la plantacion.
3. **Margen de 50 m** hacia afuera, por el error del GPS bajo el dosel. Sin el,
   la funcion se apagaria sola caminando el lindero.

El parseo del PDF no se reimplementa: se reutiliza el de
`map-security/scripts/pdf-acopios-a-geojson.py`, asi que ese repo tiene que
estar al lado de este.

**Los controles los imprime el propio script** al terminar, contra fuentes que
no participaron del calculo: los acopios del plano tienen que caer adentro, y
las vias marcadas `Interna` tienen que quedar mayoritariamente dentro mientras
las `Externa` quedan mayoritariamente fuera. Ese contraste es lo que muestra que
el perimetro discrimina y no es una mancha que traga todo. Tambien comprueba que
ciudades vecinas queden afuera.

## Vias y lotes de un predio (capas vectoriales del mapa)

```bash
python tools/vias_guaicaramo.py     "<ruta>/vias.kmz"
python tools/parcelas_guaicaramo.py "<ruta del plano>.pdf"
```

`vias_*` sale del KMZ de topografia; `parcelas_*` de la capa `PARCELA` del mismo
plano geoespacial, con el codigo de bloque y parcela de cada lote. **Ninguno de
los dos assets se versiona.**

Se dibujan como vectores y no como teselas: se ven nitidos a cualquier zoom y no
le piden un byte a la red, que es lo que hace falta adentro de un predio.

**No se guardan como GeoJSON.** El mismo dato en GeoJSON pesa casi el doble, y
la mitad es sintaxis repetida mas atributos de SIG que la app no usa. El asset
lleva solo lo que se dibuja o se muestra, con las coordenadas en un array plano.

### El atributo que hay que respetar es `TIPO`

Una parte de las vias del KMZ son `Proyectada`: **no estan construidas**. Se
dibujan punteadas y apagadas, y la leyenda lo dice con todas las letras.
Pintarlas como las demas manda a alguien a buscar una entrada que no existe, y
en un predio grande eso es un rodeo de kilometros con el fruto arriba del
tractor.

### Rotulos de los lotes

Conviven dos formas de nombrar un lote y las dos son validas: el **codigo**
(`B.10-P.9`) y el **nombre propio** de los lotes que no son palma -citricos,
frutales, viveros-, que en campo se llaman asi. Algunos lotes no tienen rotulo
en el plano: se dibujan igual, porque el lindero vale aunque no se sepa el
nombre.

El emparejamiento entre un rotulo y su lote es por cercania y no es perfecto.
El script cuenta cuantos codigos quedan repetidos en dos lotes y avisa si son
muchos: cuando ese numero crece, el emparejamiento se desalineo y el mapa
empezaria a rotular lotes con el nombre del vecino.

Cada script imprime sus propios controles al terminar. Los numeros concretos del
predio salen de ahi, que es donde sirven: no se copian a esta documentacion, que
es publica.

## Acopios de un predio

`acopios_guaicaramo.py` genera el asset con los acopios, que en el mapa se tocan
para trazar la ruta hasta ellos. No vuelve a leer el plano: parte de
`map-security/public/acopios-guaicaramo.geojson`, que ya saca el parser de
map-security (`scripts/pdf-acopios-a-geojson.py`) desde la capa `Acopios`.

```bash
python tools/acopios_guaicaramo.py [<acopios.geojson>]
```

Imprime dos controles: cuantos pares (lote, numero) se repiten -tiene que ser
casi ninguno- y cuantos acopios caen fuera del perimetro del predio.
