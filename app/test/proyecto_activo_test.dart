import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/data/archivos_repository.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/mapas_repository.dart';
import 'package:geomaps/data/proyectos_repository.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/data/waypoints_repository.dart';
import 'package:geomaps/state/proyecto_activo.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/sincronizador.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// El proyecto en el que se trabaja, y como llega a la base.
///
/// Antes todo lo que se levantaba caia en "Sin proyecto": la lista de
/// proyectos existia, pero el mapa no la miraba. Lo que se cuida aca es que
/// lo nuevo se guarde donde la persona eligio, que la eleccion no se herede
/// entre cuentas en un telefono compartido, y que el proyecto suba antes que
/// lo que cuelga de el.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ana = 'uid-ana';
  const beto = 'uid-beto';
  const usuario = 'USR-ANA';
  late AppDatabase db;
  late ProyectosRepository proyectos;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    proyectos = ProyectosRepository(db);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => db.close());

  ProviderContainer contenedor({String authUid = ana}) {
    final api = ApiClient(
      cliente: MockClient((_) async => http.Response('{}', 500)),
    );
    final c = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        apiProvider.overrideWithValue(api),
        sesionProvider.overrideWith(
          (ref) => SesionNotifier.conSesion(
            api,
            Sesion(
              authUid: authUid,
              codigoUsuario: usuario,
              nombre: 'Ana',
              correo: 'ana@example.com',
              rol: 'Usuario',
              venceEn: DateTime.now().add(const Duration(days: 20)),
            ),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<Proyecto> unProyecto(String nombre, {String de = ana}) =>
      proyectos.crear(duenoAuthUid: de, nombre: nombre);

  group('donde se guarda lo nuevo', () {
    test('sin elegir ninguno, cae en "sin proyecto" como siempre', () async {
      final c = contenedor();

      expect(
        await c.read(proyectoParaGuardarProvider.future),
        MapasRepository.proyectoLocal,
      );
    });

    test('con uno elegido, cae en ese', () async {
      final finca = await unProyecto('Finca La Esperanza');
      final c = contenedor();

      await c.read(proyectoElegidoProvider.notifier).elegir(finca.codigo);

      expect(await c.read(proyectoParaGuardarProvider.future), finca.codigo);
      expect(
        (await c.read(proyectoActivoProvider.future))?.nombre,
        'Finca La Esperanza',
      );
    });

    test('la eleccion queda guardada para la proxima vez', () async {
      final finca = await unProyecto('Finca La Esperanza');
      await contenedor()
          .read(proyectoElegidoProvider.notifier)
          .elegir(finca.codigo);

      // La app se cierra y vuelve.
      final otra = contenedor();
      otra.read(proyectoElegidoProvider);
      await pumpEventQueue();

      expect(await otra.read(proyectoParaGuardarProvider.future), finca.codigo);
    });

    test('quien entra despues en el mismo telefono no la hereda', () async {
      // Un aparato pasa de mano en mano. El proyecto de Ana no es de Beto, y
      // el trabajo de Beto no puede caer en el.
      final finca = await unProyecto('Finca de Ana');
      await contenedor()
          .read(proyectoElegidoProvider.notifier)
          .elegir(finca.codigo);

      final deBeto = contenedor(authUid: beto);
      deBeto.read(proyectoElegidoProvider);
      await pumpEventQueue();

      expect(
        await deBeto.read(proyectoParaGuardarProvider.future),
        MapasRepository.proyectoLocal,
      );
    });

    test('un proyecto archivado deja de recibir trabajo nuevo', () async {
      final finca = await unProyecto('Finca La Esperanza');
      final c = contenedor();
      await c.read(proyectoElegidoProvider.notifier).elegir(finca.codigo);
      expect(await c.read(proyectoParaGuardarProvider.future), finca.codigo);

      await proyectos.archivar(finca.codigo);
      await pumpEventQueue();

      expect(
        await c.read(proyectoParaGuardarProvider.future),
        MapasRepository.proyectoLocal,
      );
    });

    test('volver a "sin proyecto" tambien se puede', () async {
      final finca = await unProyecto('Finca La Esperanza');
      final c = contenedor();
      await c.read(proyectoElegidoProvider.notifier).elegir(finca.codigo);

      await c.read(proyectoElegidoProvider.notifier).elegir(null);

      expect(
        await c.read(proyectoParaGuardarProvider.future),
        MapasRepository.proyectoLocal,
      );
    });

    test(
      'la foto va al proyecto de su punto, no al que este elegido',
      () async {
        final finca = await unProyecto('Finca La Esperanza');
        final punto = await WaypointsRepository(db).marcar(
          usuarioCodigo: usuario,
          nombre: 'Alcantarilla',
          punto: const PuntoGeo(4.4, -72.9),
          proyectoCodigo: finca.codigo,
        );
        final carpeta = Directory.systemTemp.createTempSync('geomaps-proy');
        addTearDown(() => carpeta.deleteSync(recursive: true));
        final camara = File('${carpeta.path}/camara.jpg')
          ..writeAsBytesSync([1, 2, 3]);

        // Entre marcar el punto y tomarle la foto se pudo cambiar de proyecto.
        final foto =
            await ArchivosRepository(
              db,
              carpetaBase: () async => carpeta,
            ).guardarFoto(
              origen: camara,
              waypointCodigo: punto.codigo,
              usuarioCodigo: usuario,
            );

        expect(foto.proyectoCodigo, finca.codigo);
      },
    );
  });

  group('subir', () {
    late List<Map<String, dynamic>> cuerpos;

    Sincronizador sincronizador({bool servidorViejo = false}) {
      cuerpos = [];
      final api = ApiClient(
        cliente: MockClient((pedido) async {
          final cuerpo = jsonDecode(pedido.body) as Map<String, dynamic>;
          cuerpos.add(cuerpo);
          List<Map<String, Object?>> ok(String llave) => [
            for (final x in (cuerpo[llave] as List? ?? []))
              {
                'codigo': (x as Map)['codigo'],
                'ok': true,
                'llave_geometria': 'llave',
              },
          ];
          return http.Response(
            jsonEncode({
              'trazados': ok('trazados'),
              'waypoints': ok('waypoints'),
              if (!servidorViejo) 'proyectos': ok('proyectos'),
            }),
            200,
          );
        }),
      )..token = 'jwt';
      return Sincronizador(
        db,
        TrazadosRepository(db),
        api,
        usuario,
        authUid: ana,
      );
    }

    Future<Trazado> unLote(String proyectoCodigo) =>
        TrazadosRepository(db).guardarPoligono(
          usuarioCodigo: usuario,
          nombre: 'Lote 4',
          vertices: const [
            PuntoGeo(4.40, -72.90),
            PuntoGeo(4.41, -72.90),
            PuntoGeo(4.41, -72.89),
          ],
          proyectoCodigo: proyectoCodigo,
        );

    test('el proyecto sube antes que lo que cuelga de el', () async {
      final finca = await unProyecto('Finca La Esperanza');
      await unLote(finca.codigo);
      final s = sincronizador();

      await s.sincronizar();

      expect(cuerpos.first.keys, ['proyectos']);
      final enviado = (cuerpos.first['proyectos'] as List).single as Map;
      expect(enviado['codigo'], finca.codigo);
      expect(enviado['nombre'], 'Finca La Esperanza');
      expect(enviado['activo'], isTrue);
      // Y el lote viaja con el codigo de su proyecto, no con "local".
      final lote = (cuerpos[1]['trazados'] as List).single as Map;
      expect(lote['proyecto_codigo'], finca.codigo);

      expect(await proyectos.pendientes(ana), isEmpty);
      expect(s.state.subidos, 2);
      expect(s.state.error, isNull);
    });

    test('un proyecto recien creado sube aunque este vacio', () async {
      await unProyecto('Finca nueva');
      final s = sincronizador();

      await s.sincronizar();

      expect(cuerpos, hasLength(1));
      expect(await proyectos.pendientes(ana), isEmpty);
    });

    test('archivarlo tambien se sube', () async {
      final finca = await unProyecto('Finca La Esperanza');
      await sincronizador().sincronizar();
      await proyectos.archivar(finca.codigo);

      await sincronizador().sincronizar();

      final enviado = (cuerpos.single['proyectos'] as List).single as Map;
      expect(enviado['activo'], isFalse);
    });

    test('los proyectos de otra cuenta no viajan', () async {
      await unProyecto('De Beto', de: beto);
      final s = sincronizador();

      await s.sincronizar();

      expect(cuerpos, isEmpty);
    });

    test(
      'contra un servidor que todavia no recibe proyectos, lo demas sube',
      () async {
        // El backend publicado puede ser anterior a este APK.
        await unProyecto('Finca La Esperanza');
        await unLote(MapasRepository.proyectoLocal);
        final s = sincronizador(servidorViejo: true);

        await s.sincronizar();

        expect(s.state.error, contains('todavia no recibe proyectos'));
        expect(await proyectos.pendientes(ana), hasLength(1));
        // El lote sin proyecto si quedo arriba.
        expect(await TrazadosRepository(db).pendientes(usuario), isEmpty);
      },
    );
  });
}
