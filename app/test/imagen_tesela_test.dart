import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/fuente_teselas.dart';
import 'package:geomaps/core/teselas.dart';
import 'package:geomaps/ui/proveedor_teselas.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Como se dibuja una imagen del mapa: primero lo guardado, despues la red.
///
/// Es lo que hace que el mapa abra igual de rapido con senal que sin ella. Lo
/// que se prueba es el orden -que lo que ya esta en el telefono aparezca sin
/// esperar a un servidor que no contesta- y que la imagen de la red, cuando
/// por fin llega, reemplace a la borrosa sin que nadie la vuelva a pedir.
void main() {
  const plantilla = 'https://sat/tile/{z}/{y}/{x}';
  const madre = Tesela(18, 77929, 127795);
  const abuela = Tesela(17, 38964, 63897);

  const verde = ui.Color(0xFF00FF00);
  const rojo = ui.Color(0xFFFF0000);

  /// Un PNG de 256 x 256 de un solo color: una tesela de mentira que se puede
  /// decodificar de verdad.
  Future<Uint8List> png(ui.Color color) async {
    final grabadora = ui.PictureRecorder();
    ui.Canvas(grabadora).drawRect(
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..color = color,
    );
    final dibujo = grabadora.endRecording();
    final imagen = await dibujo.toImage(256, 256);
    final datos = await imagen.toByteData(format: ui.ImageByteFormat.png);
    imagen.dispose();
    dibujo.dispose();
    return datos!.buffer.asUint8List();
  }

  Future<ui.Color> colorDe(ui.Image imagen) async {
    final datos = await imagen.toByteData(format: ui.ImageByteFormat.rawRgba);
    final p = datos!.buffer.asUint8List();
    // El del medio: lejos de los bordes, donde el suavizado mezcla.
    final i = (128 * imagen.width + 128) * 4;
    return ui.Color.fromARGB(p[i + 3], p[i], p[i + 1], p[i + 2]);
  }

  /// Espera a que [listo] se cumpla, con tope: decodificar es trabajo de
  /// verdad y tarda lo que tarda.
  Future<void> hasta(bool Function() listo, String que) async {
    for (var i = 0; i < 300 && !listo(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(listo(), isTrue, reason: 'nunca paso: $que');
  }

  late _Cache cache;

  setUp(() {
    cache = _Cache();
    PaintingBinding.instance.imageCache.clear();
  });

  testWidgets('con senal mala: primero la guardada, despues la de la red', (
    tester,
  ) async {
    await tester.runAsync(() async {
      cache.poner(abuela.url(plantilla), await png(verde));
      final nitida = await png(rojo);

      // El servidor no contesta hasta que la prueba lo decide.
      final enVuelo = <Completer<http.Response>>[];
      final fuente = FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        cliente: MockClient((_) {
          final respuesta = Completer<http.Response>();
          enVuelo.add(respuesta);
          return respuesta.future;
        }),
      );

      final cuadros = <ui.Image>[];
      final errores = <Object>[];
      ImagenTesela(madre, fuente)
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener(
              (info, _) => cuadros.add(info.image),
              onError: (e, _) => errores.add(e),
            ),
          );

      // Aparece la de mas arriba, con el pedido todavia en el aire.
      await hasta(() => cuadros.length == 1, 'la imagen guardada');
      await hasta(() => enVuelo.length == 1, 'el pedido a la red');
      expect(await colorDe(cuadros.first), verde);
      expect(enVuelo.single.isCompleted, isFalse);

      // Llega la de verdad y reemplaza a la borrosa, sin que nadie la pida
      // otra vez.
      enVuelo.single.complete(http.Response.bytes(nitida, 200));
      await hasta(() => cuadros.length == 2, 'la imagen de la red');
      expect(await colorDe(cuadros.last), rojo);
      expect(errores, isEmpty);
      expect(fuente.fueProvisional(madre), isFalse, reason: 'ya es la buena');
    });
  });

  testWidgets(
    'sin senal: lo guardado se ve, y no hay error ni segunda vuelta',
    (tester) async {
      await tester.runAsync(() async {
        cache.poner(abuela.url(plantilla), await png(verde));
        var pedidos = 0;
        final fuente = FuenteTeselas(
          plantilla: plantilla,
          paquete: 'prueba',
          almacen: () => cache,
          cliente: MockClient((_) async {
            pedidos++;
            throw const SocketException('sin red');
          }),
        );

        final cuadros = <ui.Image>[];
        final errores = <Object>[];
        ImagenTesela(madre, fuente)
            .resolve(ImageConfiguration.empty)
            .addListener(
              ImageStreamListener(
                (info, _) => cuadros.add(info.image),
                onError: (e, _) => errores.add(e),
              ),
            );

        await hasta(() => cuadros.isNotEmpty && pedidos == 1, 'el intento');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(cuadros, hasLength(1), reason: 'no se redibuja la misma imagen');
        expect(await colorDe(cuadros.single), verde);
        expect(errores, isEmpty, reason: 'ya se esta viendo algo');
      });
    },
  );

  testWidgets('cuando vuelve la senal, lo borroso se aclara solo', (
    tester,
  ) async {
    // Nadie mueve el mapa: la imagen que ya esta en pantalla es la que cambia.
    await tester.runAsync(() async {
      cache.poner(abuela.url(plantilla), await png(verde));
      final nitida = await png(rojo);
      var hayRed = false;
      final fuente = FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        cliente: MockClient((_) async {
          if (!hayRed) throw const SocketException('sin red');
          return http.Response.bytes(nitida, 200);
        }),
      );

      final cuadros = <ui.Image>[];
      ImagenTesela(madre, fuente)
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener((info, _) => cuadros.add(info.image)),
          );

      await hasta(() => cuadros.length == 1, 'la imagen guardada');
      await hasta(() => fuente.quedoPendiente(madre), 'el intento sin red');
      expect(await colorDe(cuadros.single), verde);

      hayRed = true;
      fuente.reanudar();

      await hasta(() => cuadros.length == 2, 'la imagen de la red');
      expect(await colorDe(cuadros.last), rojo);
    });
  });

  testWidgets(
    'una imagen que ya no esta en pantalla no gasta datos al volver',
    (tester) async {
      await tester.runAsync(() async {
        cache.poner(abuela.url(plantilla), await png(verde));
        var pedidos = 0;
        var hayRed = false;
        final fuente = FuenteTeselas(
          plantilla: plantilla,
          paquete: 'prueba',
          almacen: () => cache,
          cliente: MockClient((_) async {
            pedidos++;
            if (!hayRed) throw const SocketException('sin red');
            return http.Response.bytes(await png(rojo), 200);
          }),
        );

        final cuadros = <ui.Image>[];
        final oyente = ImageStreamListener(
          (info, _) => cuadros.add(info.image),
        );
        final flujo = ImagenTesela(
          madre,
          fuente,
        ).resolve(ImageConfiguration.empty)..addListener(oyente);
        await hasta(() => cuadros.length == 1 && pedidos == 1, 'el intento');

        // El mapa se movio: esa tesela ya no se mira.
        flujo.removeListener(oyente);
        hayRed = true;
        fuente.reanudar();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(pedidos, 1, reason: 'no salio a buscarla');
        expect(cuadros, hasLength(1));
      });
    },
  );

  testWidgets('una copia vigente no sale a la red para nada', (tester) async {
    await tester.runAsync(() async {
      cache.poner(madre.url(plantilla), await png(rojo));
      var pedidos = 0;
      final fuente = FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        cliente: MockClient((_) async {
          pedidos++;
          return http.Response('', 500);
        }),
      );

      final cuadros = <ui.Image>[];
      ImagenTesela(madre, fuente)
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener((info, _) => cuadros.add(info.image)),
          );

      await hasta(() => cuadros.isNotEmpty, 'la imagen guardada');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(await colorDe(cuadros.single), rojo);
      expect(pedidos, 0);
    });
  });

  testWidgets('sin senal y sin nada guardado, avisa el error y nada mas', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fuente = FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        cliente: MockClient((_) async => throw const SocketException('x')),
      );

      final cuadros = <ui.Image>[];
      final errores = <Object>[];
      ImagenTesela(madre, fuente)
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener(
              (info, _) => cuadros.add(info.image),
              onError: (e, _) => errores.add(e),
            ),
          );

      await hasta(() => errores.isNotEmpty, 'el error');
      expect(errores.single, isA<SinTesela>());
      expect(cuadros, isEmpty);
    });
  });

  testWidgets('las cuatro hijas de una madre guardada salen las cuatro', (
    tester,
  ) async {
    // La madre se decodifica una vez y se comparte: que compartirla no deje a
    // ninguna hija sin imagen.
    await tester.runAsync(() async {
      cache.poner(madre.url(plantilla), await png(verde));
      final fuente = FuenteTeselas(
        plantilla: plantilla,
        paquete: 'prueba',
        almacen: () => cache,
        cliente: MockClient((_) async => throw const SocketException('x')),
      );

      final cuadros = <ui.Image>[];
      for (var i = 0; i < 4; i++) {
        ImagenTesela(
              Tesela(19, madre.x * 2 + (i % 2), madre.y * 2 + i ~/ 2),
              fuente,
            )
            .resolve(ImageConfiguration.empty)
            .addListener(
              ImageStreamListener((info, _) => cuadros.add(info.image)),
            );
      }

      await hasta(() => cuadros.length == 4, 'las cuatro hijas');
      for (final cuadro in cuadros) {
        expect(await colorDe(cuadro), verde);
        expect(cuadro.width, 256);
      }
    });
  });
}

/// Lo minimo de la cache de `flutter_map`: un mapa en memoria.
class _Cache implements MapCachingProvider {
  final guardadas = <String, CachedMapTile>{};

  void poner(String url, Uint8List bytes) {
    guardadas[url] = (
      bytes: bytes,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.timestamp().add(const Duration(days: 30)),
        lastModified: null,
        etag: null,
      ),
    );
  }

  @override
  bool get isSupported => true;

  @override
  Future<CachedMapTile?> getTile(String url) async => guardadas[url];

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    final imagen = bytes ?? guardadas[url]?.bytes;
    if (imagen != null) guardadas[url] = (bytes: imagen, metadata: metadata);
  }
}
