import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/camara.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/data/archivos_repository.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/trazados_repository.dart';
import 'package:geomaps/data/waypoints_repository.dart';
import 'package:geomaps/state/fotos.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/state/sesion.dart';
import 'package:geomaps/state/sincronizador.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Una camara que entrega el archivo que la prueba le deja listo.
class _CamaraFalsa implements Camara {
  File? proxima;
  File? perdida;
  var abierta = 0;

  @override
  Future<File?> tomar() async {
    abierta++;
    return proxima;
  }

  @override
  Future<File?> recuperarPerdida() async => perdida;
}

/// Las fotos de los puntos marcados.
///
/// Un punto dice "alcantarilla tapada"; la foto dice cuanto. Se toman en el
/// lote, sin senal, y suben despues. Lo que se cuida: que la foto no se
/// pierda entre la camara y la app, que no suba antes que su punto -no
/// tendria de donde colgarse-, y que no pase por el backend sino directo al
/// almacenamiento, con el permiso que el backend le firmo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const usuario = 'USR-1';
  late AppDatabase db;
  late Directory carpeta;
  late ArchivosRepository archivos;
  late WaypointsRepository puntos;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    carpeta = Directory.systemTemp.createTempSync('geomaps-fotos');
    archivos = ArchivosRepository(db, carpetaBase: () async => carpeta);
    puntos = WaypointsRepository(db);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await db.close();
    carpeta.deleteSync(recursive: true);
  });

  /// Una foto como la deja la camara: un archivo en la cache.
  File deLaCamara([String nombre = 'camara.jpg', int bytes = 4200]) {
    final archivo = File('${carpeta.path}/$nombre');
    archivo.writeAsBytesSync(List.generate(bytes, (i) => i % 251));
    return archivo;
  }

  Future<Waypoint> unPunto([String nombre = 'Alcantarilla tapada']) =>
      puntos.marcar(
        usuarioCodigo: usuario,
        nombre: nombre,
        punto: const PuntoGeo(4.405, -72.895),
      );

  group('guardar', () {
    test('la foto de la camara queda en la carpeta de la app', () async {
      final punto = await unPunto();
      final origen = deLaCamara();

      final foto = await archivos.guardarFoto(
        origen: origen,
        waypointCodigo: punto.codigo,
        usuarioCodigo: usuario,
      );

      // Copiada adonde Android no la borra, y la de la cache ya no hace falta.
      expect(foto.rutaLocal, contains('fotos'));
      expect(File(foto.rutaLocal).lengthSync(), 4200);
      expect(origen.existsSync(), isFalse);
      expect(foto.waypointCodigo, punto.codigo);
      expect(foto.sincronizado, isFalse);
      expect(await archivos.fotosDe(punto.codigo), hasLength(1));
    });

    test('borrar el punto se lleva sus fotos, y solo las suyas', () async {
      final uno = await unPunto('Uno');
      final otro = await unPunto('Otro');
      final a = await archivos.guardarFoto(
        origen: deLaCamara('a.jpg'),
        waypointCodigo: uno.codigo,
        usuarioCodigo: usuario,
      );
      final b = await archivos.guardarFoto(
        origen: deLaCamara('b.jpg'),
        waypointCodigo: otro.codigo,
        usuarioCodigo: usuario,
      );

      await archivos.borrarDelPunto(uno.codigo);

      expect(File(a.rutaLocal).existsSync(), isFalse);
      expect(await archivos.fotosDe(uno.codigo), isEmpty);
      expect(File(b.rutaLocal).existsSync(), isTrue);
      expect(await archivos.fotosDe(otro.codigo), hasLength(1));
    });
  });

  group('la camara', () {
    late _CamaraFalsa camara;

    ProviderContainer contenedor() {
      final api = ApiClient(
        cliente: MockClient((_) async => http.Response('{}', 500)),
      );
      final c = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          archivosRepositoryProvider.overrideWithValue(archivos),
          camaraProvider.overrideWithValue(camara),
          apiProvider.overrideWithValue(api),
          sesionProvider.overrideWith(
            (ref) => SesionNotifier.conSesion(
              api,
              Sesion(
                authUid: 'uid-1',
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

    setUp(() => camara = _CamaraFalsa());

    test('tomar una foto la deja guardada en su punto', () async {
      final punto = await unPunto();
      camara.proxima = deLaCamara();
      final c = contenedor();

      final foto = await c.read(fotosProvider).tomar(punto.codigo);

      expect(foto, isNotNull);
      expect(
        (await archivos.fotosDe(punto.codigo)).single.codigo,
        foto!.codigo,
      );
    });

    test('si se cancela la camara no queda nada', () async {
      final punto = await unPunto();
      final c = contenedor();

      expect(await c.read(fotosProvider).tomar(punto.codigo), isNull);

      expect(camara.abierta, 1);
      expect(await archivos.fotosDe(punto.codigo), isEmpty);
    });

    test('si Android cerro la app con la camara abierta, se rescata', () async {
      // Pasa en telefonos con poca memoria: al volver de la camara la app
      // arranca de cero. Lo unico que queda es para que punto era.
      final punto = await unPunto();
      SharedPreferences.setMockInitialValues({
        'foto_para_el_punto': punto.codigo,
      });
      camara.perdida = deLaCamara('perdida.jpg');
      final c = contenedor();

      await c.read(fotosProvider).rescatarPerdida();

      expect(await archivos.fotosDe(punto.codigo), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('foto_para_el_punto'), isNull);
    });

    test('sin nada en el aire, el rescate no hace nada', () async {
      final punto = await unPunto();
      camara.perdida = deLaCamara('suelta.jpg');
      final c = contenedor();

      // Hay un archivo perdido pero nadie anoto para que punto era.
      await c.read(fotosProvider).rescatarPerdida();

      expect(await archivos.fotosDe(punto.codigo), isEmpty);
    });
  });

  group('subir', () {
    late List<http.Request> pedidos;

    /// Un servidor entero: el backend y el almacenamiento.
    Sincronizador sincronizador({
      int fotos = 200,
      int almacen = 200,
      bool puntoOk = true,
    }) {
      pedidos = [];
      final api = ApiClient(
        cliente: MockClient((pedido) async {
          pedidos.add(pedido);
          final ruta = pedido.url.path;
          if (pedido.url.host == 'bucket.test') {
            return http.Response('', almacen);
          }
          if (ruta == '/v1/sync') {
            final cuerpo = jsonDecode(pedido.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'trazados': <Object>[],
                'waypoints': [
                  for (final w in (cuerpo['waypoints'] as List? ?? []))
                    {
                      'codigo': (w as Map)['codigo'],
                      'ok': puntoOk,
                      if (!puntoOk) 'error': 'No se pudo.',
                    },
                ],
              }),
              200,
            );
          }
          if (ruta == '/v1/fotos') {
            if (fotos != 200) {
              return http.Response('{"detail":"Not Found"}', fotos);
            }
            final cuerpo = jsonDecode(pedido.body) as Map<String, dynamic>;
            final llave =
                'proyectos/local-1/fotos/${cuerpo['waypoint_codigo']}/'
                '${cuerpo['codigo']}.jpg';
            return http.Response(
              jsonEncode({
                'url': 'https://bucket.test/$llave?firma=put',
                'llave': llave,
                'content_type': 'image/jpeg',
                'vence_en_s': 3600,
              }),
              200,
            );
          }
          if (ruta.endsWith('/confirmar')) {
            final codigo = ruta.split('/')[3];
            return http.Response(
              jsonEncode({'codigo': codigo, 'llave': 'llave-de-$codigo'}),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      )..token = 'jwt';
      return Sincronizador(
        db,
        TrazadosRepository(db),
        api,
        usuario,
        archivos: archivos,
      );
    }

    Future<Archivo> unaFoto(Waypoint punto) => archivos.guardarFoto(
      origen: deLaCamara(),
      waypointCodigo: punto.codigo,
      usuarioCodigo: usuario,
    );

    test('la foto espera a que suba su punto', () async {
      final punto = await unPunto();
      await unaFoto(punto);

      expect(await archivos.fotosParaSubir(usuario), isEmpty);
      // Pero para quien mira el contador, falta subirla.
      expect(await archivos.contarPendientes(usuario).first, 1);

      await puntos.marcarSubido(punto.codigo);
      expect(await archivos.fotosParaSubir(usuario), hasLength(1));
    });

    test(
      'sube el punto, y despues la foto directo al almacenamiento',
      () async {
        final punto = await unPunto();
        final foto = await unaFoto(punto);
        final s = sincronizador();

        await s.sincronizar();

        expect(pedidos.map((p) => '${p.method} ${p.url.host}${p.url.path}'), [
          'POST ${Uri.parse(pedidos.first.url.origin).host}/v1/sync',
          'POST ${Uri.parse(pedidos.first.url.origin).host}/v1/fotos',
          'PUT bucket.test/proyectos/local-1/fotos/${punto.codigo}/'
              '${foto.codigo}.jpg',
          'POST ${Uri.parse(pedidos.first.url.origin).host}/v1/fotos/'
              '${foto.codigo}/confirmar',
        ]);

        // Al almacenamiento va la foto tal cual, con el tipo que se firmo y
        // **sin** las llaves del backend: una cabecera de mas rompe la firma, y
        // el token de la sesion no tiene por que salir hacia otro servidor.
        final subida = pedidos[2];
        expect(subida.bodyBytes, File(foto.rutaLocal).readAsBytesSync());
        expect(subida.headers['Content-Type'], 'image/jpeg');
        expect(subida.headers.containsKey('Authorization'), isFalse);
        expect(subida.headers.containsKey('X-API-Key'), isFalse);

        final guardada = (await archivos.fotosDe(punto.codigo)).single;
        expect(guardada.sincronizado, isTrue);
        expect(guardada.llaveS3, 'llave-de-${foto.codigo}');
        // Subir no la borra del telefono: se tiene que poder ver en el lote.
        expect(File(guardada.rutaLocal).existsSync(), isTrue);
        expect(s.state.subidos, 2);
        expect(s.state.error, isNull);
      },
    );

    test('si el punto no subio, la foto ni se intenta', () async {
      final punto = await unPunto();
      await unaFoto(punto);
      final s = sincronizador(puntoOk: false);

      await s.sincronizar();

      expect(pedidos.where((p) => p.url.path.contains('fotos')), isEmpty);
      expect(
        (await archivos.fotosDe(punto.codigo)).single.sincronizado,
        isFalse,
      );
    });

    test('contra un servidor que todavia no recibe fotos, esperan', () async {
      // El backend publicado puede ser anterior a este APK.
      final punto = await unPunto();
      await unaFoto(punto);
      await unaFoto(punto);
      final s = sincronizador(fotos: 404);

      await s.sincronizar();

      expect(
        pedidos.where((p) => p.url.path == '/v1/fotos'),
        hasLength(1),
        reason: 'con la primera alcanza para saberlo',
      );
      expect(s.state.error, contains('todavia no recibe fotos'));
      expect(await archivos.contarPendientes(usuario).first, 2);
      // El punto si quedo arriba.
      expect(await puntos.pendientes(usuario), isEmpty);
    });

    test('si el almacenamiento la rechaza, queda para la proxima', () async {
      final punto = await unPunto();
      await unaFoto(punto);
      final s = sincronizador(almacen: 403);

      await s.sincronizar();

      expect(pedidos.where((p) => p.url.path.endsWith('/confirmar')), isEmpty);
      expect(s.state.error, contains('Una foto no subio'));
      expect(await archivos.contarPendientes(usuario).first, 1);

      // Y a la vuelta siguiente sube.
      final otra = sincronizador();
      await otra.sincronizar();
      expect(await archivos.contarPendientes(usuario).first, 0);
    });

    test(
      'una foto cuyo archivo ya no esta no queda pendiente para siempre',
      () async {
        final punto = await unPunto();
        final foto = await unaFoto(punto);
        await puntos.marcarSubido(punto.codigo);
        File(foto.rutaLocal).deleteSync();
        final s = sincronizador();

        await s.sincronizar();

        expect(pedidos, isEmpty);
        expect(await archivos.contarPendientes(usuario).first, 0);
        expect(s.state.error, isNull);
      },
    );
  });
}
