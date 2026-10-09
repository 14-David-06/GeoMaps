import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/acopios.dart';

/// Los acopios: el parseo del asset y el buscador.
///
/// El buscador se prueba con datos inventados -este repositorio es publico- y
/// el asset real, si esta, solo se revisa por coherencia interna.
void main() {
  final inventados = AcopiosPredio.deJson(
    jsonEncode({
      'acopios': [
        {'n': '30', 'l': 'B.9-P.2', 'x': -72.9, 'y': 4.4},
        {'n': '3', 'l': 'B.9-P.2', 'x': -72.9, 'y': 4.4},
        {'n': '30', 'l': 'B.10-P.1', 'x': -72.9, 'y': 4.4},
        {'n': '31', 'l': 'B.4-P.10', 'x': -72.9, 'y': 4.4},
        {'n': '', 'l': '', 'x': -72.9, 'y': 4.4},
      ],
    }),
  );

  group('buscar', () {
    test('sin texto devuelve todos', () {
      expect(inventados.buscar('  '), hasLength(5));
    });

    test('el numero exacto va primero', () {
      final r = inventados.buscar('3');
      expect(r.first.numero, '3');
      expect(r.map((a) => a.numero), containsAll(['30', '31']));
    });

    test('numero y lote juntos acotan', () {
      final r = inventados.buscar('30 b.9');
      expect(r, hasLength(1));
      expect(r.single.lote, 'B.9-P.2');
    });

    test('por lote solo', () {
      expect(inventados.buscar('B.4-P.10').single.numero, '31');
    });
  });

  test('nombres', () {
    expect(inventados.acopios.first.etiqueta, 'Acopio 30 · B.9-P.2');
    expect(inventados.acopios.last.etiqueta, 'Acopio sin numero');
  });

  final archivo = File('assets/zonas/guaicaramo-acopios.json');
  test(
    'el asset del predio se lee y cae cerca de los lotes',
    skip: archivo.existsSync()
        ? false
        : 'sin assets/zonas/guaicaramo-acopios.json (son confidenciales; '
              'ver assets/zonas/LEEME.md para generarlos)',
    () {
      final acopios = AcopiosPredio.deJson(archivo.readAsStringSync());
      expect(acopios.acopios, isNotEmpty);

      // Contra el encuadre del perimetro, que es otro archivo: un acopio fuera
      // de el seria un simbolo leido en otro sistema de coordenadas.
      final zona = File('assets/zonas/guaicaramo.json');
      if (!zona.existsSync()) return;
      final b = ((jsonDecode(zona.readAsStringSync()) as Map)['bbox'] as List)
          .cast<num>();
      final adentro = acopios.acopios.where(
        (a) =>
            a.punto.longitude >= b[0] &&
            a.punto.latitude >= b[1] &&
            a.punto.longitude <= b[2] &&
            a.punto.latitude <= b[3],
      );
      expect(adentro.length / acopios.acopios.length, greaterThan(0.98));
    },
  );
}
