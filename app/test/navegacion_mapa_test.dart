import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/core/indicaciones.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:geomaps/core/voz.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/mapas_repository.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/sincronizador.dart';
import 'package:geomaps/state/voz.dart';
import 'package:geomaps/state/zona_guaicaramo.dart';
import 'package:geomaps/ui/mapa/navegacion.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Una voz que anota lo que le piden decir, en vez de decirlo.
class _VozAnotada implements Voz {
  final dicho = <String>[];

  @override
  Future<void> decir(String texto) async => dicho.add(texto);

  @override
  Future<void> callar() async {}

  @override
  Future<bool> disponible() async => true;
}

/// Un grabador que no toca el GPS: anota con que lo arrancaron.
class _GrabadorFalso extends Grabador {
  _GrabadorFalso(TrazadosRepository repo) : super(repo, null, () {});

  /// Falso es el telefono que no deja grabar: sin permiso, sin usuario.
  bool arranca = true;
  String? proyecto;

  void poner(EstadoGrabacion estado) => state = estado;

  @override
  Future<void> iniciar({
    required String nombre,
    PuntoGeo? destino,
    String? destinoNombre,
    Map<String, Object?> propiedades = const {},
    String? proyectoCodigo,
  }) async {
    if (!arranca) return;
    proyecto = proyectoCodigo;
    state = EstadoGrabacion(
      codigo: 'rec-1',
      nombre: nombre,
      destino: destino,
      destinoNombre: destinoNombre,
      propiedades: propiedades,
    );
  }
}

/// Un sincronizador que solo cuenta las veces que lo llaman.
class _SincContado extends Sincronizador {
  _SincContado(AppDatabase db, ApiClient api)
    : super(db, TrazadosRepository(db), api, null);

  int veces = 0;

  @override
  Future<void> sincronizar() async => veces++;
}

