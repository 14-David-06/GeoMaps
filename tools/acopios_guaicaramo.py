# -*- coding: utf-8 -*-
"""Genera app/assets/zonas/guaicaramo-acopios.json: los acopios del predio.

    python tools/acopios_guaicaramo.py [<acopios.geojson>]

Los acopios son los puntos donde se deja el fruto cosechado para que lo recoja
el tractor. Salen de la capa `Acopios` del plano del Departamento Agronomico, y
el que ya los saco de ahi es el parser de map-security
(`scripts/pdf-acopios-a-geojson.py`), que deja
`map-security/public/acopios-guaicaramo.geojson`. Sin argumento se lee ese.

No se vuelve a parsear el PDF aca: el emparejamiento de cada simbolo con su
numero es por cercania y tiene sus vueltas, y tener dos versiones de esa
decision es tener dos respuestas distintas para el mismo acopio.

## Que va al asset

- **numero** del acopio, como esta rotulado en el plano. Se repite entre lotes:
  hay un acopio 30 en muchos lotes, asi que a secas no identifica.
- **lote** donde cae (`B.9-P.2`), recortado al codigo como en el asset de
  lotes. Es lo que vuelve unico al numero y como se lo nombra en campo: "el 30
  del B.9-P.2".
- **posicion**, redondeada a 6 decimales (~0,1 m).
"""
import json
import os
import re
import sys
from collections import Counter

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.normpath(os.path.join(AQUI, '..'))
DESTINO = os.path.join(RAIZ, 'app', 'assets', 'zonas', 'guaicaramo-acopios.json')
PERIMETRO = os.path.join(RAIZ, 'app', 'assets', 'zonas', 'guaicaramo.json')

ORIGEN = os.path.normpath(
    os.path.join(RAIZ, '..', 'map-security', 'public', 'acopios-guaicaramo.geojson')
)

DECIMALES = 6
RE_BP = re.compile(r'^B\.(\d+)-P\.(\d+)')


def main():
    origen = sys.argv[1] if len(sys.argv) > 1 else ORIGEN
    if not os.path.exists(origen):
        sys.exit('no esta %s\n(se genera con map-security/scripts/'
                 'pdf-acopios-a-geojson.py desde el plano)' % origen)

    feats = json.load(open(origen, encoding='utf-8'))['features']
    acopios = [a for a in (leer(f) for f in feats) if a]
    print('acopios:', len(acopios))
    print('con numero:', sum(1 for a in acopios if a['num']))
    print('con lote:', sum(1 for a in acopios if a['lote']))

    verificar(acopios)
    escribir(acopios)


def leer(f):
    geo = f.get('geometry') or {}
    if geo.get('type') != 'Point':
        return None
    lon, lat = geo['coordinates'][:2]
    props = f.get('properties') or {}
    return {
        'num': (props.get('num') or '').strip(),
        'lote': limpiar(props.get('lote')),
        'lon': round(lon, DECIMALES),
        'lat': round(lat, DECIMALES),
    }


def limpiar(lote):
    """El mismo recorte que el asset de lotes: "B.9-P.2 (R.)" -> "B.9-P.2".

    Los lotes con nombre propio ("Chiguiros 2 (R.)") se dejan enteros.
    """
    if not lote:
        return ''
    m = RE_BP.match(lote.strip())
    return m.group(0) if m else lote.strip()


def verificar(acopios):
    print()
    print('--- control ---')

    # Dentro de un mismo lote el numero tiene que ser unico. Unos pocos
    # repetidos los arrastra el emparejamiento por cercania del parser; si
    # crecen, se desalineo.
    pares = Counter((a['lote'], a['num']) for a in acopios
                    if a['lote'] and a['num'])
    repetidos = sum(1 for v in pares.values() if v > 1)
    print('    pares (lote, numero) repetidos:', repetidos)
    if repetidos > 5:
        print('    OJO: son muchos, revisar el emparejamiento del parser')

    # Todo acopio tiene que caer adentro del predio. Uno afuera es un simbolo
    # leido en otro sistema de coordenadas o un rotulo de la leyenda del plano.
    if not os.path.exists(PERIMETRO):
        print('    (no esta el perimetro, se salta el control de borde)')
        return
    try:
        from shapely.geometry import Point, Polygon
        from shapely.ops import unary_union
    except ImportError:
        print('    (sin shapely, se salta el control de borde)')
        return
    # El perimetro es una lista de sectores, cada uno un anillo [lon, lat].
    sectores = json.load(open(PERIMETRO, encoding='utf-8'))['sectores']
    borde = unary_union([Polygon(s).buffer(0) for s in sectores])
    afuera = sum(1 for a in acopios
                 if not borde.contains(Point(a['lon'], a['lat'])))
    print('    acopios fuera del perimetro:', afuera)


def escribir(acopios):
    datos = {
        '_fuente': 'Plano del Departamento Agronomico, capa Acopios. '
                   'CONFIDENCIAL, no versionar.',
        '_generado': 'tools/acopios_guaicaramo.py -- no editar a mano',
        'acopios': [
            {'n': a['num'], 'l': a['lote'], 'x': a['lon'], 'y': a['lat']}
            for a in acopios
        ],
    }

    os.makedirs(os.path.dirname(DESTINO), exist_ok=True)
    with open(DESTINO, 'w', encoding='utf-8') as f:
        json.dump(datos, f, ensure_ascii=False, separators=(',', ':'))

    print()
    print('escrito %s (%.0f KB)'
          % (DESTINO, os.path.getsize(DESTINO) / 1024))


if __name__ == '__main__':
    main()
