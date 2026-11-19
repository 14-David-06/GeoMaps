import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/fuente_teselas.dart';
import 'package:geomaps/core/teselas.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// El mapa base cuando no hay imagen del nivel que se pide.
///
/// El satelite, donde no tiene imagen, responde 200 con un cartel que dice
/// "Map data not yet available". En Guaicaramo pasa en cuanto se acerca el
/// mapa mas alla del nivel 18. Lo que se prueba es que ese cartel no se
/// muestre ni se guarde nunca, y que en su lugar salga la imagen del nivel de
/// arriba.
void main() {
  const plantilla = 'https://sat/tile/{z}/{y}/{x}';
  const etagRelleno = '"vvvvvvvvvvvvf"';

  // Una tesela del nivel 19 y su madre del 18.
  const hija = Tesela(19, 155858, 255591);
  const madre = Tesela(18, 77929, 127795);

  Uint8List imagen(int marca) => Uint8List.fromList(List.filled(64, marca));
  final relleno = Uint8List.fromList(List.filled(2521, 7));

  group('el cartel', () {
    test('se reconoce por su ETag, que es el mismo en todo el mundo', () {
      expect(esRellenoEsri(relleno, etag: etagRelleno), isTrue);
      expect(esRellenoEsri(imagen(1), etag: etagRelleno), isTrue);
    });

    test('una imagen de verdad no se confunde, aunque pese lo mismo', () {
      expect(esRellenoEsri(imagen(1), etag: '"4k2f4tvvf2evf"'), isFalse);
      // Mismo largo que el cartel, otro contenido: la huella no coincide.
      expect(esRellenoEsri(relleno), isFalse);
      expect(esRellenoEsri(imagen(1)), isFalse);
    });
  });

  group('el recorte', () {
    test('la madre de una tesela es la que la contiene', () {
      expect(hija.ancestro(1), madre);
      expect(hija.ancestro(0), hija);
      expect(const Tesela(2, 3, 1).ancestro(9), const Tesela(0, 0, 0));
    });

    test('un nivel arriba es un cuarto de la imagen', () {
      // (5,7) dentro de (2,3): columna impar y fila impar, abajo a la derecha.
      const t = Tesela(19, 5, 7);
      expect(t.recorteEn(const Tesela(18, 2, 3)), (128.0, 128.0, 128.0));
      expect(const Tesela(19, 4, 6).recorteEn(const Tesela(18, 2, 3)), (
        0.0,
        0.0,
        128.0,
      ));
    });

    test('dos niveles arriba es un dieciseisavo', () {
      const t = Tesela(19, 5, 7);
      expect(t.recorteEn(const Tesela(17, 1, 1)), (64.0, 192.0, 64.0));
    });

    test('sobre si misma es la imagen entera', () {
      expect(hija.recorteEn(hija), (0.0, 0.0, 256.0));
    });
  });

  group('la fuente', () {
    late _CacheFalsa cache;
    late List<String> pedidos;
    late List<http.Request> cabeceras;
    late DateTime ahora;

    /// Un servidor que tiene imagen hasta el nivel [hasta] y de ahi en mas
    /// manda el cartel, como el satelite.
    FuenteTeselas fuente({int hasta = 18, bool sinRed = false, int? estado}) {
      return FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        reloj: () => ahora,
        cliente: MockClient((pedido) async {
          pedidos.add(pedido.url.path);
          cabeceras.add(pedido);
          if (sinRed) throw const SocketException('sin red');
          if (estado != null) return http.Response('', estado);
          final z = int.parse(pedido.url.pathSegments[1]);
          return z <= hasta
              ? http.Response.bytes(imagen(z), 200, headers: {'etag': '"$z"'})
              : http.Response.bytes(
                  relleno,
                  200,
                  headers: {'etag': etagRelleno},
                );
        }),
      );
    }

    setUp(() {
      cache = _CacheFalsa();
      pedidos = [];
      cabeceras = [];
      ahora = DateTime(2026, 11, 18, 9);
    });

    /// Un servidor que no contesta hasta que la prueba lo decide: asi es una
    /// raya de senal, donde el pedido no falla, se queda colgado.
    (FuenteTeselas, List<Completer<http.Response>>) fuenteColgada() {
      final enVuelo = <Completer<http.Response>>[];
      final f = FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        reloj: () => ahora,
        cliente: MockClient((pedido) {
          pedidos.add(pedido.url.path);
          final respuesta = Completer<http.Response>();
          enVuelo.add(respuesta);
          return respuesta.future;
        }),
      );
      return (f, enVuelo);
    }

    http.Response con(int marca) =>
        http.Response.bytes(imagen(marca), 200, headers: {'etag': '"$marca"'});

    test('donde hay imagen, entrega la pedida y la guarda', () async {
      final r = await fuente().cargar(madre);

      expect(r.origen, madre);
      expect(r.bytes, imagen(18));
      expect(r.provisional, isFalse);
      await pumpEventQueue();
      expect(cache.guardadas.keys, [madre.url(plantilla)]);
    });

    test('donde manda el cartel, entrega la del nivel de arriba', () async {
      final r = await fuente().cargar(hija);

      expect(r.origen, madre, reason: 'la imagen es la del nivel 18');
      expect(r.bytes, imagen(18));
      expect(r.provisional, isFalse, reason: 'se sabe que no existe');
      await pumpEventQueue();
      expect(cache.guardadas.keys, [
        madre.url(plantilla),
      ], reason: 'el cartel no se guarda nunca');
    });

    test('sube varios niveles si hace falta', () async {
      const nieta = Tesela(21, 155858 * 4, 255591 * 4);
      final r = await fuente().cargar(nieta);
      expect(r.origen, madre);
    });

    test('no vuelve a preguntar por lo que ya sabe que falta', () async {
      final f = fuente();
      await f.cargar(hija);
      final antes = pedidos.length;

      await f.cargar(hija);
      // Y una tesela que cae adentro de la que falta tampoco se pregunta.
      await f.cargar(Tesela(20, hija.x * 2, hija.y * 2));

      expect(pedidos.length, antes);
    });

    test(
      'cuando un nivel viene faltando en la zona, deja de pedirlo',
      () async {
        final f = fuente();
        // Cinco vecinas del nivel 19, todas sin imagen.
        for (var i = 0; i < 5; i++) {
          await f.cargar(Tesela(19, hija.x + i, hija.y));
        }
        final antes = pedidos.where((p) => p.startsWith('/tile/19/')).length;

        for (var i = 5; i < 12; i++) {
          await f.cargar(Tesela(19, hija.x + i, hija.y));
        }

        expect(
          pedidos.where((p) => p.startsWith('/tile/19/')).length,
          antes,
          reason: 'las siguientes del mismo nivel y zona ya no se piden',
        );
      },
    );

    test('un cartel guardado de antes tambien se reconoce', () async {
      // El telefono que ya miro esta zona con la version anterior.
      cache.poner(hija.url(plantilla), relleno, etag: etagRelleno);
      cache.poner(madre.url(plantilla), imagen(18));

      final r = await fuente(sinRed: true).cargar(hija);

      expect(r.origen, madre);
      expect(r.provisional, isFalse);
      expect(pedidos, isEmpty, reason: 'todo salio de lo guardado');
    });

    test(
      'sin senal muestra lo guardado de mas arriba, y lo reintenta',
      () async {
        const abuela = Tesela(17, 38964, 63897);
        cache.poner(abuela.url(plantilla), imagen(17));
        final f = fuente(sinRed: true);

        final r = await f.cargar(madre);

        expect(r.origen, abuela);
        expect(r.provisional, isTrue, reason: 'no se pudo preguntar por ella');
        expect(
          f.fueProvisional(madre),
          isFalse,
          reason:
              'con la red cortada no se rehace la misma imagen borrosa '
              'que ya se esta viendo',
        );

        ahora = ahora.add(
          FuenteTeselas.pausaSinRed + const Duration(seconds: 1),
        );
        expect(f.fueProvisional(madre), isTrue, reason: 'paso la pausa');
        expect(f.fueProvisional(madre), isFalse, reason: 'se consulta una vez');
      },
    );

    test('sin senal no insiste con la red en cada tesela', () async {
      final f = fuente(sinRed: true);
      await expectLater(f.cargar(madre), throwsA(isA<SinTesela>()));
      final antes = pedidos.length;

      await expectLater(
        f.cargar(const Tesela(18, 77930, 127795)),
        throwsA(isA<SinTesela>()),
      );

      expect(antes, 1, reason: 'el primer fallo corta los intentos');
      expect(pedidos.length, antes);
    });

    test('una copia vencida sirve cuando no hay red', () async {
      cache.poner(madre.url(plantilla), imagen(18), vencida: true);

      final r = await fuente(sinRed: true).cargar(madre);

      expect(r.origen, madre);
      expect(r.bytes, imagen(18));
      expect(r.provisional, isFalse);
    });

    test('un 404 es que no hay imagen; un 503 es que no se sabe', () async {
      cache.poner(madre.url(plantilla), imagen(18));

      final con404 = await fuente(estado: 404).cargar(hija);
      expect(con404.origen, madre);
      expect(con404.provisional, isFalse);

      final con503 = await fuente(estado: 503).cargar(hija);
      expect(con503.origen, madre);
      expect(con503.provisional, isTrue);
    });

    // Con una raya de senal un pedido no falla: se queda colgado. Antes el
    // mapa esperaba a la red antes de mostrar la copia que ya tenia, y cada
    // imagen tardaba quince segundos en aparecer.
    group('lo guardado primero, sin esperar a la red', () {
      test('una copia vencida se entrega en el acto', () async {
        cache.poner(madre.url(plantilla), imagen(18), vencida: true);

        final r = await fuente().guardada(madre);

        expect(r!.origen, madre);
        expect(r.bytes, imagen(18));
        expect(r.provisional, isTrue, reason: 'vale la pena renovarla');
        expect(pedidos, isEmpty);
      });

      test('sin la pedida, entrega la de mas arriba', () async {
        const abuela = Tesela(17, 38964, 63897);
        cache.poner(abuela.url(plantilla), imagen(17));

        final r = await fuente().guardada(madre);

        expect(r!.origen, abuela);
        expect(r.provisional, isTrue, reason: 'no se sabe si la pedida existe');
        expect(pedidos, isEmpty);
      });

      test('si la pedida no existe, la de arriba ya es la respuesta', () async {
        cache.poner(hija.url(plantilla), relleno, etag: etagRelleno);
        cache.poner(madre.url(plantilla), imagen(18));

        final r = await fuente().guardada(hija);

        expect(r!.origen, madre);
        expect(r.provisional, isFalse, reason: 'no hay nada que preguntar');
        expect(pedidos, isEmpty);
      });

      test('sin nada guardado lo dice, tambien en el acto', () async {
        expect(await fuente().guardada(madre), isNull);
        expect(pedidos, isEmpty);
      });

      test('no espera a un servidor que no contesta', () async {
        const abuela = Tesela(17, 38964, 63897);
        cache.poner(abuela.url(plantilla), imagen(17));
        final (f, enVuelo) = fuenteColgada();

        // La red sale a buscar la de verdad y se queda colgada...
        final deLaRed = f.cargar(madre);
        // ...y lo guardado contesta igual.
        final local = await f.guardada(madre);
        expect(local!.origen, abuela);
        await pumpEventQueue();
        expect(enVuelo, hasLength(1), reason: 'el pedido sigue en el aire');

        // Cuando por fin llega, es la buena.
        enVuelo.single.complete(con(18));
        final r = await deLaRed;
        expect(r.origen, madre);
        expect(r.provisional, isFalse);
      });

      test('las hijas de una misma madre la leen del disco una vez', () async {
        cache.poner(madre.url(plantilla), imagen(18));
        final f = fuente(sinRed: true);

        // Las cuatro hijas de la madre: dos columnas por dos filas.
        for (var i = 0; i < 4; i++) {
          final r = await f.guardada(
            Tesela(19, madre.x * 2 + (i % 2), madre.y * 2 + i ~/ 2),
          );
          expect(r!.origen, madre);
        }

        expect(
          cache.lecturas.where((u) => u == madre.url(plantilla)),
          hasLength(1),
        );
      });
    });

    group('la red se cuida', () {
      test('una copia vencida se renueva preguntando si cambio', () async {
        cache.poner(
          madre.url(plantilla),
          imagen(18),
          etag: '"18"',
          vencida: true,
        );
        final f = FuenteTeselas(
          plantilla: plantilla,
          paquete: 'prueba',
          almacen: () => cache,
          cliente: MockClient((pedido) async {
            cabeceras.add(pedido);
            // No cambio: el servidor no la vuelve a mandar.
            return pedido.headers['If-None-Match'] == '"18"'
                ? http.Response('', 304)
                : con(99);
          }),
        );

        final r = await f.cargar(madre);

        expect(cabeceras.single.headers['If-None-Match'], '"18"');
        expect(r.bytes, imagen(18), reason: 'la misma que ya tenia');
        expect(r.provisional, isFalse);
        await pumpEventQueue();
        final guardada = cache.guardadas[madre.url(plantilla)]!;
        expect(guardada.metadata.isStale, isFalse, reason: 'vale otra vez');
        expect(guardada.bytes, imagen(18));
      });

      test('mientras sigue sin red, espera cada vez mas', () async {
        final f = fuente(sinRed: true);
        Future<void> pedir(int i) => expectLater(
          f.cargar(Tesela(18, madre.x + i, madre.y)),
          throwsA(isA<SinTesela>()),
        );
        void pasan(int segundos) =>
            ahora = ahora.add(Duration(seconds: segundos));

        await pedir(0);
        expect(pedidos, hasLength(1));

        // Paso la primera pausa (20 s): sale a probar, y sigue sin red.
        pasan(21);
        await pedir(1);
        expect(pedidos, hasLength(2));

        // La segunda pausa es el doble: a los 21 s todavia no prueba.
        pasan(21);
        await pedir(2);
        expect(pedidos, hasLength(2));

        pasan(20);
        await pedir(3);
        expect(pedidos, hasLength(3));
      });

      test('vencida la pausa sale uno solo a probar', () async {
        final (f, enVuelo) = fuenteColgada();
        // Un primer pedido que falla corta la red.
        final primero = expectLater(f.cargar(madre), throwsA(isA<SinTesela>()));
        await pumpEventQueue();
        enVuelo.single.completeError(const SocketException('sin red'));
        await primero;
        ahora = ahora.add(const Duration(seconds: 21));
        enVuelo.clear();

        // Cinco teselas a la vez: no salen cinco pedidos a colgarse.
        final cargas = [
          for (var i = 1; i <= 5; i++)
            expectLater(
              f.cargar(Tesela(18, madre.x + i, madre.y)),
              throwsA(isA<SinTesela>()),
            ),
        ];
        await pumpEventQueue();
        expect(enVuelo, hasLength(1), reason: 'uno prueba, los demas esperan');

        // El que probo falla: los demas no salen a comprobarlo de nuevo.
        enVuelo.single.completeError(const SocketException('sin red'));
        await Future.wait(cargas);
        expect(enVuelo, hasLength(1));
      });

      test('si el que probo consigue respuesta, salen los demas', () async {
        final (f, enVuelo) = fuenteColgada();
        final primero = expectLater(f.cargar(madre), throwsA(isA<SinTesela>()));
        await pumpEventQueue();
        enVuelo.single.completeError(const SocketException('sin red'));
        await primero;
        ahora = ahora.add(const Duration(seconds: 21));
        enVuelo.clear();

        final cargas = [
          for (var i = 1; i <= 3; i++)
            f.cargar(Tesela(18, madre.x + i, madre.y)),
        ];
        await pumpEventQueue();
        expect(enVuelo, hasLength(1));

        enVuelo.single.complete(con(18));
        await pumpEventQueue();
        expect(enVuelo, hasLength(3), reason: 'los otros dos ya salieron');
        enVuelo[1].complete(con(18));
        enVuelo[2].complete(con(18));

        for (final r in await Future.wait(cargas)) {
          expect(r.provisional, isFalse);
        }
      });

      test('no salen mas de seis pedidos a la vez', () async {
        final (f, enVuelo) = fuenteColgada();

        final cargas = [
          for (var i = 0; i < 20; i++)
            f.cargar(Tesela(18, madre.x + i, madre.y)),
        ];
        await pumpEventQueue();
        expect(enVuelo, hasLength(FuenteTeselas.enParalelo));

        // A medida que contestan, entran los que esperaban.
        var contestados = 0;
        while (contestados < 20) {
          expect(
            enVuelo.length - contestados,
            lessThanOrEqualTo(FuenteTeselas.enParalelo),
          );
          enVuelo[contestados++].complete(con(18));
          await pumpEventQueue();
        }

        expect(await Future.wait(cargas), hasLength(20));
        expect(enVuelo, hasLength(20));
      });

      test('moviendo el mapa rapido, lo que quedo atras no se baja', () async {
        final (f, enVuelo) = fuenteColgada();
        // Cien teselas pedidas de corrido, con la red lenta.
        final cargas = [
          for (var i = 0; i < 100; i++)
            f
                .cargar(Tesela(18, madre.x + i, madre.y))
                .then<TeselaCargada?>((r) => r, onError: (Object _) => null),
        ];
        await pumpEventQueue();
        expect(enVuelo, hasLength(FuenteTeselas.enParalelo));

        // Se van contestando todos los que lleguen a salir.
        var contestados = 0;
        while (contestados < enVuelo.length) {
          enVuelo[contestados++].complete(con(18));
          await pumpEventQueue();
        }
        final resultados = await Future.wait(cargas);

        // Seis salieron de entrada y 48 esperaron turno; el resto no se pidio,
        // ni la suya ni la de mas arriba.
        expect(enVuelo, hasLength(54));
        expect(resultados.whereType<TeselaCargada>(), hasLength(54));
        // Las ultimas pedidas -lo que se esta mirando- si se bajaron...
        expect(
          pedidos,
          contains(
            Tesela(
              18,
              madre.x + 99,
              madre.y,
            ).url(plantilla).substring('https://sat'.length),
          ),
        );
        // ...y las que se quedaron sin turno quedan anotadas para despues.
        expect(f.quedoPendiente(Tesela(18, madre.x + 10, madre.y)), isTrue);
      });

      test(
        'si un pedido corta la red, los que esperaban turno no salen',
        () async {
          final (f, enVuelo) = fuenteColgada();
          final cargas = [
            for (var i = 0; i < 20; i++)
              expectLater(
                f.cargar(Tesela(18, madre.x + i, madre.y)),
                throwsA(isA<SinTesela>()),
              ),
          ];
          await pumpEventQueue();

          for (final pedido in List.of(enVuelo)) {
            pedido.completeError(const SocketException('sin red'));
          }
          await Future.wait(cargas);

          expect(
            enVuelo,
            hasLength(FuenteTeselas.enParalelo),
            reason: 'los catorce que esperaban no llegaron a pedir nada',
          );
        },
      );

      test('avisa a quien quedo esperando, una vez, cuando vuelve', () async {
        final f = fuente(sinRed: true);
        await expectLater(f.cargar(madre), throwsA(isA<SinTesela>()));
        expect(f.quedoPendiente(madre), isTrue);

        var avisos = 0;
        f.avisarAlVolver(madre, () => avisos++);
        await pumpEventQueue();
        expect(avisos, 0, reason: 'todavia no volvio');

        f.reanudar();
        await pumpEventQueue();
        expect(avisos, 1);

        f.reanudar();
        await pumpEventQueue();
        expect(avisos, 1, reason: 'quien sigue esperando se vuelve a anotar');
      });

      test(
        'si un pedido consigue respuesta despues del corte, tambien avisa',
        () async {
          // El telefono no siempre dice que volvio la red: a veces solo vuelve.
          final (f, enVuelo) = fuenteColgada();
          final primero = expectLater(
            f.cargar(madre),
            throwsA(isA<SinTesela>()),
          );
          await pumpEventQueue();
          enVuelo.single.completeError(const SocketException('sin red'));
          await primero;

          var avisos = 0;
          f.avisarAlVolver(madre, () => avisos++);
          ahora = ahora.add(const Duration(seconds: 21));
          enVuelo.clear();

          final otra = f.cargar(Tesela(18, madre.x + 1, madre.y));
          await pumpEventQueue();
          enVuelo.single.complete(con(18));
          await otra;
          await pumpEventQueue();

          expect(avisos, 1);
        },
      );

      test('cuando el telefono avisa que volvio la red, no espera', () async {
        final f = fuente(sinRed: true);
        await expectLater(f.cargar(madre), throwsA(isA<SinTesela>()));
        expect(pedidos, hasLength(1));

        f.reanudar();
        await expectLater(
          f.cargar(Tesela(18, madre.x + 1, madre.y)),
          throwsA(isA<SinTesela>()),
        );

        expect(pedidos, hasLength(2), reason: 'salio sin esperar la pausa');
      });
    });
  });
}

/// Lo minimo de la cache de `flutter_map`: un mapa en memoria.
class _CacheFalsa implements MapCachingProvider {
  final guardadas = <String, CachedMapTile>{};

  /// Cada lectura, con su direccion: para contar las que van al disco.
  final lecturas = <String>[];

  void poner(
    String url,
    Uint8List bytes, {
    String? etag,
    bool vencida = false,
  }) {
    guardadas[url] = (
      bytes: bytes,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.timestamp().add(
          vencida ? const Duration(days: -1) : const Duration(days: 30),
        ),
        lastModified: null,
        etag: etag,
      ),
    );
  }

  @override
  bool get isSupported => true;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    lecturas.add(url);
    return guardadas[url];
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    // Sin bytes es "la misma imagen, con otra fecha": como la cache de verdad.
    final imagen = bytes ?? guardadas[url]?.bytes;
    if (imagen != null) guardadas[url] = (bytes: imagen, metadata: metadata);
  }
}