/// La ruta del mapa, sin el mapa: calcularla, seguirla, decirla y guardarla.
///
/// Es lo que usa un conductor con el telefono en el tablero, asi que lo que se
/// cuida es lo que le pasa a el: que la ruta aparezca aunque el GPS llegue
/// tarde, que un salto del GPS no le cambie el camino, que la app no hable
/// cuando nadie le pidio indicaciones ni repita "te saliste" como un sermon, y
/// que al llegar pregunte una sola vez.
///
/// La red es la misma escalera de `ruteo_test`, de 1 km de lado:
///
///     A ---- B ---- C      lat 4.4010   (pavimentada, arriba)
///     |             |
///     D ---- E ---- F      lat 4.4000   (balastrada, abajo)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const a = LatLng(4.4010, -72.9000);
  const b = LatLng(4.4010, -72.8950);
  const c = LatLng(4.4010, -72.8900);
  const d = LatLng(4.4000, -72.9000);
  const e = LatLng(4.4000, -72.8950);
  const f = LatLng(4.4000, -72.8900);
  const vias = 'escalera.json';

  Via via(TipoVia tipo, List<LatLng> puntos) =>
      Via(tipo: tipo, interna: true, codBp: 'B.1-P.1', puntos: puntos);

  final red = RedVial.construir(
    ViasPredio([
      via(TipoVia.pavimentada, [a, b, c]),
      via(TipoVia.balastrada, [d, e, f]),
      via(TipoVia.balastrada, [a, d]),
      via(TipoVia.balastrada, [c, f]),
    ]),
  );

  Position en(LatLng p, {double precision = 8}) => Position(
    latitude: p.latitude,
    longitude: p.longitude,
    timestamp: DateTime.utc(2026, 11, 18, 15),
    accuracy: precision,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );

  late AppDatabase db;
  late _VozAnotada voz;
  late _GrabadorFalso grabador;
  late _SincContado sinc;
  late ProviderContainer contenedor;

  // Lo que la pantalla le presta a la ruta, anotado.
  late Position? posicion;
  late List<String> avisos;
  late List<bool> calificaciones;
  late int seguimientos;
  late int quitadas;
  late int redibujos;
  late DateTime ahora;
  late String? nombreElegido;
  late Completer<void>? calificando;

  /// Arma la ruta del mapa. [alArmarLaRed] deja demorar el grafo, que es lo
  /// que tarda la primera vez.
  NavegacionDelMapa navegacion({
    String? archivo = vias,
    Future<RedVial> Function()? alArmarLaRed,
  }) {
    final api = ApiClient(
      cliente: MockClient((_) async => http.Response('{}', 500)),
    );
    grabador = _GrabadorFalso(TrazadosRepository(db));
    sinc = _SincContado(db, api);
    contenedor = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(api),
        sesionProvider.overrideWith(
          (ref) => SesionNotifier.conSesion(
            api,
            Sesion(
              authUid: 'uid-1',
              codigoUsuario: 'USR-1',
              nombre: 'Ana',
              correo: 'ana@example.com',
              rol: 'Usuario',
              venceEn: DateTime.now().add(const Duration(days: 20)),
            ),
          ),
        ),
        vozProvider.overrideWithValue(voz),
        grabadorProvider.overrideWith((ref) => grabador),
        sincronizadorProvider.overrideWith((ref) => sinc),
        redVialProvider.overrideWith(
          (ref, archivo) => alArmarLaRed?.call() ?? Future.value(red),
        ),
      ],
    );
    addTearDown(contenedor.dispose);

    final nav = NavegacionDelMapa(
      leer: contenedor.read,
      archivoVias: archivo,
      posicion: () => posicion,
      avisar: avisos.add,
      alSeguir: () => seguimientos++,
      alQuitar: () => quitadas++,
      pedirNombre: (sugerido) async => nombreElegido,
      calificar: ({required llego}) async {
        calificaciones.add(llego);
        await calificando?.future;
      },
      reloj: () => ahora,
    )..addListener(() => redibujos++);
    return nav;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    voz = _VozAnotada();
    posicion = en(a);
    avisos = [];
    calificaciones = [];
    seguimientos = 0;
    quitadas = 0;
    redibujos = 0;
    ahora = DateTime(2026, 11, 18, 10);
    nombreElegido = 'Ruta al lote 4';
    calificando = null;
  });
  tearDown(() => db.close());

  /// Llega un fix: la pantalla guarda la posicion y despues le avisa a la ruta.
  Future<void> fix(NavegacionDelMapa nav, LatLng p, {double precision = 8}) {
    posicion = en(p, precision: precision);
    nav.alFix(posicion!);
    return pumpEventQueue();
  }

  /// Una ruta de A a F ya trazada.
  Future<NavegacionDelMapa> conRuta({String? nombre}) async {
    final nav = navegacion();
    nav.fijarDestino(f, nombre: nombre);
    await pumpEventQueue();
    expect(nav.ruta, isNotNull);
    return nav;
  }

  int vecesDicho(String frase) => voz.dicho.where((d) => d == frase).length;

  group('trazar la ruta', () {
    test('con posicion, la traza y pone la camara a seguirla', () async {
      final nav = navegacion();

      nav.fijarDestino(f);
      expect(nav.calculando, isTrue, reason: 'el cartel sale en el acto');
      await pumpEventQueue();

      expect(nav.destino, f);
      expect(nav.ruta!.metrosTotales, greaterThan(1000));
      expect(nav.progreso, isNotNull);
      expect(nav.calculando, isFalse);
      expect(seguimientos, 1);
      expect(redibujos, greaterThanOrEqualTo(2));
      expect(avisos, isEmpty);
    });

    test('sin GPS todavia, lo dice y deja el destino puesto', () async {
      final nav = navegacion();
      posicion = null;

      nav.fijarDestino(f);
      await pumpEventQueue();

      expect(avisos.single, contains('Sin senal de GPS'));
      expect(nav.destino, f);
      expect(nav.ruta, isNull);
      expect(nav.calculando, isFalse);
    });

    test(
      'el fix que llega despues traza la ruta que faltaba, callado',
      () async {
        // El mapa que abre un conductor con la vuelta ya tomada: el destino
        // esta puesto antes de que el GPS diga donde esta el camion.
        final nav = navegacion();
        posicion = null;
        nav.retomar(f, nombre: 'Acopio 38');
        expect(redibujos, 0);

        await fix(nav, a);

        expect(nav.ruta, isNotNull);
        expect(nav.nombreDestino, 'Acopio 38');
        expect(avisos, isEmpty);
      },
    );

    test(
      'lejos de toda via avisa una vez, y reintenta sin repetirlo',
      () async {
        final nav = navegacion();
        const monte = LatLng(4.4300, -72.9000);

        nav.fijarDestino(monte);
        await pumpEventQueue();
        expect(avisos.single, contains('No hay ruta por via'));
        expect(seguimientos, 0);

        // Cada posicion nueva vuelve a probar: doscientos metros pueden ser
        // justo lo que faltaba. Pero el cartel no vuelve a salir.
        await fix(nav, b);
        await fix(nav, c);

        expect(nav.ruta, isNull);
        expect(nav.destino, monte);
        expect(avisos, hasLength(1));
      },
    );

    test('en un mapa sin vias no hay nada que trazar', () async {
      final nav = navegacion(archivo: null);

      nav.fijarDestino(f);
      await pumpEventQueue();

      expect(nav.ruta, isNull);
      expect(nav.calculando, isFalse);
      expect(avisos, isEmpty);
    });

    test('si no se pueden leer las vias, lo dice y el mapa sigue', () async {
      final nav = navegacion(
        alArmarLaRed: () => Future.error(StateError('sin el asset')),
      );

      nav.fijarDestino(f);
      await pumpEventQueue();

      expect(avisos.single, contains('No se pudieron leer las vias'));
      expect(nav.calculando, isFalse);
    });

    test('un calculo viejo no pisa al destino nuevo', () async {
      // La primera ruta arma el grafo, que tarda. Si mientras tanto se marca
      // otro punto, la respuesta del primero ya no vale.
      final grafo = Completer<RedVial>();
      final nav = navegacion(alArmarLaRed: () => grafo.future);

      nav.fijarDestino(f);
      nav.fijarDestino(d, nombre: 'El patio');
      grafo.complete(red);
      await pumpEventQueue();

      expect(nav.ruta!.destino, d);
      expect(nav.nombreDestino, 'El patio');
      expect(seguimientos, 1);
      expect(nav.calculando, isFalse);
    });

    test('quitarla mientras se calcula no la deja aparecer despues', () async {
      final grafo = Completer<RedVial>();
      final nav = navegacion(alArmarLaRed: () => grafo.future);

      nav.fijarDestino(f);
      nav.quitar();
      grafo.complete(red);
      await pumpEventQueue();

      expect(nav.ruta, isNull);
      expect(nav.destino, isNull);
      expect(nav.calculando, isFalse);
      expect(quitadas, 1);
    });

    test('cerrado el mapa, lo que venia calculando se descarta', () async {
      final grafo = Completer<RedVial>();
      final nav = navegacion(alArmarLaRed: () => grafo.future);
      nav.fijarDestino(f);
      final antes = redibujos;

      nav.dispose();
      grafo.complete(red);
      await pumpEventQueue();

      expect(nav.ruta, isNull);
      expect(redibujos, antes);
    });
  });

  group('mirando cuanto falta, sin iniciarla', () {
    test('avanza el progreso con cada fix', () async {
      final nav = await conRuta();
      final alSalir = nav.progreso!.metrosRestantes;

      await fix(nav, b);

      expect(nav.progreso!.metrosRestantes, lessThan(alSalir - 400));
    });

    test('al llegar suelta la ruta y lo dice en pantalla', () async {
      final nav = await conRuta(nombre: 'Acopio 38');

      await fix(nav, f);

      expect(nav.ruta, isNull);
      expect(nav.destino, isNull);
      expect(quitadas, 1, reason: 'el acopio al que iba deja de estar elegido');
      expect(avisos.single, 'Llegaste: Acopio 38.');
      expect(calificaciones, isEmpty, reason: 'no se inicio: no se califica');
    });

    test('la app no habla: marcar un punto no es pedir indicaciones', () async {
      final nav = await conRuta();

      await fix(nav, b);
      await fix(nav, e); // Se sale de la ruta.
      await fix(nav, f);

      expect(voz.dicho, isEmpty);
    });
  });

  group('con la ruta iniciada', () {
    test(
      'se graba como navegacion, en el proyecto en uso, y se anuncia',
      () async {
        final nav = await conRuta(nombre: 'Acopio 38');

        await nav.iniciar();

        final g = contenedor.read(grabadorProvider);
        expect(NavegacionDelMapa.esNavegacion(g), isTrue);
        expect(g.nombre, 'Ruta a Acopio 38');
        expect(g.destinoNombre, 'Acopio 38');
        // Lo que la app prometio, para comparar con lo que se hizo.
        expect(
          g.propiedades['ruta_sugerida_m'],
          nav.ruta!.metrosTotales.round(),
        );
        expect(grabador.proyecto, MapasRepository.proyectoLocal);
        expect(seguimientos, 2, reason: 'al trazarla y al iniciarla');
        expect(avisos.single, startsWith('Ruta iniciada'));
        expect(voz.dicho.single, startsWith('Ruta a Acopio 38.'));
      },
    );

    test('si el telefono no deja grabar, lo dice y no anuncia nada', () async {
      final nav = await conRuta();
      grabador.arranca = false;

      await nav.iniciar();

      expect(avisos.single, 'No se pudo iniciar la ruta.');
      expect(voz.dicho, isEmpty);
      expect(seguimientos, 1);
    });

    test('al llegar lo dice y pide la calificacion una sola vez', () async {
      final nav = await conRuta(nombre: 'Acopio 38');
      await nav.iniciar();
      // El dialogo de calificar queda abierto mientras siguen llegando fixes.
      calificando = Completer<void>();

      await fix(nav, f);
      await fix(nav, f);
      await nav.terminar(llego: false);

      expect(calificaciones, [true]);
      expect(nav.ruta, isNull);
      expect(vecesDicho('Llegaste a Acopio 38.'), 1);

      calificando!.complete();
      await pumpEventQueue();
    });

    test('terminarla antes de llegar tambien pide la calificacion', () async {
      final nav = await conRuta();
      await nav.iniciar();

      await nav.terminar(llego: false);

      expect(calificaciones, [false]);
      expect(nav.destino, isNull);
    });

    test(
      'al salirse recalcula desde donde esta, sin mover la camara',
      () async {
        final nav = await conRuta();
        await nav.iniciar();
        final primera = nav.ruta;
        final seguia = seguimientos;

        // Iba por arriba (A-B-C) y aparece en la via de abajo, a 110 m.
        await fix(nav, e);

        expect(nav.ruta, isNot(same(primera)));
        expect(nav.ruta!.origen, e);
        expect(nav.ruta!.metrosTotales, lessThan(700));
        expect(seguimientos, seguia, reason: 'recalcular no recentra el mapa');
        expect(vecesDicho(GuiaRuta.alDesviarse), 1);
      },
    );

    test('un salto del GPS impreciso no le cambia el camino', () async {
      final nav = await conRuta();
      await nav.iniciar();
      final primera = nav.ruta;

      // El mismo punto, pero con 120 m de error: puede ser el mismo lugar.
      await fix(nav, e, precision: 120);

      expect(nav.ruta, same(primera));
      expect(vecesDicho(GuiaRuta.alDesviarse), 0);
    });

    test('"te saliste de la ruta" no se repite como un sermon', () async {
      final nav = await conRuta();
      await nav.iniciar();

      // Bajo palma el GPS salta de una via a la otra cada pocos segundos.
      await fix(nav, e);
      ahora = ahora.add(const Duration(seconds: 10));
      await fix(nav, b);
      ahora = ahora.add(const Duration(seconds: 10));
      await fix(nav, e);
      expect(vecesDicho(GuiaRuta.alDesviarse), 1);

      // Pasado un rato, si se vuelve a salir se vuelve a decir.
      ahora = ahora.add(const Duration(seconds: 60));
      await fix(nav, b);
      expect(vecesDicho(GuiaRuta.alDesviarse), 2);
    });
  });

  group('en la vuelta de un camion', () {
    EstadoGrabacion vuelta({List<double>? destino}) => EstadoGrabacion(
      codigo: 'rec-vuelta',
      nombre: 'Vuelta 12',
      propiedades: {'vuelta_id': 'v1', 'destino': ?destino},
    );

    test('la ruta se anuncia sola: no tiene boton de iniciar', () async {
      final nav = navegacion();
      grabador.poner(vuelta());

      nav.fijarDestino(f, nombre: 'los vagones');
      await pumpEventQueue();

      expect(voz.dicho.single, startsWith('Ruta a los vagones.'));
    });

    test('la llegada a los vagones la dice la vuelta, no dos veces', () async {
      final nav = navegacion();
      // El destino de la vuelta es el mismo punto al que lleva la ruta.
      grabador.poner(vuelta(destino: [f.longitude, f.latitude]));
      nav.fijarDestino(f, nombre: 'los vagones');
      await pumpEventQueue();

      await fix(nav, f);

      expect(vecesDicho('Llegaste a los vagones.'), 0);
      expect(avisos.single, 'Llegaste: los vagones.');
      expect(calificaciones, isEmpty, reason: 'la vuelta no se califica aca');
    });

    test('la llegada a otro punto de la vuelta si la dice la ruta', () async {
      final nav = navegacion();
      grabador.poner(vuelta(destino: [a.longitude, a.latitude]));
      posicion = en(c);
      nav.fijarDestino(f, nombre: 'el taller');
      await pumpEventQueue();

      await fix(nav, f);

      expect(vecesDicho('Llegaste a el taller.'), 1);
    });
  });

  group('guardarla', () {
    test(
      'queda en el telefono con el nombre elegido, y pide subirla',
      () async {
        final nav = await conRuta(nombre: 'Acopio 38');

        await nav.guardar();

        final rutas = await TrazadosRepository(db).observarRutas('USR-1').first;
        expect(rutas.single.nombre, 'Ruta al lote 4');
        expect(nav.guardada, isTrue);
        expect(avisos.single, startsWith('Ruta guardada'));
        expect(sinc.veces, 1);
      },
    );

    test('si se cancela el nombre no se guarda nada', () async {
      final nav = await conRuta();
      nombreElegido = null;

      await nav.guardar();

      expect(
        await TrazadosRepository(db).observarRutas('USR-1').first,
        isEmpty,
      );
      expect(nav.guardada, isFalse);
      expect(avisos, isEmpty);
    });

    test('una ruta abierta de la lista ya figura guardada', () async {
      final nav = await conRuta();

      nav.marcarGuardada();
      expect(nav.guardada, isTrue);

      // Otro destino es otra ruta: esa todavia no esta guardada.
      nav.fijarDestino(d);
      expect(nav.guardada, isFalse);
    });
  });
}
