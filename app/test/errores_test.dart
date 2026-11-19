import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/api_client.dart';
import 'package:geomaps/core/errores.dart';
import 'package:geomaps/core/fuente_teselas.dart';
import 'package:geomaps/core/teselas.dart';
import 'package:geomaps/state/errores.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// El cuaderno de errores del telefono.
///
/// Lo que se pidio: enterarse de un fallo en el telefono de un conductor sin
/// que el conductor tenga que contarlo. Lo que se cuida aca es que anotar
/// errores no empeore nada: que no se pierdan sin senal, que un fallo que se
/// repite no llene el telefono, que los cortes de red no cuenten como fallos,
/// y que el cuaderno nunca sea el que falla.
void main() {
  late Directory carpeta;
  late File archivo;

  setUp(() {
    carpeta = Directory.systemTemp.createTempSync('geomaps-errores');
    archivo = File('${carpeta.path}/errores.json');
  });
  tearDown(() => carpeta.deleteSync(recursive: true));

  RegistroErrores abrir() => RegistroErrores(
    archivo,
    versionCode: 11,
    versionNombre: '0.2.7',
    sistema: 'OPPO CPH2637 · Android 14',
    reloj: () => DateTime.utc(2026, 11, 17, 15, 30),
  );

  StackTrace traza(String donde) =>
      StackTrace.fromString('#0 $donde\n#1 otra (lib/x.dart:9)\n#2 main');

  group('anotar', () {
    test('queda en el telefono, con la version y el modelo', () async {
      await abrir().anotar(
        StateError('la lista esta vacia'),
        traza('PanelRuta.build (lib/ui/capa_ruta.dart:201)'),
        donde: 'widgets library',
      );

      // Otro cuaderno sobre el mismo archivo: es la app que se cerro y volvio.
      final informes = await abrir().pendientes();
      expect(informes, hasLength(1));
      final i = informes.single;
      expect(i.mensaje, 'Bad state: la lista esta vacia');
      expect(i.traza, contains('capa_ruta.dart:201'));
      expect(i.donde, 'widgets library');
      expect(i.versionCode, 11);
      expect(i.versionNombre, '0.2.7');
      expect(i.sistema, 'OPPO CPH2637 · Android 14');
      expect(i.ocurrioEn, DateTime.utc(2026, 11, 17, 15, 30));
      expect(i.codigo, hasLength(36));
    });

    test('el mismo fallo repetido es una fila que cuenta', () async {
      // Una tarjeta que falla al dibujarse falla en cada cuadro.
      final registro = abrir();
      for (var n = 0; n < 60; n++) {
        await registro.anotar(
          StateError('la lista esta vacia'),
          traza('PanelRuta.build (lib/ui/capa_ruta.dart:201)'),
        );
      }

      final informes = await registro.pendientes();
      expect(informes, hasLength(1));
      expect(informes.single.veces, 60);
      // En el archivo queda la ultima potencia de dos: el numero exacto no
      // vale escribir el archivo sesenta veces por segundo.
      expect((await abrir().pendientes()).single.veces, 32);
    });

    test('dos fallos distintos son dos filas', () async {
      final registro = abrir();
      await registro.anotar(StateError('uno'), traza('a (lib/a.dart:1)'));
      await registro.anotar(StateError('uno'), traza('b (lib/b.dart:2)'));
      await registro.anotar(StateError('dos'), traza('a (lib/a.dart:1)'));

      expect(await registro.pendientes(), hasLength(3));
    });

    test('los cortes de red y las teselas que faltan no se anotan', () async {
      // Sin senal son miles por jornada y ninguno es un fallo de la app.
      final registro = abrir();
      for (final ruido in <Object>[
        const SocketException('Failed host lookup'),
        TimeoutException('tardo'),
        http.ClientException('Connection closed'),
        const HandshakeException(),
        const SinTesela(Tesela(18, 1, 2)),
      ]) {
        await registro.anotar(ruido, StackTrace.current);
      }

      expect(await registro.pendientes(), isEmpty);
      expect(archivo.existsSync(), isFalse);
    });

    test('con el cuaderno lleno se va el mas viejo', () async {
      final registro = abrir();
      for (var n = 0; n < RegistroErrores.maximo + 5; n++) {
        await registro.anotar(StateError('fallo $n'), null);
      }

      final informes = await registro.pendientes();
      expect(informes, hasLength(RegistroErrores.maximo));
      expect(informes.first.mensaje, 'Bad state: fallo 5');
      expect(informes.last.mensaje, 'Bad state: fallo 44');
    });

    test('una traza enorme se recorta a lo que acepta el servidor', () async {
      final registro = abrir();
      await registro.anotar(
        StateError('x' * 5000),
        StackTrace.fromString('#0 f (lib/a.dart:1)\n' * 2000),
      );

      final i = (await registro.pendientes()).single;
      expect(i.mensaje.length, lessThanOrEqualTo(2000));
      expect(i.traza!.length, lessThanOrEqualTo(8000));
    });

    test('un archivo roto no deja a la app sin poder anotar', () async {
      // Se fue la bateria a mitad de una escritura.
      archivo.writeAsStringSync('{"informes": [{"codigo": "a1"');

      final registro = abrir();
      expect(await registro.pendientes(), isEmpty);
      await registro.anotar(StateError('despues'), null);
      expect((await abrir().pendientes()).single.mensaje, contains('despues'));
    });

    test('nunca lanza, ni con el disco en contra', () async {
      // La "carpeta" del archivo es un archivo: no se puede escribir ahi.
      final imposible = File('${archivo.path}/adentro/errores.json');
      archivo.writeAsStringSync('ocupado');
      final registro = RegistroErrores(imposible);

      await registro.anotar(StateError('x'), null);
      await registro.quitar(['a']);
      await registro.vaciar();
    });

    test('varios a la vez no mezclan el archivo', () async {
      final registro = abrir();
      await Future.wait([
        for (var n = 0; n < 25; n++)
          registro.anotar(StateError('a la vez $n'), null),
      ]);

      expect(await abrir().pendientes(), hasLength(25));
    });
  });

  group('lo que avisa Flutter', () {
    test('un fallo al dibujar se anota con su contexto', () async {
      final registro = abrir();
      await anotarDeFlutter(
        registro,
        FlutterErrorDetails(
          exception: StateError('sin puntos'),
          stack: traza('PanelMedicion.build (lib/ui/medicion.dart:140)'),
          library: 'widgets library',
          context: ErrorDescription('building PanelMedicion'),
        ),
      );

      final i = (await registro.pendientes()).single;
      expect(i.donde, 'widgets library: building PanelMedicion');
    });

    test('una imagen que no cargo no es un fallo', () async {
      final registro = abrir();
      await anotarDeFlutter(
        registro,
        FlutterErrorDetails(
          exception: StateError('no se pudo decodificar'),
          library: 'image resource service',
        ),
      );
      await anotarDeFlutter(
        registro,
        FlutterErrorDetails(exception: StateError('menor'), silent: true),
      );

      expect(await registro.pendientes(), isEmpty);
    });
  });

  group('subir', () {
    ApiClient api(
      Future<http.Response> Function(http.Request pedido) servidor, {
      String? token = 'jwt',
    }) => ApiClient(cliente: MockClient(servidor))..token = token;

    test('sube lo pendiente y lo saca del telefono', () async {
      final registro = abrir();
      await registro.anotar(StateError('uno'), null);
      await registro.anotar(StateError('dos'), null);

      late Map<String, dynamic> cuerpo;
      await subirErrores(
        registro,
        api((pedido) async {
          expect(pedido.url.path, '/v1/errores');
          expect(pedido.headers['Authorization'], 'Bearer jwt');
          cuerpo = jsonDecode(pedido.body) as Map<String, dynamic>;
          final codigos = [
            for (final e in cuerpo['errores'] as List) (e as Map)['codigo'],
          ];
          return http.Response(jsonEncode({'recibidos': codigos}), 200);
        }),
      );

      final enviados = cuerpo['errores'] as List;
      expect(enviados, hasLength(2));
      expect((enviados.first as Map)['version_code'], 11);
      expect((enviados.first as Map)['ocurrio_en'], '2026-11-17T15:30:00.000Z');
      expect(await registro.pendientes(), isEmpty);
      expect(await abrir().pendientes(), isEmpty);
    });

    test('de a veinte, que es lo que acepta el servidor', () async {
      final registro = abrir();
      for (var n = 0; n < 35; n++) {
        await registro.anotar(StateError('fallo $n'), null);
      }

      final tandas = <int>[];
      await subirErrores(
        registro,
        api((pedido) async {
          final errores =
              (jsonDecode(pedido.body) as Map<String, dynamic>)['errores']
                  as List;
          tandas.add(errores.length);
          return http.Response(
            jsonEncode({
              'recibidos': [for (final e in errores) (e as Map)['codigo']],
            }),
            200,
          );
        }),
      );

      expect(tandas, [20, 15]);
      expect(await registro.pendientes(), isEmpty);
    });

    test('contra un servidor que todavia no los recibe, se quedan', () async {
      // El backend publicado puede ser anterior a este APK: responde 404, y
      // los informes esperan en el telefono a que se actualice.
      final registro = abrir();
      await registro.anotar(StateError('espera'), null);

      await subirErrores(
        registro,
        api((_) async => http.Response('{"detail":"Not Found"}', 404)),
      );

      expect(await registro.pendientes(), hasLength(1));
    });

    test('sin senal no falla y no pierde nada', () async {
      final registro = abrir();
      await registro.anotar(StateError('espera'), null);

      await subirErrores(
        registro,
        api((_) async => throw const SocketException('sin red')),
      );

      expect(await registro.pendientes(), hasLength(1));
    });

    test('sin sesion ni llama: no hay a nombre de quien subir', () async {
      final registro = abrir();
      await registro.anotar(StateError('espera'), null);
      var llamadas = 0;

      await subirErrores(
        registro,
        api((_) async {
          llamadas++;
          return http.Response('{}', 200);
        }, token: null),
      );
      await subirErrores(null, api((_) async => http.Response('{}', 200)));

      expect(llamadas, 0);
      expect(await registro.pendientes(), hasLength(1));
    });

    test('solo se borra lo que el servidor dijo que recibio', () async {
      final registro = abrir();
      await registro.anotar(StateError('uno'), null);
      await registro.anotar(StateError('dos'), null);
      final primero = (await registro.pendientes()).first.codigo;

      await subirErrores(
        registro,
        api(
          (_) async => http.Response(
            jsonEncode({
              'recibidos': [primero],
            }),
            200,
          ),
        ),
      );

      final quedan = await registro.pendientes();
      expect(quedan.single.mensaje, contains('dos'));
    });
  });
}
