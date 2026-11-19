import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/state/gps.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/red.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/zona_guaicaramo.dart';
import 'package:geomaps/ui/capa_ruta.dart';
import 'package:geomaps/ui/mapa/barra_gps.dart';
import 'package:geomaps/ui/mapa/botones.dart';
import 'package:geomaps/ui/mapa/punto_propio.dart';
import 'package:geomaps/ui/mapa_page.dart';
import 'package:geomaps/ui/medicion.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La ubicacion del telefono, de mentira: da permiso y entrega las posiciones
/// que la prueba le pone.
class _UbicacionFalsa extends GeolocatorPlatform {
  final fixes = StreamController<Position>.broadcast();

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => null;

  @override
  Stream<ServiceStatus> getServiceStatusStream() => const Stream.empty();

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      fixes.stream;
}

/// Un grabador con el estado puesto a mano, que no toca el GPS.
class _GrabadorFijo extends Grabador {
  _GrabadorFijo(TrazadosRepository repo) : super(repo, null, () {});
}

/// La pantalla del mapa entera, armada como en el telefono.
///
/// Las piezas del mapa tienen cada una su prueba; aca se cuida que esten bien
/// enchufadas entre si: que la posicion llegue a la barra y a la flecha, que
/// la ruta se dibuje y se suelte, que las herramientas hagan lo que dicen y
/// que al salir no quede nada colgado.
///
/// La ubicacion y la brujula son de mentira, y el satelite no baja: en una
/// prueba no hay red, y el mapa tiene que andar igual.
///
/// El GPS de la app es uno solo para todas las pantallas y se acuerda de la
/// ultima posicion: quien abre el mapa ve de una donde esta. Aca se le hace
/// olvidar antes de cada prueba, para que ninguna arranque parada donde
/// termino la anterior.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const a = LatLng(4.4010, -72.9000);
  const c = LatLng(4.4010, -72.8900);
  const d = LatLng(4.4000, -72.9000);
  const f = LatLng(4.4000, -72.8900);
  const archivo = 'escalera.json';

  Via via(TipoVia tipo, List<LatLng> puntos) =>
      Via(tipo: tipo, interna: true, codBp: 'B.1-P.1', puntos: puntos);

  // La escalera de `ruteo_test`: dos vias de 1 km unidas por las puntas.
  final vias = ViasPredio([
    via(TipoVia.pavimentada, [a, c]),
    via(TipoVia.balastrada, [d, f]),
    via(TipoVia.balastrada, [a, d]),
    via(TipoVia.balastrada, [c, f]),
  ]);
  final red = RedVial.construir(vias);

  Position en(LatLng p, {double precision = 5}) => Position(
    latitude: p.latitude,
    longitude: p.longitude,
    timestamp: DateTime.now(),
    accuracy: precision,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );

  late AppDatabase db;
  late _UbicacionFalsa ubicacion;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    SharedPreferences.setMockInitialValues({});
    ubicacion = _UbicacionFalsa();
    GeolocatorPlatform.instance = ubicacion;
    Gps.instancia.olvidar();
    // Un telefono sin magnetometro que conteste: la brujula no dice nada.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('hemanthraj/flutter_compass'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
  });
  tearDown(() => db.close());

  /// Deja pasar el tiempo de a poco: el mapa tiene un indicador girando
  /// mientras cargan las imagenes, y con `pumpAndSettle` no se asienta nunca.
  Future<void> esperar(WidgetTester tester, [int veces = 6]) async {
    for (var i = 0; i < veces; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> abrir(
    WidgetTester tester,
    Widget mapa, {
    Future<RedVial> Function()? alArmarLaRed,
    double letra = 1,
  }) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = letra;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final api = ApiClient(
      cliente: MockClient((_) async => http.Response('{}', 500)),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          apiProvider.overrideWithValue(api),
          sesionProvider.overrideWith(
            (ref) => SesionNotifier.conSesion(
              api,
              Sesion(
                authUid: 'uid-1',
                codigoUsuario: 'USR-1',
                nombre: 'Ana Gomez',
                correo: 'ana@example.com',
                rol: 'Usuario',
                venceEn: DateTime.now().add(const Duration(days: 20)),
              ),
            ),
          ),
          redProvider.overrideWith(
            (ref) => Stream.value(const RedState([ConnectivityResult.none])),
          ),
          grabadorProvider.overrideWith(
            (ref) => _GrabadorFijo(TrazadosRepository(db)),
          ),
          viasPredioProvider.overrideWith((ref, _) async => vias),
          redVialProvider.overrideWith(
            (ref, _) => alArmarLaRed?.call() ?? Future.value(red),
          ),
        ],
        child: MaterialApp(theme: temaSirius, home: mapa),
      ),
    );
    await esperar(tester);
  }

  /// Llega una posicion del GPS.
  Future<void> fix(
    WidgetTester tester,
    LatLng p, {
    double precision = 5,
  }) async {
    ubicacion.fixes.add(en(p, precision: precision));
    await esperar(tester);
  }

  /// Los botones del costado tienen que quedar arriba de la tarjeta de la
  /// ruta, no debajo de ella: tapados no se pueden tocar.
  void botonesALaVista(WidgetTester tester) {
    final botones = tester.getRect(find.byType(BotonesDelMapa));
    final tarjeta = tester.getRect(find.byType(PanelRuta));
    expect(
      botones.bottom,
      lessThanOrEqualTo(tarjeta.top),
      reason: 'los botones ($botones) quedan debajo de la tarjeta ($tarjeta)',
    );
    expect(botones.top, greaterThan(0), reason: 'se salen por arriba');
  }

  /// Una prueba de pantalla. Al terminar desarma el arbol: es lo que suelta
  /// la ubicacion y las consultas en vivo, y lo que prueba que salir del mapa
  /// no deja nada colgado.
  void pantalla(String nombre, Future<void> Function(WidgetTester) cuerpo) {
    testWidgets(nombre, (tester) async {
      await cuerpo(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  }

  pantalla('sin GPS abre igual, lo dice, y se puede cerrar', (tester) async {
    await abrir(tester, const MapaPage());

    expect(find.textContaining('Buscando senal GPS'), findsOneWidget);
    expect(find.byType(PuntoPropio), findsNothing);
    // Sin posicion no hay donde centrar.
    final centrar = tester.widget<FloatingActionButton>(
      find.widgetWithIcon(FloatingActionButton, Icons.navigation),
    );
    expect(centrar.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  pantalla('con el primer fix muestra donde estoy y con que precision', (
    tester,
  ) async {
    await abrir(tester, const MapaPage());

    await fix(tester, a, precision: 4);

    expect(find.textContaining('+/- 4 m'), findsOneWidget);
    expect(find.byType(PuntoPropio), findsOneWidget);
    final barra = tester.widget<BarraGps>(find.byType(BarraGps));
    expect(barra.posicion!.latitude, a.latitude);

    // El boton de centrar alterna entre el modo navegador y el norte arriba.
    expect(find.byTooltip('Norte arriba'), findsOneWidget);
    await tester.tap(find.byTooltip('Norte arriba'));
    await esperar(tester);
    expect(find.byTooltip('Girar hacia donde voy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  pantalla('las herramientas: medir entra y sale del modo de medir', (
    tester,
  ) async {
    await abrir(tester, const MapaPage());

    await tester.tap(find.byTooltip('Herramientas'));
    await esperar(tester);
    // El mapa a secas no tiene vias: no hay rutas que guardar.
    expect(find.text('Rutas guardadas'), findsNothing);
    await tester.ensureVisible(find.text('Medir distancia o area'));
    await tester.tap(find.text('Medir distancia o area'));
    await esperar(tester);

    expect(find.byType(PanelMedicion), findsOneWidget);

    // Atras, midiendo, deja de medir: no saca del mapa.
    await tester.binding.handlePopRoute();
    await esperar(tester);
    expect(find.byType(PanelMedicion), findsNothing);
    expect(find.byType(MapaPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  pantalla('abierto hacia un destino, traza la ruta con el primer fix', (
    tester,
  ) async {
    await abrir(
      tester,
      const MapaPage(
        archivoVias: archivo,
        destinoInicial: f,
        nombreDestinoInicial: 'Acopio 38',
      ),
    );
    // Todavia no hay desde donde trazarla.
    expect(find.byType(PanelRuta), findsNothing);

    await fix(tester, a);

    expect(find.byType(PanelRuta), findsOneWidget);
    expect(find.textContaining('Acopio 38'), findsWidgets);
    expect(find.text('Iniciar la ruta'), findsOneWidget);
    expect(find.byType(MarcadorDestino), findsOneWidget);
    botonesALaVista(tester);

    // Al llegar la suelta y lo dice.
    await fix(tester, f);

    expect(find.byType(PanelRuta), findsNothing);
    expect(find.byType(MarcadorDestino), findsNothing);
    expect(find.text('Llegaste: Acopio 38.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  pantalla('lo que va arriba puede mandar el mapa a otro destino', (
    tester,
  ) async {
    // Como el viaje de un camion: del acopio al patio sin salir del mapa.
    await abrir(
      tester,
      MapaPage(
        archivoVias: archivo,
        destinoInicial: f,
        nombreDestinoInicial: 'Acopio 38',
        panelSuperior: Builder(
          builder: (context) => FilledButton(
            onPressed: () => MapaPage.irA(context, d, nombre: 'El patio'),
            child: const Text('Ir al patio'),
          ),
        ),
      ),
    );
    await fix(tester, c);
    expect(find.textContaining('Acopio 38'), findsWidgets);

    await tester.tap(find.text('Ir al patio'));
    await esperar(tester);

    expect(find.byType(PanelRuta), findsOneWidget);
    expect(find.textContaining('El patio'), findsWidgets);
    expect(find.textContaining('Acopio 38'), findsNothing);

    // Cerrar la tarjeta suelta la ruta.
    await tester.tap(find.byTooltip('Quitar la ruta'));
    await esperar(tester);
    expect(find.byType(PanelRuta), findsNothing);
    expect(tester.takeException(), isNull);
  });

  pantalla('con la letra del telefono al 130% el mapa entero no se desborda', (
    tester,
  ) async {
    // Las tarjetas tienen cada una su prueba de letra grande; aca van todas
    // juntas sobre el mapa: la barra, la franja de arriba, los botones y la
    // tarjeta de la ruta, en un telefono angosto.
    await abrir(
      tester,
      const MapaPage(
        archivoVias: archivo,
        destinoInicial: f,
        nombreDestinoInicial: 'Acopio 38 - Bloque 9 - Parcela 2',
      ),
      letra: 1.3,
    );
    expect(tester.takeException(), isNull);

    await fix(tester, a, precision: 38);
    expect(find.byType(PanelRuta), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Con la letra agrandada la tarjeta mide casi el doble: los botones
    // suben con ella en vez de quedar tapados.
    botonesALaVista(tester);
    await tester.tap(find.byTooltip('Herramientas'));
    await esperar(tester);
    expect(find.text('Rutas guardadas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  pantalla('salir con una ruta a medio calcular no rompe nada', (tester) async {
    // La primera ruta arma el grafo de las vias, que tarda.
    final grafo = Completer<RedVial>();
    await abrir(
      tester,
      const MapaPage(archivoVias: archivo, destinoInicial: f),
      alArmarLaRed: () => grafo.future,
    );
    await fix(tester, a);
    expect(find.byType(CalculandoRuta), findsOneWidget);

    // El mapa se cierra antes de que termine, y despues llega la respuesta.
    await tester.pumpWidget(const SizedBox());
    grafo.complete(red);
    await esperar(tester);
  });
}
