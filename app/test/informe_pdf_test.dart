import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/exportador.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/core/geojson.dart';
import 'package:geomaps/core/informe_pdf.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/db/enums.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/data/waypoints_repository.dart';
import 'package:geomaps/ui/exportar_page.dart';
import 'package:geomaps/ui/theme.dart';

/// El informe PDF de un levantamiento: la hoja que se imprime o se manda a
/// quien no usa mapas.
///
/// Lo que mas se cuida es lo que dice sobre la precision. Un area de 4,2 ha
/// medida con 30 m de error no es el mismo dato que una medida con 3 m, y en
/// el papel se ven iguales si nadie lo escribe.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  const usuario = 'USR-1';
  final manana = DateTime(2026, 11, 18, 7, 30);

  /// Un area marcada tocando el mapa: unas 12 hectareas.
  Future<Trazado> unArea({double lado = 0.0032}) =>
      TrazadosRepository(db).guardarPoligono(
        usuarioCodigo: usuario,
        nombre: 'Lote 4 - La Esperanza',
        vertices: [
          const PuntoGeo(4.4000, -72.9000),
          PuntoGeo(4.4000 + lado, -72.9000),
          PuntoGeo(4.4000 + lado, -72.9000 + lado),
          PuntoGeo(4.4000, -72.9000 + lado),
        ],
      );

  /// Un recorrido grabado con el GPS, con [puntos] posiciones.
  Future<Trazado> unRecorrido({double precision = 4, int puntos = 30}) {
    final linea = [
      for (var i = 0; i < puntos; i++) PuntoGeo(4.40 + i * 0.0002, -72.90),
    ];
    return db
        .into(db.trazados)
        .insertReturning(
          TrazadosCompanion.insert(
            codigo: 'rec-$puntos-${precision.round()}',
            proyectoCodigo: 'local',
            nombre: 'Lindero norte',
            tipo: TipoTrazado.ruta.name,
            metodo: MetodoCaptura.automatico.name,
            geometria: jsonEncode(GeoJson.linea(linea)),
            distanciaM: Value(puntos * 22.1),
            precisionMediaM: Value(precision),
            iniciadoEn: Value(manana),
            terminadoEn: Value(manana.add(const Duration(minutes: 95))),
            usuarioCodigo: const Value(usuario),
            creadoEn: manana,
          ),
        );
  }

  String? dato(ContenidoInforme c, String etiqueta) =>
      c.datos.where((d) => d.etiqueta == etiqueta).firstOrNull?.valor;

  group('lo que dice', () {
    test('de un area: su medida, su perimetro y de donde salio', () async {
      final c = InformePdf.contenido(
        await unArea(),
        proyecto: 'Finca La Esperanza',
        autor: 'Ana Gomez',
      );

      expect(c.tipo, 'Área medida');
      expect(c.titulo, 'Lote 4 - La Esperanza');
      expect(dato(c, 'Proyecto'), 'Finca La Esperanza');
      expect(dato(c, 'Área'), endsWith(' ha'));
      expect(dato(c, 'Perímetro'), contains(' km ('));
      expect(dato(c, 'Vértices'), '4', reason: 'el que cierra no cuenta');
      expect(dato(c, 'Levantado por'), 'Ana Gomez');
      expect(c.conTablaDeVertices, isTrue);
    });

    test('lo marcado a mano dice que no salio del GPS', () async {
      // Sin esto, un area dibujada con el dedo se usa como lindero.
      final c = InformePdf.contenido(await unArea());

      expect(dato(c, 'Cómo se levantó'), contains('sin GPS'));
      expect(dato(c, 'Precisión media del GPS'), isNull);
      expect(c.notas.first, contains('no como lindero'));
      expect(dato(c, 'Proyecto'), 'Sin proyecto');
    });

    test('de un recorrido con buen GPS dice con cuanto error', () async {
      final c = InformePdf.contenido(await unRecorrido(precision: 4));

      expect(c.tipo, 'Recorrido grabado');
      expect(dato(c, 'Precisión media del GPS'), '± 4 m');
      expect(dato(c, 'Duración'), '1 h 35 min');
      expect(dato(c, 'Fecha'), '18/11/2026 07:30');
      expect(c.notas.first, 'El GPS tuvo un error medio de ± 4 m.');
      expect(c.notas, contains(contains('no reemplaza un levantamiento')));
    });

    test('con el GPS impreciso, avisa que la medida es aproximada', () async {
      final c = InformePdf.contenido(await unRecorrido(precision: 28));

      expect(c.notas.first, contains('± 28 m, que es alto'));
      expect(c.notas.first, contains('la distancia es aproximada'));
    });

    test('un recorrido largo no lista sus miles de puntos', () async {
      final c = InformePdf.contenido(await unRecorrido(puntos: 800));

      expect(c.conTablaDeVertices, isFalse);
      expect(c.notas, contains(contains('800 puntos, que no se listan')));
    });

    test('las medidas se escriben como aca', () {
      expect(InformePdf.area(4.2), '4,20 ha');
      expect(InformePdf.area(1234.5), '1.234,50 ha');
      // Menos de una hectarea se entiende mejor en metros.
      expect(InformePdf.area(0.346), '3.460 m² (0,35 ha)');
      expect(InformePdf.distancia(812), '812 m');
      expect(InformePdf.distancia(12480), '12,48 km (12.480 m)');
    });
  });

  group('el archivo', () {
    bool esPdf(List<int> bytes) =>
        ascii.decode(bytes.sublist(0, 5)) == '%PDF-' && bytes.length > 1500;

    test('se arma para un area, con sus puntos marcados', () async {
      final area = await unArea();
      final marca = await WaypointsRepository(db).marcar(
        usuarioCodigo: usuario,
        nombre: 'Mojon de la esquina',
        punto: const PuntoGeo(4.4001, -72.8999),
        precisionM: 5,
        nota: 'Pintado de rojo',
      );

      final bytes = await InformePdf.deTrazado(area, marcas: [marca]);

      expect(esPdf(bytes), isTrue);
    });

    test('se arma para un recorrido de miles de puntos', () async {
      final bytes = await InformePdf.deTrazado(await unRecorrido(puntos: 3000));

      expect(esPdf(bytes), isTrue);
    });

    test('un area con muchos vertices pasa de hoja sin romperse', () async {
      final muchos = await TrazadosRepository(db).guardarPoligono(
        usuarioCodigo: usuario,
        nombre: 'Lindero largo',
        vertices: [
          for (var i = 0; i < 140; i++)
            PuntoGeo(4.40 + 0.01 * (i % 2), -72.90 + i * 0.0001),
        ],
      );

      final bytes = await InformePdf.deTrazado(muchos);

      expect(esPdf(bytes), isTrue);
    });

    test('un nombre con un emoji no deja a nadie sin informe', () async {
      // Las fuentes del PDF no conocen un emoji, y con una sola letra que no
      // conozcan el documento entero no se arma.
      final area = await TrazadosRepository(db).guardarPoligono(
        usuarioCodigo: usuario,
        nombre: 'Lote de la ñata 🌴 — sector 日本',
        vertices: const [
          PuntoGeo(4.40, -72.90),
          PuntoGeo(4.41, -72.90),
          PuntoGeo(4.41, -72.89),
        ],
      );
      final marca = await WaypointsRepository(db).marcar(
        usuarioCodigo: usuario,
        nombre: 'Árbol caído 😬',
        punto: const PuntoGeo(4.405, -72.895),
      );

      final bytes = await InformePdf.deTrazado(
        area,
        marcas: [marca],
        autor: 'José Ñáñez',
      );

      expect(esPdf(bytes), isTrue);
    });

    test('un recorrido sin puntos tampoco lo rompe', () async {
      final vacio = await TrazadosRepository(db)
          .abrirGrabacion(usuarioCodigo: usuario, nombre: 'Recorrido vacio');

      expect(esPdf(await InformePdf.deTrazado(vacio)), isTrue);
    });
  });

  group('compartir', () {
    test('el informe no es texto: no sale un GPX en su lugar', () async {
      final area = await unArea();

      expect(
        () => Exportador.contenido(area, FormatoEntrega.pdf),
        throwsArgumentError,
      );
    });

    Future<void> abrirHoja(
      WidgetTester tester, {
      required bool conInforme,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: temaSirius,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => elegirFormato(context, conInforme: conInforme),
                child: const Text('compartir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('compartir'));
      await tester.pumpAndSettle();
    }

    testWidgets('un levantamiento ofrece el informe PDF', (tester) async {
      await abrirHoja(tester, conInforme: true);

      expect(find.text('Informe PDF'), findsOneWidget);
      expect(find.text('KML'), findsOneWidget);
    });

    testWidgets('una lista de puntos sueltos no', (tester) async {
      await abrirHoja(tester, conInforme: false);

      expect(find.text('Informe PDF'), findsNothing);
      expect(find.text('KML'), findsOneWidget);
    });

    testWidgets('la hoja no se desborda con la letra agrandada', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await abrirHoja(tester, conInforme: true);

      expect(tester.takeException(), isNull);
    });
  });
}
