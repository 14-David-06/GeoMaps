import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/state/grabacion.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/red.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/ubicacion_provider.dart';
import 'package:geomaps/state/zona_guaicaramo.dart';
import 'package:geomaps/ui/cerrar_sesion.dart';
import 'package:geomaps/ui/home_page.dart';
import 'package:geomaps/ui/login_page.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Un grabador con el estado puesto a mano.
class _GrabadorFijo extends Grabador {
  _GrabadorFijo(TrazadosRepository repo, EstadoGrabacion estado)
    : super(repo, null, () {}) {
    state = estado;
  }
}

/// La sesion en los dos momentos en que puede costarle la jornada a alguien:
/// cuando vence estando sin senal, y cuando se cierra con trabajo sin subir.
void main() {
  const usuario = 'USR-1';
  late AppDatabase db;

  Sesion sesion({required bool vencida}) => Sesion(
    authUid: 'uid-1',
    codigoUsuario: usuario,
    nombre: 'Ana Gomez',
    correo: 'ana@example.com',
    rol: 'Usuario',
    proveedor: 'Correo',
    venceEn: DateTime.now().add(Duration(days: vencida ? -3 : 20)),
  );

  /// Lo que responde el servidor a un ingreso que salio bien.
  String ingresoBien() => jsonEncode({
    'token': 'jwt-nuevo',
    'auth_uid': 'uid-1',
    'codigo_usuario': usuario,
    'nombre': 'Ana Gomez',
    'correo': 'ana@example.com',
    'rol': 'Usuario',
    'proveedor': 'Correo',
    'vence_en': DateTime.now()
        .add(const Duration(days: 30))
        .toUtc()
        .toIso8601String(),
    'perfiles': ['plantacion'],
  });

  setUp(() {
    // Las consultas en vivo se cierran en el acto: ver letra_grande_test.
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => db.close());

  Future<void> unLote() => TrazadosRepository(db).guardarPoligono(
    usuarioCodigo: usuario,
    nombre: 'Lote de prueba',
    vertices: const [
      PuntoGeo(4.40, -72.90),
      PuntoGeo(4.41, -72.90),
      PuntoGeo(4.41, -72.89),
    ],
  );

  group('una sesion vencida', () {
    test('al abrir la app sigue adentro, con lo suyo', () async {
      // Vencio estando en el lote: entrar de nuevo necesita red, y ahi no hay.
      FlutterSecureStorage.setMockInitialValues({
        'jwt': 'jwt-viejo',
        'sesion': jsonEncode(sesion(vencida: true).aJson()),
      });
      final api = ApiClient(cliente: MockClient((_) async => fail('sin red')));

      final notifier = SesionNotifier(api);
      await pumpEventQueue();

      expect(notifier.state.arrancando, isFalse);
      expect(notifier.state.sesion?.codigoUsuario, usuario);
      expect(notifier.state.vencida, isTrue);
      expect(notifier.state.autenticado, isFalse);
      // La sesion guardada no se borra: mañana tiene que seguir entrando.
      expect(await const FlutterSecureStorage().read(key: 'sesion'), isNotNull);
    });

    test('si falla al volver a entrar, no queda afuera', () async {
      final notifier = SesionNotifier.conSesion(
        ApiClient(
          cliente: MockClient(
            (_) async => http.Response('{"detail":"Clave incorrecta."}', 401),
          ),
        ),
        sesion(vencida: true),
      );

      await notifier.entrarConClave('ana@example.com', 'no-era');

      expect(notifier.state.sesion?.codigoUsuario, usuario);
      expect(notifier.state.vencida, isTrue);
      expect(notifier.state.error, 'Clave incorrecta.');
      expect(notifier.state.cargando, isFalse);
    });

    test('cuando entra de nuevo, la sesion queda al dia', () async {
      final api = ApiClient(
        cliente: MockClient((_) async => http.Response(ingresoBien(), 200)),
      );
      final notifier = SesionNotifier.conSesion(api, sesion(vencida: true));

      await notifier.entrarConClave('ana@example.com', 'la-buena');

      expect(notifier.state.autenticado, isTrue);
      expect(notifier.state.vencida, isFalse);
      expect(api.token, 'jwt-nuevo');
    });

    test('quien nunca entro si va al ingreso', () async {
      final notifier = SesionNotifier(ApiClient());
      await pumpEventQueue();

      expect(notifier.state.arrancando, isFalse);
      expect(notifier.state.sesion, isNull);
    });

    testWidgets('el inicio avisa, y desde ahi se entra de nuevo', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final api = ApiClient(
        cliente: MockClient((pedido) async {
          return pedido.url.path == '/v1/sesion/clave'
              ? http.Response(ingresoBien(), 200)
              : http.Response('{"detail":"La sesion vencio."}', 401);
        }),
      )..token = 'jwt-viejo';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbProvider.overrideWithValue(db),
            apiProvider.overrideWithValue(api),
            sesionProvider.overrideWith(
              (ref) => SesionNotifier.conSesion(api, sesion(vencida: true)),
            ),
            redProvider.overrideWith(
              (ref) => Stream.value(const RedState([ConnectivityResult.wifi])),
            ),
            posicionProvider.overrideWith((ref) => const Stream.empty()),
            estadoGuaicaramoProvider.overrideWithValue(
              const EstadoZona(motivo: MotivoZona.buscandoGps),
            ),
          ],
          child: MaterialApp(theme: temaSirius, home: const HomePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Adentro, con el aviso arriba y las herramientas de siempre.
      expect(find.text('Tu sesion vencio'), findsOneWidget);
      expect(find.text('Sesion vencida'), findsOneWidget);
      expect(find.text('Mapa'), findsOneWidget);

      await tester.tap(find.text('Entrar de nuevo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Correo'),
        'ana@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Clave'),
        'la-buena',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      // El ingreso se cerro solo y el aviso ya no esta.
      expect(find.byType(LoginPage), findsNothing);
      expect(find.text('Tu sesion vencio'), findsNothing);
      expect(find.text('Mapa'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('cerrar sesion', () {
    late List<String> subidas;

    /// Una pantalla con un boton de salir, y si [arriba], otra encima con el
    /// suyo: es salir desde el mapa, con el inicio debajo.
    Future<ProviderContainer> abrir(
      WidgetTester tester, {
      bool hayRed = true,
      int servidor = 200,
      EstadoGrabacion grabando = const EstadoGrabacion(),
      bool arriba = false,
    }) async {
      subidas = [];
      final api = ApiClient(
        cliente: MockClient((pedido) async {
          if (pedido.url.path != '/v1/sync') return http.Response('{}', 404);
          if (servidor != 200) {
            return http.Response('{"detail":"El servidor no pudo."}', servidor);
          }
          final trazados =
              (jsonDecode(pedido.body) as Map<String, dynamic>)['trazados']
                  as List;
          subidas.addAll([for (final t in trazados) (t as Map)['nombre']]);
          return http.Response(
            jsonEncode({
              'trazados': [
                for (final t in trazados)
                  {
                    'codigo': (t as Map)['codigo'],
                    'ok': true,
                    'llave_geometria': 'llave',
                  },
              ],
            }),
            200,
          );
        }),
      )..token = 'jwt';

      Widget boton(String texto) => Consumer(
        builder: (context, ref, _) => Center(
          child: FilledButton(
            onPressed: () => cerrarSesion(context, ref),
            child: Text(texto),
          ),
        ),
      );

      late ProviderContainer contenedor;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbProvider.overrideWithValue(db),
            apiProvider.overrideWithValue(api),
            sesionProvider.overrideWith(
              (ref) => SesionNotifier.conSesion(api, sesion(vencida: false)),
            ),
            redProvider.overrideWith(
              (ref) => Stream.value(
                RedState([
                  hayRed ? ConnectivityResult.wifi : ConnectivityResult.none,
                ]),
              ),
            ),
            grabadorProvider.overrideWith(
              (ref) => _GrabadorFijo(TrazadosRepository(db), grabando),
            ),
          ],
          child: MaterialApp(
            theme: temaSirius,
            home: Builder(
              builder: (context) {
                contenedor = ProviderScope.containerOf(context);
                return Scaffold(
                  body: Column(
                    children: [
                      const Text('el inicio'),
                      boton('salir'),
                      if (arriba)
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                body: Column(
                                  children: [
                                    const Text('el mapa'),
                                    boton('salir desde el mapa'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          child: const Text('abrir el mapa'),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return contenedor;
    }

    bool adentro(ProviderContainer c) => c.read(sesionProvider).sesion != null;

    /// Toca [texto] y espera a que termine lo que desate. Cerrar la sesion
    /// pasa por canales de plataforma -Google, el almacen seguro-, y eso no lo
    /// destraba `pump`: hace falta dejar correr el reloj de verdad.
    Future<void> tocar(WidgetTester tester, String texto) async {
      await tester.tap(find.text(texto));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> cerrar(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox());

    testWidgets('sin nada pendiente, sale sin preguntar', (tester) async {
      final c = await abrir(tester);

      await tocar(tester, 'salir');

      expect(find.byType(AlertDialog), findsNothing);
      expect(adentro(c), isFalse);
      await cerrar(tester);
    });

    testWidgets('con registros sin subir pregunta, y quedarse no sale', (
      tester,
    ) async {
      await unLote();
      final c = await abrir(tester);

      await tocar(tester, 'salir');

      expect(find.text('Tenes 1 registro sin subir'), findsOneWidget);
      // Dice lo que de verdad pasa: no se pierde, pero queda esperando.
      expect(
        find.textContaining('solo suben cuando vuelvas a entrar'),
        findsOneWidget,
      );

      await tocar(tester, 'Quedarme');

      expect(adentro(c), isTrue);
      await cerrar(tester);
    });

    testWidgets('subir ahora sube lo pendiente y recien ahi sale', (
      tester,
    ) async {
      await unLote();
      final c = await abrir(tester);

      await tocar(tester, 'salir');
      await tocar(tester, 'Subir ahora');

      expect(subidas, ['Lote de prueba']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(adentro(c), isFalse);
      await cerrar(tester);
    });

    testWidgets('si no sube, no sale y dice por que', (tester) async {
      await unLote();
      final c = await abrir(tester, servidor: 500);

      await tocar(tester, 'salir');
      await tocar(tester, 'Subir ahora');

      expect(find.text('El servidor no pudo.'), findsOneWidget);
      expect(adentro(c), isTrue);

      // Y se puede salir igual: la decision es de la persona.
      await tocar(tester, 'Salir sin subir');
      expect(adentro(c), isFalse);
      await cerrar(tester);
    });

    testWidgets('sin conexion no ofrece subir, pero deja salir', (
      tester,
    ) async {
      await unLote();
      final c = await abrir(tester, hayRed: false);

      await tocar(tester, 'salir');

      expect(find.text('Ahora no hay conexion para subirlos.'), findsOneWidget);
      final subir = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Subir ahora'),
      );
      expect(subir.onPressed, isNull);

      await tocar(tester, 'Salir sin subir');
      expect(adentro(c), isFalse);
      expect(subidas, isEmpty);
      await cerrar(tester);
    });

    testWidgets('con un recorrido abierto, avisa que no va a subir', (
      tester,
    ) async {
      final c = await abrir(
        tester,
        grabando: const EstadoGrabacion(
          codigo: 't1',
          nombre: 'Recorrido del martes',
        ),
      );

      await tocar(tester, 'salir');

      expect(find.text('Hay un recorrido sin terminar'), findsOneWidget);
      expect(find.textContaining('Recorrido del martes'), findsOneWidget);
      expect(find.text('Subir ahora'), findsNothing);

      await tocar(tester, 'Quedarme');
      expect(adentro(c), isTrue);
      await cerrar(tester);
    });

    testWidgets('con la letra agrandada el aviso no se desborda', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await unLote();
      await abrir(
        tester,
        hayRed: false,
        grabando: const EstadoGrabacion(
          codigo: 't1',
          nombre: 'Recorrido del martes por la tarde',
        ),
      );

      await tocar(tester, 'salir');

      expect(tester.takeException(), isNull);
      expect(find.text('Salir sin subir'), findsOneWidget);
      await cerrar(tester);
    });

    testWidgets('salir desde el mapa vuelve al inicio, donde esta el ingreso', (
      tester,
    ) async {
      final c = await abrir(tester, arriba: true);
      await tocar(tester, 'abrir el mapa');
      expect(find.text('el mapa'), findsOneWidget);

      await tocar(tester, 'salir desde el mapa');

      expect(adentro(c), isFalse);
      expect(find.text('el mapa'), findsNothing, reason: 'tapaba el ingreso');
      expect(find.text('el inicio'), findsOneWidget);
      await cerrar(tester);
    });
  });
}
