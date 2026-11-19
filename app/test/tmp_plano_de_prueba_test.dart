import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/detalle_plano.dart';
import 'package:geomaps/core/geopdf.dart';
import 'package:geomaps/core/importar_geopdf.dart';

// Comprobacion de una vez: el pliego de prueba que arma
// tools/plano_de_prueba.py lo lee la app. Este archivo no se queda.
void main() {
  test('la app lee el pliego de prueba', () {
    final ruta = Platform.environment['PLANO_DE_PRUEBA']!;
    final g = GeoPdf.leerArchivo(ruta);

    // ignore: avoid_print
    print(
      'esquinas: ${g.esquinas}\nrecorte: ${g.recorte.x} ${g.recorte.y} '
      '${g.recorte.ancho} ${g.recorte.alto}\naviso: ${g.aviso}',
    );
    final e = ImportadorGeoPdf.encuadre(g, anchoHoja: 3370, altoHoja: 2384);
    final d = DetallePlano.para(
      anchoPt: g.recorte.ancho,
      altoPt: g.recorte.alto,
      anchoVista: e.anchoPx,
      altoVista: e.altoPx,
    );
    // ignore: avoid_print
    print(
      'entera: ${e.anchoPx} x ${e.altoPx}; detalle: ${d?.ancho} x ${d?.alto} '
      'en ${d?.total} cuadros',
    );
    expect(g.noroeste.latitude, closeTo(4.345, 1e-6));
    expect(g.sureste.longitude, closeTo(-72.785, 1e-6));
    expect(d!.total, 48);
  });
}
