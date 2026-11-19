import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geomaps/camiones/camiones_page.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/db/enums.dart';
import 'package:geomaps/data/proyectos_repository.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/data/waypoints_repository.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/red.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/ubicacion_provider.dart';
import 'package:geomaps/state/zona_guaicaramo.dart';
import 'package:geomaps/ui/aviso_ubicacion_page.dart';
import 'package:geomaps/ui/boton_voz.dart';
import 'package:geomaps/ui/capa_ruta.dart';
import 'package:geomaps/ui/capa_vias.dart';
import 'package:geomaps/ui/capas_panel.dart';
import 'package:geomaps/ui/home_page.dart';
import 'package:geomaps/ui/login_page.dart';
import 'package:geomaps/ui/mapa/barra_gps.dart';
import 'package:geomaps/ui/mapa/botones.dart';
import 'package:geomaps/ui/mapa/capa_base.dart';
import 'package:geomaps/ui/mapa/cuenta.dart';
import 'package:geomaps/ui/mapa/herramientas.dart';
import 'package:geomaps/ui/mapa/seguidor.dart';
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
/// Del mapa estan aca sus tarjetas y franjas, una por una. El mapa entero,
/// con todas encima, se abre en `mapa_page_test.dart`.
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
    Sesion? quien,
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
                (ref) => SesionNotifier.conSesion(
                  ref.watch(apiProvider),
                  quien ?? sesion,
                ),
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

    pantalla('el inicio con la sesion vencida, y volver a entrar', (
      tester,
    ) async {
      final vencida = Sesion(
        authUid: 'uid-1',
        codigoUsuario: usuario,
        nombre: 'Maria Fernanda Rodriguez Castellanos',
        correo: 'maria.fernanda.rodriguez@example.com',
        rol: 'Usuario',
        venceEn: DateTime.now().subtract(const Duration(days: 2)),
        perfiles: const {Perfil.plantacion, Perfil.camiones},
      );
      await abrir(tester, const HomePage(), quien: vencida);
      expect(find.text('Tu sesion vencio'), findsOneWidget);

      await abrir(tester, const LoginPage(reingreso: true), quien: vencida);
      expect(find.text('Entrar de nuevo'), findsOneWidget);
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

    pantalla('los proyectos, con uno en uso', (tester) async {
      final repo = ProyectosRepository(db);
      await repo.crear(
        duenoAuthUid: 'uid-1',
        nombre: 'Finca La Esperanza del Rio Upia',
        cliente: 'Palmas del Upia S.A.S.',
        municipio: 'Barranca de Upia',
      );
      await repo.crear(duenoAuthUid: 'uid-1', nombre: 'Visita del martes');
      await abrir(tester, const ProyectosPage());
      // Arriba de todo, la opcion de no usar ninguno, que es la de fabrica.
      expect(find.text('En uso: lo que levantes queda suelto'), findsOneWidget);

      // Con la letra agrandada la lista es larga: se baja hasta el proyecto.
      await tester.scrollUntilVisible(
        find.text('Visita del martes'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // Al tocarlo queda en uso, y la lista lo dice.
      await tester.tap(find.text('Visita del martes'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      sinDesbordes(tester);
      expect(
        find.text('En uso: lo que levantes se guarda aca'),
        findsOneWidget,
      );
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

    pantalla('marcar un punto, con sus tres botones', (tester) async {
      await abrir(
        tester,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) => FilledButton(
              onPressed: () => marcarPunto(
                context,
                ref,
                punto: const LatLng(4.405, -72.895),
                precisionM: 38,
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      sinDesbordes(tester);
      expect(find.text('Guardar con foto'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
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
            botonVoz: const BotonVoz(),
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
            botonVoz: const BotonVoz(),
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

    pantalla('las herramientas del mapa', (tester) async {
      HerramientaMapa? elegida;
      Widget mapa(EstadoGrabacion grabacion, Proyecto? proyecto) => Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async => elegida = await elegirHerramienta(
              context,
              grabacion: grabacion,
              proyecto: proyecto,
              conRutasGuardadas: true,
            ),
            child: const Text('abrir'),
          ),
        ),
      );
      Future<void> abrirHoja() async {
        await anotando(() async {
          await tester.tap(find.text('abrir'));
          await tester.pumpAndSettle();
        });
        sinDesbordes(tester);
      }

      // Sin nada en curso y sin proyecto: se ofrece grabar.
      await abrir(tester, mapa(const EstadoGrabacion(), null));
      await abrirHoja();
      expect(find.text('Sin proyecto'), findsOneWidget);
      expect(find.text('Grabar recorrido'), findsOneWidget);
      expect(find.text('Terminar el recorrido'), findsNothing);

      // La hoja solo dice que se eligio, y se cierra.
      await tester.ensureVisible(find.text('Medir distancia o area'));
      await tester.tap(find.text('Medir distancia o area'));
      await tester.pumpAndSettle();
      expect(elegida, HerramientaMapa.medir);
      expect(find.text('Grabar recorrido'), findsNothing);

      // Grabando, y con un proyecto de nombre largo: se ofrece terminar.
      final proyecto = await ProyectosRepository(db).crear(
        duenoAuthUid: 'uid-1',
        nombre: 'Finca La Esperanza del Rio Upia, lindero norte',
      );
      await abrir(
        tester,
        mapa(
          const EstadoGrabacion(
            codigo: 'rec-1',
            nombre: 'Recorrido del lindero norte, por la ronda del cano',
          ),
          proyecto,
        ),
      );
      await abrirHoja();
      expect(find.textContaining('Proyecto: Finca La Esperanza'), findsOne);
      expect(find.text('Terminar el recorrido'), findsOneWidget);
      expect(find.text('Grabar recorrido'), findsNothing);
      await tester.ensureVisible(find.text('Mi cuenta'));
      await tester.tap(find.text('Mi cuenta'));
      await tester.pumpAndSettle();
      expect(elegida, HerramientaMapa.cuenta);

      // En la vuelta de un camion la grabacion se finaliza desde su franja:
      // aca no se ofrece ni grabar ni terminar.
      await abrir(
        tester,
        mapa(
          const EstadoGrabacion(
            codigo: 'rec-2',
            nombre: 'Vuelta 12',
            propiedades: {'vuelta_id': 'v1'},
          ),
          null,
        ),
      );
      await abrirHoja();
      expect(find.text('Grabar recorrido'), findsNothing);
      expect(find.text('Terminar el recorrido'), findsNothing);
      expect(find.text('Rutas guardadas'), findsOneWidget);
    });

    pantalla('la cuenta, desde el mapa', (tester) async {
      await abrir(
        tester,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) => FilledButton(
              onPressed: () => mostrarCuentaDelMapa(context, ref),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await anotando(() async {
        await tester.tap(find.text('abrir'));
        await tester.pumpAndSettle();
      });

      sinDesbordes(tester);
      expect(find.textContaining('Sesion valida'), findsOneWidget);
      expect(find.text('Cerrar sesion'), findsOneWidget);
    });

    pantalla('la barra del GPS, y su color segun la precision', (tester) async {
      Position fix(double precision) => Position(
        latitude: 4.405123,
        longitude: -72.895456,
        timestamp: DateTime.now(),
        accuracy: precision,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
      Future<Color?> colorDe(BarraGps barra) async {
        await abrir(
          tester,
          Scaffold(
            backgroundColor: Colors.black,
            body: Stack(children: [barra]),
          ),
        );
        final caja = tester.widget<Container>(
          find.descendant(
            of: find.byType(BarraGps),
            matching: find.byType(Container),
          ),
        );
        return (caja.decoration! as BoxDecoration).color;
      }

      // Buscando: el renglon mas largo que muestra.
      expect(
        await colorDe(const BarraGps(posicion: null, error: null)),
        ColoresEstado.aviso,
      );
      expect(
        await colorDe(
          const BarraGps(
            posicion: null,
            error:
                'La app no tiene permiso para usar la ubicacion. Activalo en '
                'los ajustes del telefono.',
          ),
        ),
        ColoresEstado.mal,
      );
      // Con 10 m o menos el punto sirve para un lindero; con mas, no.
      expect(
        await colorDe(BarraGps(posicion: fix(4), error: null)),
        ColoresEstado.bien,
      );
      expect(find.textContaining('+/- 4 m'), findsOneWidget);
      expect(
        await colorDe(BarraGps(posicion: fix(38), error: null)),
        ColoresEstado.aviso,
      );
    });

    pantalla('los botones del mapa y el cartel de trazando', (tester) async {
      Widget costado({required bool conAcopios, required bool conPosicion}) =>
          Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Positioned(
                  right: 16,
                  bottom: 140,
                  child: BotonesDelMapa(
                    modo: ModoCamara.rumbo,
                    alAbrirHerramientas: () {},
                    alAbrirCapas: () {},
                    alBuscarAcopio: conAcopios ? () {} : null,
                    alCentrar: conPosicion ? () {} : null,
                  ),
                ),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: CalculandoRuta(),
                ),
              ],
            ),
          );

      await abrir(tester, costado(conAcopios: true, conPosicion: true));
      expect(find.byTooltip('Buscar un acopio'), findsOneWidget);
      expect(find.byTooltip('Norte arriba'), findsOneWidget);
      expect(find.textContaining('Trazando la ruta'), findsOneWidget);

      // El mapa a secas no tiene acopios que buscar; sin posicion, no hay
      // donde centrar y el boton queda apagado.
      await abrir(tester, costado(conAcopios: false, conPosicion: false));
      expect(find.byTooltip('Buscar un acopio'), findsNothing);
      final centrar = tester.widget<FloatingActionButton>(
        find.widgetWithIcon(FloatingActionButton, Icons.navigation),
      );
      expect(centrar.onPressed, isNull);
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
