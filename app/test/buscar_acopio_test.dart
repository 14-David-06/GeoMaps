import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/acopios.dart';
import 'package:geomaps/ui/capa_acopios.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:latlong2/latlong.dart';

/// Buscar un acopio cuando el numero se repite.
///
/// Hay un acopio 38 en seis lotes. Antes, escribir "38" traia ademas todo lo
/// que tuviera un 38 en el nombre del lote, en filas chicas que decian
/// `Lote B.9-P.2`. Lo que se prueba: que el numero busque el numero, que el
/// bloque se elija con un toque, y que se lea.
void main() {
  final acopios = AcopiosPredio.deJson(
    jsonEncode({
      'acopios': [
        {'n': '38', 'l': 'B.31-P.1', 'x': -72.90, 'y': 4.40},
        {'n': '38', 'l': 'B.9-P.2', 'x': -72.96, 'y': 4.45},
        {'n': '38', 'l': 'B.11-P.22', 'x': -72.93, 'y': 4.43},
        {'n': '38A', 'l': 'B.9-P.2', 'x': -72.96, 'y': 4.451},
        // Los que antes se colaban: un 38 en el bloque y otro en la parcela.
        {'n': '5', 'l': 'B.38-P.1', 'x': -72.95, 'y': 4.44},
        {'n': '7', 'l': 'B.4-P.38', 'x': -72.95, 'y': 4.44},
        {'n': '12', 'l': 'Chiguiros 3 (R.)', 'x': -72.94, 'y': 4.42},
        {'n': '', 'l': '', 'x': -72.94, 'y': 4.42},
      ],
    }),
  );

  // Parado al lado del 38 del bloque 9.
  const aqui = LatLng(4.4501, -72.9601);

  group('la busqueda', () {
    test('un numero busca el numero del acopio, no el del lote', () {
      final r = acopios.buscar('38');
      expect(r.map((a) => a.numero), ['38', '38', '38', '38A']);
      expect(r.map((a) => a.lote), isNot(contains('B.38-P.1')));
      expect(r.map((a) => a.lote), isNot(contains('B.4-P.38')));
    });

    test('el exacto va antes que el que empieza igual', () {
      expect(acopios.buscar('38').last.numero, '38A');
      expect(acopios.buscar('38a').single.lote, 'B.9-P.2');
    });

    test('un segundo numero es el bloque o la parcela', () {
      expect(acopios.buscar('38 31').single.lote, 'B.31-P.1');
      expect(acopios.buscar('38 22').single.lote, 'B.11-P.22');
      // Mientras se escribe "11", con el primer 1 ya acota.
      expect(acopios.buscar('38 1').map((a) => a.lote), [
        'B.31-P.1',
        'B.11-P.22',
      ]);
    });

    test('el lote se escribe como salga: con puntos, sin puntos', () {
      expect(acopios.buscar('38 b9').first.lote, 'B.9-P.2');
      expect(acopios.buscar('38 B.9-P.2').first.lote, 'B.9-P.2');
      expect(acopios.buscar('b38').single.numero, '5');
      expect(acopios.buscar('chiguiros').single.numero, '12');
    });

    test('dice que numero se esta buscando', () {
      expect(AcopiosPredio.numeroBuscado('38 b9'), '38');
      expect(AcopiosPredio.numeroBuscado(' 30A '), '30a');
      expect(AcopiosPredio.numeroBuscado('chiguiros'), isNull);
      expect(AcopiosPredio.numeroBuscado(''), isNull);
    });
  });

  group('el nombre', () {
    test('el bloque y la parcela con todas las letras', () {
      final a = acopios.acopios[1];
      expect(a.bloque, '9');
      expect(a.parcela, '2');
      expect(a.lugar, 'Bloque 9 · Parcela 2');
      expect(a.etiquetaLarga, 'Acopio 38 · Bloque 9 · Parcela 2');
      // La corta no cambia: es como se guardaron las rutas hasta ahora.
      expect(a.etiqueta, 'Acopio 38 · B.9-P.2');
    });

    test('un lote con nombre propio se deja como esta', () {
      final a = acopios.buscar('12').single;
      expect(a.bloque, isNull);
      expect(a.lugar, 'Chiguiros 3 (R.)');
      expect(a.etiquetaLarga, 'Acopio 12 · Chiguiros 3 (R.)');
    });

    test('fuera de todo lote no inventa un lugar', () {
      final a = acopios.acopios.last;
      expect(a.lugar, '');
      expect(a.etiquetaLarga, 'Acopio sin numero');
    });
  });

  group('el orden', () {
    test('el mas cercano primero', () {
      final r = porCercania(acopios.buscar('38'), aqui);
      expect(r.first.lote, 'B.9-P.2');
      expect(r.last.lote, 'B.31-P.1');
    });

    test('los bloques se ordenan como numeros', () {
      final bloques = ['31', '9', '11', '335', 'x']..sort(compararNumerico);
      expect(bloques, ['9', '11', '31', '335', 'x']);
    });
  });

  group('la pantalla', () {
    Future<Acopio? Function()> abrir(
      WidgetTester tester, {
      LatLng? desde = aqui,
    }) async {
      Acopio? elegido;
      await tester.pumpWidget(
        MaterialApp(
          theme: temaSirius,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  elegido = await buscarAcopio(context, acopios, desde: desde);
                },
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      return () => elegido;
    }

    testWidgets('al escribir el numero ofrece los bloques que lo tienen', (
      tester,
    ) async {
      await abrir(tester);
      await tester.enterText(find.byType(TextField), '38');
      await tester.pumpAndSettle();

      expect(find.text('Hay 4 acopios. Elige el bloque:'), findsOneWidget);
      // Un boton por bloque, y ordenados como numeros.
      final botones = ['Todos', 'Bloque 9', 'Bloque 11', 'Bloque 31'];
      final posiciones = [
        for (final b in botones) tester.getTopLeft(find.text(b).first).dx,
      ];
      expect(posiciones, [...posiciones]..sort());

      // La fila dice el bloque y la parcela enteros, no "Lote B.9-P.2".
      expect(find.text('Parcela 2'), findsWidgets);
      expect(find.textContaining('B.9-P.2'), findsNothing);
      // Y no se cuelan los lotes que tienen un 38 en el nombre.
      expect(find.text('Bloque 38'), findsNothing);
      expect(find.text('Parcela 38'), findsNothing);
    });

    testWidgets('marca cual es el mas cercano', (tester) async {
      await abrir(tester);
      await tester.enterText(find.byType(TextField), '38');
      await tester.pumpAndSettle();

      expect(find.text('EL MAS CERCANO'), findsOneWidget);
      // Es la primera fila, y es la del bloque 9.
      final cartel = tester.getTopLeft(find.text('EL MAS CERCANO'));
      final parcela = tester.getTopLeft(find.text('Parcela 2').first);
      expect(parcela.dy, greaterThan(cartel.dy));
      expect(parcela.dy - cartel.dy, lessThan(90));
    });

    testWidgets('elegir un bloque deja solo los suyos', (tester) async {
      final elegido = await abrir(tester);
      await tester.enterText(find.byType(TextField), '38');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Bloque 11').first);
      await tester.pumpAndSettle();

      expect(find.text('Es este:'), findsOneWidget);
      expect(find.text('Parcela 22'), findsOneWidget);
      expect(find.text('Parcela 1'), findsNothing);

      await tester.tap(find.text('Parcela 22'));
      await tester.pumpAndSettle();
      expect(elegido()!.lote, 'B.11-P.22');
    });

    testWidgets('sin escribir nada ofrece los que estan cerca', (tester) async {
      await abrir(tester);

      expect(find.textContaining('los que tienes cerca'), findsOneWidget);
      expect(find.text('Bloque 9'), findsWidgets);
    });

    testWidgets('sin posicion no inventa cercania', (tester) async {
      await abrir(tester, desde: null);

      expect(find.text('Escribe el numero del acopio.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '38');
      await tester.pumpAndSettle();
      expect(find.text('EL MAS CERCANO'), findsNothing);
      expect(find.textContaining('km'), findsNothing);
    });

    testWidgets('un numero que no existe lo dice', (tester) async {
      await abrir(tester);
      await tester.enterText(find.byType(TextField), '999');
      await tester.pumpAndSettle();

      expect(find.textContaining('No hay ningun acopio'), findsOneWidget);
    });

    testWidgets('con la letra del telefono agrandada no se desborda', (
      tester,
    ) async {
      // Un telefono angosto, con la letra al 130%: como lo tiene configurado
      // quien no ve bien.
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await abrir(tester);
      await tester.enterText(find.byType(TextField), '38');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Bloque 9'), findsWidgets);
    });
  });
}
