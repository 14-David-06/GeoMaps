"""Arma un pliego de prueba, georreferenciado, para probar la importacion de
planos grandes en el telefono.

Sale un PDF de una hoja de 119 x 84 cm, dibujado -no escaneado-: una
cuadricula, unas vias y rotulos chicos en cada cruce. Es el caso que una
imagen sola de 4096 pixeles deja ilegible, y el que la app tiene que afinar
con cuadros de detalle. No trae ningun dato del predio: son lineas inventadas
puestas alrededor de unas coordenadas publicas.

No necesita nada instalado: escribe el PDF a mano.

    python tools/plano_de_prueba.py                 # plano-de-prueba.pdf
    python tools/plano_de_prueba.py otro.pdf

Para probarlo: copiarlo al telefono (por ejemplo
`adb push plano-de-prueba.pdf /sdcard/Download/`), y en la app ir a Mapa >
Capas > Planos > Elegir un PDF. Lo que hay que ver:

- que el plano aparezca enseguida, como siempre;
- que en la lista de planos diga "Mejorando el detalle: N de 48" y avance;
- que al acercarse los rotulos "V-0312" se lean nitidos, y que no se note
  donde empalma un cuadro con el de al lado, tampoco con el mapa girado.
"""

import sys

# La hoja, en puntos: un pliego acostado.
ANCHO, ALTO = 3370, 2384
# El plano adentro de la hoja: lo demas es el marco y el membrete.
X0, Y0, X1, Y1 = 60, 84, 3300, 2304

# Donde cae el plano en el mundo: unos 24 x 16 km del piedemonte llanero.
SUR, NORTE = 4.200, 4.345
OESTE, ESTE = -73.000, -72.785


def contenido() -> bytes:
    """El dibujo de la hoja: lo que un motor de PDF sabe pintar sin fuentes
    ni imagenes adentro."""
    s = []
    # El papel, blanco, de punta a punta: la app lo tiene que quitar.
    s.append(f"1 1 1 rg 0 0 {ANCHO} {ALTO} re f")
    # El marco de la hoja y el membrete, que la app no tiene que dibujar.
    s.append("0 0 0 RG 3 w 20 20 %d %d re S" % (ANCHO - 40, ALTO - 40))
    s.append("BT /F1 28 Tf 70 36 Td (PLANO DE PRUEBA - GeoMaps) Tj ET")

    # Un relleno palido, como un lote: sin papel tiene que quedar un velo.
    s.append("0.96 0.93 0.70 rg 900 700 1100 800 re f")
    s.append("0.80 0.92 0.80 rg 2100 1500 700 500 re f")

    # La cuadricula.
    s.append("0.55 0.55 0.55 RG 0.6 w")
    for x in range(X0, X1 + 1, 90):
        s.append(f"{x} {Y0} m {x} {Y1} l S")
    for y in range(Y0, Y1 + 1, 90):
        s.append(f"{X0} {y} m {X1} {y} l S")

    # Unas vias, mas gruesas y en diagonal: ahi se ve si los cuadros empalman.
    s.append("0.75 0.10 0.10 RG 4 w")
    s.append(f"{X0} {Y0 + 300} m 1200 1300 l 2300 900 l {X1} {Y1 - 200} l S")
    s.append("0.10 0.25 0.70 RG 2.5 w")
    s.append(f"{X0 + 400} {Y1} m 1500 1700 c 1900 1200 2200 700 2600 {Y0} c S")
    s.append("0.10 0.10 0.10 RG 1.2 w")
    for i in range(12):
        x = X0 + 150 + i * 260
        s.append(f"{x} {Y0} m {x + 180} {Y1} l S")

    # Los rotulos: letra de 6 puntos, la que se pierde en una imagen sola.
    s.append("0 0 0 rg")
    numero = 0
    for y in range(Y0 + 45, Y1, 90):
        for x in range(X0 + 12, X1 - 60, 180):
            numero += 1
            s.append(f"BT /F1 6 Tf {x} {y} Td (V-{numero:04d}) Tj ET")
    for i, nombre in enumerate(
        ["VEREDA LA ESPERANZA", "CANO GUAYURIBA", "VIA AL PATIO", "SECTOR 9"]
    ):
        s.append(
            f"BT /F1 16 Tf {500 + i * 700} {600 + i * 380} Td ({nombre}) Tj ET"
        )
    return ("\n".join(s) + "\n").encode("latin-1")


def armar() -> bytes:
    dibujo = contenido()
    # Las esquinas en el orden en que las escriben los programas: suroeste,
    # noroeste, noreste y sureste, cada una como latitud y longitud.
    gpts = (
        f"{SUR} {OESTE} {NORTE} {OESTE} {NORTE} {ESTE} {SUR} {ESTE}"
    )
    objetos = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        (
            f"<</Type/Page/Parent 2 0 R/MediaBox[0 0 {ANCHO} {ALTO}]"
            f"/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R"
            f"/VP[<</Type/Viewport/BBox[{X0} {Y1} {X1} {Y0}]/Measure 6 0 R>>]>>"
        ).encode("latin-1"),
        b"<</Length %d>>\nstream\n" % len(dibujo) + dibujo + b"endstream",
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>",
        (
            "<</Type/Measure/Subtype/GEO/Bounds[0 1 0 0 1 0 1 1]"
            f"/GPTS[{gpts}]>>"
        ).encode("latin-1"),
    ]

    salida = bytearray(b"%PDF-1.6\n%\xe2\xe3\xcf\xd3\n")
    posiciones = []
    for numero, cuerpo in enumerate(objetos, start=1):
        posiciones.append(len(salida))
        salida += b"%d 0 obj\n" % numero + cuerpo + b"\nendobj\n"
    tabla = len(salida)
    salida += b"xref\n0 %d\n" % (len(objetos) + 1)
    salida += b"0000000000 65535 f \n"
    for p in posiciones:
        salida += b"%010d 00000 n \n" % p
    salida += b"trailer\n<</Size %d/Root 1 0 R>>\n" % (len(objetos) + 1)
    salida += b"startxref\n%d\n%%%%EOF\n" % tabla
    return bytes(salida)


if __name__ == "__main__":
    destino = sys.argv[1] if len(sys.argv) > 1 else "plano-de-prueba.pdf"
    datos = armar()
    with open(destino, "wb") as archivo:
        archivo.write(datos)
    print(f"{destino}: {len(datos) / 1024:.0f} KB, hoja de {ANCHO} x {ALTO} puntos")
