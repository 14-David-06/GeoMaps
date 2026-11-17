import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/camiones/vueltas.dart';
import 'package:geomaps/camiones/vueltas_page.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Un grabador con el estado puesto a mano: la pantalla solo lo mira.
class _GrabadorFijo extends Grabador {
  _GrabadorFijo(TrazadosRepository repo, EstadoGrabacion estado)
    : super(repo, null, () {}) {
    state = estado;
  }
}

/// La pantalla que abre el QR.
///
/// Lo que se pidio: que tomar una vuelta **no pida la cedula** -solo la
/// clave-, y que **no se pueda tomar otra** mientras haya una sin finalizar.
/// Y que se lea: quienes la usan son, en su mayoria, personas mayores.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Vuelta vuelta({double? lat, int numero = 23}) => Vuelta.deJson({
    'id': 'v$numero',
    'jornada': '2026-11-09',
    'consecutivo': numero,
    'tipo_fruto': 'comercial',
    'reportado_en': '2026-11-09T20:40:00Z',
    'origen': {
      'codigo': 'B.3-P.4 · 11A',
      'bloque': 'B.3',
      'num': '11A',
      'lat': lat,
      'lon': lat == null ? null : -72.98,
    },
    'destino': {'codigo': 'B.3-P.1 · 5', 'bloque': 'B.3', 'num': '5'},
    'vagon': '133',
  });

  Future<void> abrir(
    WidgetTester tester, {
    Conductor? conductor = const Conductor(nombre: 'Ana Gomez'),
    double? lat = 4.49,
    ViajeAbierto? abierto,
    EstadoGrabacion grabando = const EstadoGrabacion(),
    http.Response Function(http.Request pedido)? servidor,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        // Una llave nueva cada vez: abrir dos veces en una misma prueba tiene
        // que armar la pantalla de cero, con sus propios datos.
        key: UniqueKey(),
        overrides: [
          dbProvider.overrideWithValue(db),
          apiProvider.overrideWithValue(
            ApiClient(
              cliente: MockClient(
                (pedido) async =>
                    servidor?.call(pedido) ?? http.Response('{}', 500),
              ),
            ),
          ),
          grabadorProvider.overrideWith(
            (ref) => _GrabadorFijo(TrazadosRepository(db), grabando),
          ),
          vueltasProvider.overrideWith(
            (ref) async => ListaVueltas(
              vueltas: [vuelta(lat: lat)],
              conductor: conductor,
              viajeAbierto: abierto,
              control: true,
            ),
          ),
        ],
        child: MaterialApp(theme: temaSirius, home: const VueltasPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  final tomar = find.widgetWithText(FilledButton, 'Tomar esta vuelta');

  /// La tarjeta es alta y la lista arma solo lo que se ve: primero se baja
  /// hasta el boton, y recien con la pantalla ya acomodada se lo toca.
  Future<void> tocarTomar(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      tomar,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(tomar);
    await tester.pumpAndSettle();
  }

  testWidgets('no pide la cedula: a una cuenta con clave, solo la clave', (
    tester,
  ) async {
    await abrir(tester);

    expect(find.textContaining('quedan a nombre de Ana Gomez'), findsOneWidget);
    expect(find.textContaining('cedula'), findsNothing);
    await tocarTomar(tester);

    expect(find.text('Tomar la vuelta #23'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Tu clave de GeoMaps'), findsOneWidget);
    expect(find.textContaining('edula'), findsNothing);
    // La ayuda se lee entera: antes se cortaba con puntos suspensivos.
    expect(find.text('Es la misma con la que entras a la app.'), findsOneWidget);
  });

  testWidgets('una cuenta de Google confirma sin escribir nada', (
    tester,
  ) async {
    await abrir(
      tester,
      conductor: const Conductor(nombre: 'Carla Diaz', pideClave: false),
    );
    await tocarTomar(tester);

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('a nombre de Carla Diaz'), findsWidgets);
    expect(
      find.widgetWithText(FilledButton, 'Tomar la vuelta'),
      findsOneWidget,
    );
  });

  testWidgets('sin escribir la clave no se manda nada', (tester) async {
    var llamadas = 0;
    await abrir(
      tester,
      servidor: (_) {
        llamadas++;
        return http.Response('{}', 200);
      },
    );
    await tocarTomar(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Tomar la vuelta'));
    await tester.pump();

    expect(find.text('Escribe tu clave de GeoMaps.'), findsOneWidget);
    expect(llamadas, 0);
  });

  testWidgets('dice el sitio con todas las letras y explica la regla', (
    tester,
  ) async {
    await abrir(tester);

    expect(find.text('Acopio 11A'), findsOneWidget);
    expect(find.text('Bloque 3 · Parcela 4'), findsOneWidget);
    expect(
      find.text('Dejar el vagon 133 en Bloque 3 · Parcela 1 · Acopio 5'),
      findsOneWidget,
    );
    expect(find.textContaining('B.3-P.4'), findsNothing);

    await tocarTomar(tester);
    expect(
      find.textContaining('tienes que llegar a los vagones y volver aqui'),
      findsOneWidget,
    );
  });

  testWidgets('una vuelta sin coordenada tambien se deja tomar', (
    tester,
  ) async {
    await abrir(tester, lat: null);

    expect(find.textContaining('Sin coordenada'), findsOneWidget);
    await tocarTomar(tester);

    expect(find.text('Tomar la vuelta #23'), findsOneWidget);
    expect(
      find.textContaining('Este acopio no tiene coordenada'),
      findsOneWidget,
    );
  });

  testWidgets('con una vuelta sin finalizar en el servidor no se toma otra', (
    tester,
  ) async {
    await abrir(
      tester,
      abierto: ViajeAbierto(
        codigo: 'viaje-0001',
        vueltaId: 'v7',
        vuelta: vuelta(numero: 7, lat: 4.47),
      ),
    );

    expect(find.text('Tienes Vuelta #7 sin finalizar'), findsOneWidget);
    expect(
      find.textContaining('No puedes tomar otra hasta finalizarla'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(FilledButton, 'Continuar esa vuelta'),
      findsOneWidget,
    );
    // La lista se ve, pero el boton esta apagado.
    await tester.scrollUntilVisible(
      tomar,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilledButton>(tomar).onPressed, isNull);
  });

  testWidgets('con una vuelta abierta en este telefono tampoco', (
    tester,
  ) async {
    await abrir(
      tester,
      grabando: const EstadoGrabacion(
        codigo: 't1',
        nombre: 'Vuelta #7 · B.3 · 2',
        propiedades: {'vuelta_id': 'v7'},
        // La app se cerro a mitad del viaje y todavia no se retomo: antes
        // ese caso dejaba tomar una segunda vuelta.
        abiertaSinGrabar: true,
      ),
    );

    expect(find.text('Tienes una vuelta sin finalizar'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Ir a mi vuelta'), findsOneWidget);
    await tester.scrollUntilVisible(
      tomar,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilledButton>(tomar).onPressed, isNull);
  });

  testWidgets('si el servidor dice que ya tiene una, el dialogo lo muestra', (
    tester,
  ) async {
    await abrir(
      tester,
      conductor: const Conductor(nombre: 'Carla Diaz', pideClave: false),
      servidor: (pedido) => http.Response(
        jsonEncode({
          'detail': 'Tienes Vuelta #7 sin finalizar. Finalizala para tomar '
              'otra.',
        }),
        423,
      ),
    );
    await tocarTomar(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Tomar la vuelta'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Tienes Vuelta #7 sin finalizar'), findsOneWidget);
  });

  testWidgets('un servidor que todavia exige la cedula lo dice claro', (
    tester,
  ) async {
    await abrir(
      tester,
      conductor: const Conductor(nombre: 'Carla Diaz', pideClave: false),
      servidor: (pedido) => http.Response(
        jsonEncode({
          'detail': [
            {
              'type': 'missing',
              'loc': ['body', 'cedula'],
              'msg': 'Field required',
            },
          ],
        }),
        422,
      ),
    );
    await tocarTomar(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Tomar la vuelta'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('todavia no esta actualizado'),
      findsOneWidget,
    );
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

    await abrir(
      tester,
      abierto: ViajeAbierto(
        codigo: 'viaje-0001',
        vueltaId: 'v7',
        vuelta: vuelta(numero: 7, lat: 4.47),
      ),
    );
    expect(tester.takeException(), isNull);

    await abrir(tester);
    await tocarTomar(tester);
    expect(find.text('Tu clave de GeoMaps'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
