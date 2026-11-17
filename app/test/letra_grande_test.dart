import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/camiones/camiones_page.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/db/enums.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/data/waypoints_repository.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/red.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/ubicacion_provider.dart';
import 'package:geomaps/state/zona_guaicaramo.dart';
import 'package:geomaps/ui/aviso_ubicacion_page.dart';
import 'package:geomaps/ui/capa_ruta.dart';
import 'package:geomaps/ui/capa_vias.dart';
import 'package:geomaps/ui/capas_panel.dart';
import 'package:geomaps/ui/home_page.dart';
import 'package:geomaps/ui/login_page.dart';
import 'package:geomaps/ui/mapa_page.dart' show CapaBase;
import 'package:geomaps/ui/medicion.dart';
import 'package:geomaps/ui/panel_grabacion.dart';
import 'package:geomaps/ui/proyectos_page.dart';
import 'package:geomaps/ui/sincronizacion_page.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:geomaps/ui/trazado_page.dart';
import 'package:geomaps/ui/waypoint_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

/// Un grabador con el estado puesto a mano: la franja solo lo mira.
class _GrabadorFijo extends Grabador {
  _GrabadorFijo(TrazadosRepository repo, EstadoGrabacion estado)
    : super(repo, null, () {}) {
    state = estado;
  }
}

