import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/camiones/camiones_page.dart';
import 'package:geomaps/camiones/panel_viaje.dart';
import 'package:geomaps/camiones/vueltas.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Un grabador que no toca el GPS: guarda lo que le piden y nada mas.
class _GrabadorFalso extends Grabador {
  _GrabadorFalso(TrazadosRepository repo, EstadoGrabacion estado)
    : super(repo, null, () {}) {
    state = estado;
  }

  /// Con que se cerro el viaje. Nulo mientras siga abierto.
  Map<String, Object?>? cierre;
  bool descartado = false;

  @override
  Future<void> terminar({Map<String, Object?> propiedades = const {}}) async {
    cierre = propiedades;
    state = const EstadoGrabacion();
  }

  @override
  Future<void> descartar() async {
    descartado = true;
    state = const EstadoGrabacion();
  }
}

/// El viaje de una vuelta en pantalla: que diga en que paso va, y que solo se
/// pueda finalizar cuando el camion fue hasta los vagones y volvio.
void main() {
  late AppDatabase db;
  late _GrabadorFalso grabador;
  late List<http.Request> pedidos;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    pedidos = [];
  });
  tearDown(() => db.close());

  const salida = {'en': '2026-11-13T15:00:00Z', 'lat': 4.40, 'lon': -72.90};
  const llegada = {'en': '2026-11-13T15:25:00Z', 'lat': 4.45, 'lon': -72.94};
  const regreso = {'en': '2026-11-13T15:55:00Z', 'lat': 4.40, 'lon': -72.90};

  EstadoGrabacion viaje({
    bool llego = false,
    bool volvio = false,
    bool conPunto = true,
    bool cortado = false,
  }) => EstadoGrabacion(
    codigo: 't1',
    nombre: 'Vuelta #23 · B.3 · 11A',
    metros: 7400,
    destinoNombre: 'Bloque 3 · Parcela 4 · Acopio 11A',
    destino: conPunto ? const PuntoGeo(4.45, -72.94) : null,
    abiertaSinGrabar: cortado,
    propiedades: {
      'vuelta_id': 'v23',
      'viaje': 'viaje-0001',
      if (conPunto) 'destino': [-72.94, 4.45],
      'salida': salida,
      if (llego) 'llegada': llegada,
      if (volvio) 'regreso': regreso,
      'entrega': [-72.95, 4.44],
      'entrega_nombre': 'Bloque 3 · Parcela 1 · Acopio 5',
      'vagon': '133',
    },
  );

  Future<void> armar(
    WidgetTester tester,
    EstadoGrabacion estado, {
    required Widget pantalla,
    ({bool control, ViajeAbierto? viaje})? servidor,
  }) async {
    grabador = _GrabadorFalso(TrazadosRepository(db), estado);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          dbProvider.overrideWithValue(db),
          apiProvider.overrideWithValue(
            ApiClient(
              cliente: MockClient((pedido) async {
                pedidos.add(pedido);
                return http.Response('{"estado":"finalizada","abierto":false}', 200);
              }),
            ),
          ),
          grabadorProvider.overrideWith((ref) => grabador),
          miViajeProvider.overrideWith((ref) async => servidor),
        ],
        child: MaterialApp(theme: temaSirius, home: pantalla),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> panel(WidgetTester tester, EstadoGrabacion estado) => armar(
    tester,
    estado,
    pantalla: const Scaffold(
      body: SafeArea(
        child: Padding(padding: EdgeInsets.all(12), child: PanelViaje()),
      ),
    ),
  );

  final finalizar = find.widgetWithText(FilledButton, 'Finalizar la vuelta');

  group('el panel dice en que paso va', () {
    testWidgets('de ida: ir por los vagones, sin boton de finalizar', (
      tester,
    ) async {
      await panel(tester, viaje());

      expect(find.text('1 de 3 · Ve por los vagones'), findsOneWidget);
      expect(find.text('Ir a los vagones'), findsOneWidget);
      expect(find.text('Dejar el vagon 133'), findsOneWidget);
      expect(finalizar, findsNothing);
      // Antes de llegar todavia se puede devolver.
      expect(find.text('Opciones'), findsOneWidget);
    });

    testWidgets('ya llego: le falta volver, y ya no se devuelve', (
      tester,
    ) async {
      await panel(tester, viaje(llego: true));

      expect(find.text('2 de 3 · Vuelve al punto de salida'), findsOneWidget);
      expect(find.text('Camino de vuelta'), findsOneWidget);
      expect(find.text('Ir a los vagones'), findsNothing);
      expect(finalizar, findsNothing);
      expect(find.text('Opciones'), findsNothing);
    });

    testWidgets('fue y volvio: recien ahi aparece finalizar', (tester) async {
      await panel(tester, viaje(llego: true, volvio: true));

      expect(find.text('3 de 3 · Ya puedes finalizar'), findsOneWidget);
      expect(finalizar, findsOneWidget);
      expect(find.text('Camino de vuelta'), findsNothing);
    });

    testWidgets('un acopio sin coordenada deja marcar la llegada', (
      tester,
    ) async {
      await panel(tester, viaje(conPunto: false));

      expect(find.textContaining('no tiene coordenada'), findsOneWidget);
      await tester.tap(find.text('Ya llegue a los vagones'));
      await tester.pumpAndSettle();

      // En la prueba no hay GPS: sin el no se puede marcar, y lo dice.
      expect(find.text('Todavia no'), findsOneWidget);
      expect(find.textContaining('Sin GPS'), findsOneWidget);
      expect(grabador.state.propiedades.containsKey('llegada'), isFalse);
    });

    testWidgets('si la app se habia cerrado, ofrece seguir la vuelta', (
      tester,
    ) async {
      await panel(tester, viaje(cortado: true));
      expect(
        find.widgetWithText(FilledButton, 'Seguir la vuelta'),
        findsOneWidget,
      );
    });

    testWidgets('un recorrido cualquiera no muestra pasos de vuelta', (
      tester,
    ) async {
      await panel(
        tester,
        const EstadoGrabacion(codigo: 't9', nombre: 'Recorrido 13/11'),
      );
      expect(find.textContaining('de 3'), findsNothing);
      expect(finalizar, findsNothing);
    });
  });

  group('finalizar', () {
    testWidgets('habiendo ido y vuelto, se finaliza y se avisa al servidor', (
      tester,
    ) async {
      await panel(tester, viaje(llego: true, volvio: true));

      await tester.tap(finalizar);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Finalizar'));
      await tester.pumpAndSettle();
      // La calificacion de la ruta no es obligatoria.
      await tester.tap(find.text('Omitir'));
      await tester.pumpAndSettle();

      expect(grabador.cierre, isNotNull);
      expect((grabador.cierre!['fin'] as Map)['en'], isNotNull);

      final aviso = pedidos.single;
      expect(aviso.url.path, '/v1/camiones/viajes/viaje-0001/seguimiento');
      final cuerpo = jsonDecode(aviso.body) as Map<String, dynamic>;
      expect(cuerpo.keys, containsAll(['salida', 'llegada', 'regreso', 'fin']));
      expect(cuerpo['trazado'], 't1');
      expect(cuerpo['recorrido_m'], 7400);
    });

    testWidgets('arrepentirse en la confirmacion no cierra nada', (
      tester,
    ) async {
      await panel(tester, viaje(llego: true, volvio: true));

      await tester.tap(finalizar);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Todavia no'));
      await tester.pumpAndSettle();

      expect(grabador.cierre, isNull);
      expect(pedidos, isEmpty);
    });
  });

  group('la entrada de camiones', () {
    Future<void> entrada(
      WidgetTester tester,
      EstadoGrabacion estado, {
      ({bool control, ViajeAbierto? viaje})? servidor,
    }) => armar(
      tester,
      estado,
      pantalla: const CamionesPage(),
      servidor: servidor,
    );

    final escanear = find.widgetWithText(FilledButton, 'Escanear QR de vueltas');
    final boton = find.widgetWithText(OutlinedButton, 'Finalizar la vuelta');

    testWidgets('sin viaje, se escanea', (tester) async {
      await entrada(tester, const EstadoGrabacion());
      expect(tester.widget<FilledButton>(escanear).onPressed, isNotNull);
    });

    testWidgets('con una vuelta sin finalizar no se escanea otra', (
      tester,
    ) async {
      await entrada(tester, viaje());

      expect(tester.widget<FilledButton>(escanear).onPressed, isNull);
      expect(find.text('Paso 1 de 3: ve por los vagones.'), findsOneWidget);
      expect(
        find.text('Finaliza la vuelta que tienes para poder tomar otra.'),
        findsOneWidget,
      );
    });

    testWidgets('tampoco si la app se cerro a mitad de la vuelta', (
      tester,
    ) async {
      // Era el hueco: al reabrir la app el viaje quedaba "sin grabar" y el
      // boton de escanear se prendia.
      await entrada(tester, viaje(cortado: true));
      expect(tester.widget<FilledButton>(escanear).onPressed, isNull);
      expect(find.text('Seguir el viaje'), findsOneWidget);
    });

    testWidgets('finalizar sin haber llegado no cierra: dice que falta', (
      tester,
    ) async {
      await entrada(tester, viaje());

      await tester.tap(boton);
      await tester.pumpAndSettle();

      expect(find.text('Todavia no llegas a los vagones'), findsOneWidget);
      expect(find.text('No la voy a recoger'), findsOneWidget);
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();

      expect(grabador.cierre, isNull);
      expect(grabador.state.codigo, 't1');
      expect(pedidos, isEmpty);
    });

    testWidgets('finalizar sin haber vuelto tampoco, y ya no se devuelve', (
      tester,
    ) async {
      await entrada(tester, viaje(llego: true));

      await tester.tap(boton);
      await tester.pumpAndSettle();

      expect(find.text('Te falta volver'), findsOneWidget);
      expect(find.text('No la voy a recoger'), findsNothing);
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(grabador.cierre, isNull);
    });

    testWidgets('devolverla antes de llegar la suelta y descarta el viaje', (
      tester,
    ) async {
      await entrada(tester, viaje());

      await tester.tap(boton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('No la voy a recoger'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Devolverla'));
      await tester.pumpAndSettle();

      expect(pedidos.single.url.path, '/v1/camiones/vueltas/v23/soltar');
      expect(grabador.descartado, isTrue);
    });

    testWidgets('si despacho la cerro, se cierra el viaje del telefono', (
      tester,
    ) async {
      await entrada(tester, viaje(), servidor: (control: true, viaje: null));

      expect(find.textContaining('Despacho cerro esta vuelta'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Cerrar el viaje'));
      await tester.pumpAndSettle();

      expect(grabador.cierre, {'cierre': 'despacho'});
    });

    testWidgets('si el servidor no lleva el control, no se le cree', (
      tester,
    ) async {
      await entrada(tester, viaje(), servidor: (control: false, viaje: null));
      expect(find.textContaining('Despacho cerro'), findsNothing);
      expect(boton, findsOneWidget);
    });

    testWidgets('sin respuesta del servidor el viaje sigue como estaba', (
      tester,
    ) async {
      await entrada(tester, viaje());
      expect(find.textContaining('Despacho cerro'), findsNothing);
    });

    testWidgets('si la abierta en el servidor es esta misma, todo sigue', (
      tester,
    ) async {
      await entrada(
        tester,
        viaje(),
        servidor: (
          control: true,
          viaje: const ViajeAbierto(codigo: 'viaje-0001', vueltaId: 'v23'),
        ),
      );
      expect(find.textContaining('Despacho cerro'), findsNothing);
    });
  });

  testWidgets('con la letra del telefono agrandada nada se desborda', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    for (final estado in [
      viaje(),
      viaje(conPunto: false),
      viaje(llego: true),
      viaje(llego: true, volvio: true),
      viaje(cortado: true),
    ]) {
      await panel(tester, estado);
      expect(tester.takeException(), isNull);
      await armar(tester, estado, pantalla: const CamionesPage());
      expect(tester.takeException(), isNull);
    }
  });
}