/// La letra de toda la app.
///
/// La mayoria de quienes usan GeoMaps en campo son personas mayores que no ven
/// bien. Dos cosas se cuidan aca:
///
/// - **El piso.** Ningun estilo del tema baja de 15, y los botones miden lo
///   que mide un dedo con guante.
/// - **Que no se rompa.** Esa gente lleva ademas la letra del telefono
///   agrandada. Cada pantalla se abre en un telefono angosto (360 de ancho)
///   con la letra al 130% y con el tema de verdad, y no puede desbordarse:
///   un renglon que se sale de su tarjeta es un dato que no se lee.
///
/// El mapa no esta aca porque no se puede armar sin GPS ni teselas; sus
/// tarjetas y franjas si, una por una.
void main() {
  late AppDatabase db;

  // Las consultas en vivo se cierran en el acto y no con un temporizador: el
  // reloj de una prueba de pantalla es de mentira, y con el temporizador la
  // base no terminaba nunca de cerrarse.
  setUp(
    () => db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    ),
  );
  tearDown(() => db.close());

  const usuario = 'USR-1';
  final sesion = Sesion(
    authUid: 'uid-1',
    codigoUsuario: usuario,
    // Un nombre largo a proposito: es el que rompe los encabezados.
    nombre: 'Maria Fernanda Rodriguez Castellanos',
    correo: 'maria.fernanda.rodriguez@example.com',
    rol: 'Usuario',
    venceEn: DateTime.now().add(const Duration(days: 5)),
    perfiles: const {Perfil.plantacion, Perfil.camiones},
  );

  final informes = <String>[];
  setUp(informes.clear);

  /// Falla si al dibujar algo se salio de su lugar, y dice que fue: el error
  /// de Flutter trae el widget y el renglon del codigo donde esta.
  void sinDesbordes(WidgetTester tester) {
    final error = tester.takeException();
    if (error == null) return;
    fail(informes.isEmpty ? '$error' : informes.join('\n'));
  }

  /// Corre [dibujar] anotando el informe completo de cada error de dibujo:
  /// la excepcion sola dice "se desbordo 40 pixeles" y no dice que.
  Future<void> anotando(Future<void> Function() dibujar) async {
    final previo = FlutterError.onError;
    FlutterError.onError = (detalle) {
      informes.add(detalle.toString());
      previo?.call(detalle);
    };
    try {
      await dibujar();
    } finally {
      FlutterError.onError = previo;
    }
  }

  /// Abre [pantalla] como la ve quien no ve bien: telefono angosto, letra al
  /// 130%, el tema de la app. Falla si algo se desborda.
  Future<void> abrir(
    WidgetTester tester,
    Widget pantalla, {
    bool adentro = true,
    List<Override> extra = const [],
  }) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await anotando(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbProvider.overrideWithValue(db),
            apiProvider.overrideWithValue(
              ApiClient(
                cliente: MockClient((_) async => http.Response('{}', 500)),
              ),
            ),
            if (adentro)
              sesionProvider.overrideWith(
                (ref) =>
                    SesionNotifier.conSesion(ref.watch(apiProvider), sesion),
              ),
            redProvider.overrideWith(
              (ref) => Stream.value(const RedState([ConnectivityResult.none])),
            ),
            posicionProvider.overrideWith((ref) => const Stream.empty()),
            estadoGuaicaramoProvider.overrideWithValue(
              const EstadoZona(motivo: MotivoZona.fuera, metrosAlBorde: 12400),
            ),
            ...extra,
          ],
          child: MaterialApp(theme: temaSirius, home: pantalla),
        ),
      );
      // Sin `pumpAndSettle`: varias pantallas tienen un indicador girando
      // mientras cargan, y con el nunca se asientan.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    });
    sinDesbordes(tester);
  }

  /// Una prueba de pantalla. Al terminar desarma el arbol, para que las
  /// consultas en vivo de la base local se suelten antes de cerrarla.
  void pantalla(String nombre, Future<void> Function(WidgetTester) cuerpo) {
    testWidgets(nombre, (tester) async {
      await cuerpo(tester);
      await tester.pumpWidget(const SizedBox());
    });
  }

  /// Una tarjeta de las que flotan sobre el mapa, pegada abajo como en el.
  Widget sobreElMapa(Widget tarjeta) => Scaffold(
    backgroundColor: Colors.black,
    body: Align(alignment: Alignment.bottomCenter, child: tarjeta),
  );

  group('el tema', () {
    test('ningun estilo de letra baja de 15', () {
      final t = temaSirius.textTheme;
      final estilos = {
        'titleLarge': t.titleLarge,
        'titleMedium': t.titleMedium,
        'titleSmall': t.titleSmall,
        'bodyLarge': t.bodyLarge,
        'bodyMedium': t.bodyMedium,
        'bodySmall': t.bodySmall,
        'labelLarge': t.labelLarge,
        'labelMedium': t.labelMedium,
        'labelSmall': t.labelSmall,
      };
      for (final e in estilos.entries) {
        expect(
          e.value!.fontSize,
          greaterThanOrEqualTo(Letra.minima),
          reason: e.key,
        );
      }
      // El texto corriente, el que sale sin pedir ningun estilo.
      expect(t.bodyMedium!.fontSize, Letra.cuerpo);
    });

    pantalla('los botones miden al menos 50 de alto', (tester) async {
      await abrir(
        tester,
        Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Guardar')),
              OutlinedButton(onPressed: () {}, child: const Text('Cancelar')),
              ElevatedButton(onPressed: () {}, child: const Text('Seguir')),
            ],
          ),
        ),
      );

      for (final tipo in [FilledButton, OutlinedButton, ElevatedButton]) {
        expect(
          tester.getSize(find.byType(tipo)).height,
          greaterThanOrEqualTo(50),
          reason: '$tipo',
        );
      }
    });

    test('los colores de estado se leen con letra blanca', () {
      // El contraste que pide la norma de accesibilidad para texto normal.
      for (final color in [
        ColoresEstado.bien,
        ColoresEstado.aviso,
        ColoresEstado.mal,
        ColoresEstado.neutro,
      ]) {
        final contraste = 1.05 / (color.computeLuminance() + 0.05);
        expect(contraste, greaterThanOrEqualTo(4.5), reason: '$color');
      }
    });
  });

  group('con la letra del telefono al 130% no se desborda', () {
    pantalla('el inicio, con todas sus tarjetas', (tester) async {
      await abrir(tester, const HomePage());

      expect(find.text('Sincronizar'), findsOneWidget);
      expect(find.text('Camiones'), findsOneWidget);
      // El detalle se lee entero: antes se cortaba con puntos suspensivos.
      expect(find.text('Herramientas de transporte'), findsOneWidget);
    });

    pantalla('la hoja de la cuenta', (tester) async {
      await abrir(tester, const HomePage());
      await tester.tap(find.byTooltip('Mi cuenta'));
      await tester.pumpAndSettle();

      sinDesbordes(tester);
      expect(find.text('Cerrar sesion'), findsOneWidget);
    });

    pantalla('el ingreso', (tester) async {
      await abrir(tester, const LoginPage(), adentro: false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      sinDesbordes(tester);
      expect(find.text('Continuar con Google'), findsOneWidget);
    });

    pantalla('el aviso de ubicacion', (tester) async {
      await abrir(tester, const AvisoUbicacionPage());
    });

    pantalla('sincronizar, con cosas por subir', (tester) async {
      await TrazadosRepository(db).guardarPoligono(
        usuarioCodigo: usuario,
        nombre: 'Lote de prueba',
        vertices: const [
          PuntoGeo(4.40, -72.90),
          PuntoGeo(4.41, -72.90),
          PuntoGeo(4.41, -72.89),
        ],
      );
      await abrir(tester, const SincronizacionPage());

      expect(find.textContaining('sin subir'), findsOneWidget);
    });

    pantalla('los proyectos', (tester) async {
      await abrir(tester, const ProyectosPage());
    });

    pantalla('camiones', (tester) async {
      await abrir(
        tester,
        const CamionesPage(),
        extra: [
          grabadorProvider.overrideWith(
            (ref) =>
                _GrabadorFijo(TrazadosRepository(db), const EstadoGrabacion()),
          ),
        ],
      );
    });

    pantalla('la lista de lo levantado', (tester) async {
      await TrazadosRepository(db).guardarPoligono(
        usuarioCodigo: usuario,
        nombre: 'Lote nuevo junto a la quebrada grande',
        vertices: const [
          PuntoGeo(4.40, -72.90),
          PuntoGeo(4.41, -72.90),
          PuntoGeo(4.41, -72.89),
        ],
      );
      await WaypointsRepository(db).marcar(
        usuarioCodigo: usuario,
        nombre: 'Alcantarilla tapada en la via del bloque 9',
        punto: const PuntoGeo(4.405, -72.895),
        simbolo: SimboloWaypoint.values.last,
        precisionM: 38,
      );

      await abrir(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => elegirLevantado(context),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      sinDesbordes(tester);
      expect(find.textContaining('Lote nuevo'), findsOneWidget);
    });

    pantalla('la ficha de un area y la de un punto', (tester) async {
      final area = await TrazadosRepository(db).guardarPoligono(
        usuarioCodigo: usuario,
        nombre: 'Lote nuevo junto a la quebrada grande',
        vertices: const [
          PuntoGeo(4.40, -72.90),
          PuntoGeo(4.41, -72.90),
          PuntoGeo(4.41, -72.89),
        ],
      );
      final punto = await WaypointsRepository(db).marcar(
        usuarioCodigo: usuario,
        nombre: 'Alcantarilla tapada en la via del bloque 9',
        punto: const PuntoGeo(4.405, -72.895),
        precisionM: 38,
      );

      await abrir(
        tester,
        sobreElMapa(FichaTrazado(trazado: area, onCerrar: () {})),
      );
      await abrir(
        tester,
        sobreElMapa(
          FichaPunto(
            punto: punto,
            desde: const LatLng(4.40, -72.90),
            onCerrar: () {},
            onBorrar: () {},
            onIr: () {},
          ),
        ),
      );
    });

    pantalla('la tarjeta de medir', (tester) async {
      await abrir(
        tester,
        sobreElMapa(
          PanelMedicion(
            puntos: const [
              LatLng(4.40, -72.90),
              LatLng(4.41, -72.90),
              LatLng(4.41, -72.89),
            ],
            onDeshacer: () {},
            onCerrar: () {},
            onGuardar: () {},
          ),
        ),
      );

      expect(find.text('Guardar area'), findsOneWidget);
    });

    pantalla('la tarjeta de la ruta, antes de salir y en camino', (
      tester,
    ) async {
      Via via(TipoVia tipo, List<LatLng> puntos) =>
          Via(tipo: tipo, interna: true, codBp: 'B.1-P.1', puntos: puntos);
      final red = RedVial.construir(
        ViasPredio([
          via(TipoVia.pavimentada, const [
            LatLng(4.4010, -72.9000),
            LatLng(4.4010, -72.8900),
          ]),
          via(TipoVia.balastrada, const [
            LatLng(4.4010, -72.8900),
            LatLng(4.4000, -72.8900),
          ]),
        ]),
      );
      // El destino queda lejos de la via: la tarjeta suma el renglon de "los
      // ultimos metros a pie", que es el mas largo que puede mostrar.
      final ruta = red.ruta(
        desde: const LatLng(4.4010, -72.9000),
        hasta: const LatLng(4.3990, -72.8895),
      )!;

      await abrir(
        tester,
        sobreElMapa(
          PanelRuta(
            ruta: ruta,
            progreso: null,
            calculando: false,
            nombreDestino: 'Acopio 38 · Bloque 9 · Parcela 2',
            onCerrar: () {},
            onGuardar: () {},
            onIniciar: () {},
          ),
        ),
      );
      expect(find.text('Iniciar la ruta'), findsOneWidget);

      await abrir(
        tester,
        sobreElMapa(
          PanelRuta(
            ruta: ruta,
            progreso: null,
            calculando: true,
            enRuta: true,
            nombreDestino: 'Acopio 38 · Bloque 9 · Parcela 2',
            onCerrar: () {},
            onTerminar: () {},
          ),
        ),
      );
      expect(find.text('Terminar la ruta'), findsOneWidget);
    });

    pantalla('la pista de la ruta y la leyenda de vias', (tester) async {
      await abrir(
        tester,
        sobreElMapa(
          const Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PistaRuta(conAcopios: true),
                SizedBox(height: 8),
                LeyendaVias(),
              ],
            ),
          ),
        ),
      );
    });

    pantalla('la franja de grabacion, con el GPS impreciso', (tester) async {
      await abrir(
        tester,
        sobreElMapa(
          const Padding(padding: EdgeInsets.all(12), child: PanelGrabacion()),
        ),
        extra: [
          grabadorProvider.overrideWith(
            (ref) => _GrabadorFijo(
              TrazadosRepository(db),
              const EstadoGrabacion(
                codigo: 't1',
                nombre: 'Recorrido del martes por la tarde',
                metros: 12480,
                precisionUltimaM: 64,
                abiertaSinGrabar: true,
              ),
            ),
          ),
        ],
      );

      expect(find.text('Seguir'), findsOneWidget);
      expect(find.text('Terminar'), findsOneWidget);
    });

    pantalla('el panel de capas', (tester) async {
      await abrir(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: PanelCapas(
              base: CapaBase.satelite,
              onBase: (_) {},
              capas: CapaPredio.values,
              visibles: const {CapaPredio.lotes, CapaPredio.vias},
              onCapa: (_, _) {},
              cuantos: const {
                CapaPredio.lotes: 1240,
                CapaPredio.vias: 318,
                CapaPredio.acopios: 412,
              },
              planos: 2,
              verPlanos: true,
              onPlanos: (_) {},
              onAdministrarPlanos: () {},
              onBuscarAcopio: () {},
            ),
          ),
        ),
      );
    });
  });
}
