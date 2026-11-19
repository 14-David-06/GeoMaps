import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/detalle_plano.dart';
import 'package:geomaps/ui/capa_pdf.dart';
import 'package:latlong2/latlong.dart';

/// Como se apoya un plano importado sobre el mapa.
void main() {
  /// Un plano de hoja acostada: la esquina de arriba-izquierda de la imagen es
  /// el suroeste del terreno. Asi salen los PDF con la pagina girada.
  const acostado = PlanoEnMapa(
    codigo: 'p1',
    nombre: 'Vias',
    ruta: '/no/existe.png',
    esquinas: [
      LatLng(4.20, -73.10),
      LatLng(4.60, -73.10),
      LatLng(4.60, -72.90),
      LatLng(4.20, -72.90),
    ],
    opacidad: 0.7,
  );

  testWidgets('el giro se aplica al dibujar, no en una capa aparte', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final contexto = tester.element(find.byType(SizedBox));

    final capa =
        const CapaPdf(planos: [acostado]).build(contexto) as OverlayImageLayer;
    final imagen = capa.overlayImages.single as RotatedOverlayImage;

    // Con filtro en la transformacion, Flutter guarda la imagen en una capa
    // recortada a la pantalla **antes** de girarla. En un plano girado 90
    // grados eso es otro pedazo de la imagen, y al acercar el mapa el plano
    // desaparece. Se vio en el telefono; que no vuelva por un valor por
    // defecto de la libreria.
    expect(imagen.transformFilterQuality, isNull);

    // Las esquinas se pasan en el orden de la imagen, no del terreno.
    expect(imagen.topLeftCorner, acostado.esquinas[0]);
    expect(imagen.bottomRightCorner, acostado.esquinas[2]);
    expect(imagen.bottomLeftCorner, acostado.esquinas[3]);
    expect(imagen.opacity, 0.7);
  });

  testWidgets('sin planos no dibuja nada', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final contexto = tester.element(find.byType(SizedBox));
    expect(const CapaPdf(planos: []).build(contexto), isA<SizedBox>());
  });

  group('una hoja grande, con detalle', () {
    // Un PNG de un pixel: lo que importa aca es donde se pone cada imagen,
    // no lo que tiene adentro.
    final unPixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
      'hwGA60e6kgAAAABJRU5ErkJggg==',
    );

    late Directory carpeta;
    setUp(() => carpeta = Directory.systemTemp.createTempSync('capa_pdf_'));
    tearDown(() {
      try {
        carpeta.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows a veces tarda en soltar un archivo recien leido.
      }
    });

    /// Un plano de unos 22 km de lado con el detalle a medio hacer: estan
    /// los cuadros de la mitad de arriba, y los de abajo todavia no.
    PlanoEnMapa grande() {
      final ruta = '${carpeta.path}/hoja.png';
      File(ruta).writeAsBytesSync(unPixel);
      var detalle = const DetallePlano(
        anchoVista: 4096,
        altoVista: 4096,
        ancho: 8192,
        alto: 8192,
      );
      Directory(DetallePlano.carpetaDe(ruta)).createSync();
      for (var i = 0; i < detalle.total ~/ 2; i++) {
        File(detalle.archivoDe(ruta, i)).writeAsBytesSync(unPixel);
        detalle = detalle.conListo(i);
      }
      return PlanoEnMapa(
        codigo: 'hoja',
        nombre: 'Vias del Meta',
        ruta: ruta,
        esquinas: const [
          LatLng(4.60, -73.10),
          LatLng(4.60, -72.90),
          LatLng(4.40, -72.90),
          LatLng(4.40, -73.10),
        ],
        opacidad: 0.8,
        detalle: detalle,
      );
    }

    Future<MapController> abrir(
      WidgetTester tester,
      List<PlanoEnMapa> planos,
    ) async {
      final mapa = MapController();
      await tester.pumpWidget(
        MaterialApp(
          home: FlutterMap(
            mapController: mapa,
            options: const MapOptions(
              initialCenter: LatLng(4.55, -73.0),
              initialZoom: 9,
            ),
            children: [CapaPdf(planos: planos)],
          ),
        ),
      );
      await tester.pump();
      return mapa;
    }

    /// Deja que se abran de verdad las imagenes del disco, que en una prueba
    /// de pantalla no avanzan solas.
    Future<void> abrirImagenes(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump();
      }
    }

    Finder dentro(Type tipo) => find.descendant(
      of: find.byType(PlanoConDetalle),
      matching: find.byType(tipo),
    );

    testWidgets('alejado es su imagen entera, como cualquier plano', (
      tester,
    ) async {
      await abrir(tester, [grande()]);
      await abrirImagenes(tester);

      expect(dentro(RotatedOverlayImage), findsOneWidget);
      expect(dentro(ClipPath), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('de cerca pone los cuadros que hay, y ahi recorta la entera', (
      tester,
    ) async {
      final plano = grande();
      final mapa = await abrir(tester, [plano]);

      // La parte de arriba de la hoja, que es la que ya tiene sus cuadros.
      mapa.move(const LatLng(4.56, -73.0), 14);
      await tester.pump();
      // En el primer cuadro todavia se estan abriendo: sigue la entera sola,
      // sin huecos.
      expect(dentro(RotatedOverlayImage), findsOneWidget);

      await abrirImagenes(tester);

      final imagenes = tester
          .widgetList<RotatedOverlayImage>(dentro(RotatedOverlayImage))
          .toList();
      expect(imagenes.length, greaterThan(1));
      expect(
        imagenes.length - 1,
        lessThanOrEqualTo(PlanoConDetalle.maximoALaVez),
      );
      // La entera sigue estando, recortada donde ya hay cuadros.
      expect(dentro(ClipPath), findsOneWidget);
      // Los cuadros se apoyan igual que la entera: misma opacidad, y el giro
      // sin capa aparte, que es lo que hacia desaparecer el plano de cerca.
      for (final imagen in imagenes) {
        expect(imagen.opacity, 0.8);
        expect(imagen.transformFilterQuality, isNull);
      }
      // Y caen adentro del plano.
      for (final imagen in imagenes.skip(1)) {
        expect(imagen.topLeftCorner.latitude, inInclusiveRange(4.40, 4.60));
        expect(imagen.topLeftCorner.longitude, inInclusiveRange(-73.1, -72.9));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('al volver a un lugar ya visto, los cuadros estan en el acto', (
      tester,
    ) async {
      final mapa = await abrir(tester, [grande()]);
      mapa.move(const LatLng(4.56, -73.0), 14);
      await tester.pump();
      await abrirImagenes(tester);
      final antes = tester.widgetList(dentro(RotatedOverlayImage)).length;
      expect(antes, greaterThan(1));

      // Se aleja -vuelve a la imagen entera sola- y se acerca de nuevo.
      mapa.move(const LatLng(4.56, -73.0), 9);
      await tester.pump();
      expect(dentro(RotatedOverlayImage), findsOneWidget);
      mapa.move(const LatLng(4.56, -73.0), 14);
      await tester.pump();

      // Las imagenes siguen en la memoria del telefono y contestan mientras
      // se arma la pantalla: no hay que esperarlas, y no puede romperse.
      expect(tester.takeException(), isNull);
      expect(tester.widgetList(dentro(RotatedOverlayImage)).length, antes);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('donde todavia no hay cuadros queda la imagen entera', (
      tester,
    ) async {
      final mapa = await abrir(tester, [grande()]);

      // La parte de abajo de la hoja: esos cuadros no se dibujaron.
      mapa.move(const LatLng(4.43, -73.0), 14);
      await tester.pump();
      await abrirImagenes(tester);

      expect(dentro(RotatedOverlayImage), findsOneWidget);
      expect(dentro(ClipPath), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('un plano comun al lado sigue yendo como siempre', (
      tester,
    ) async {
      final comun = PlanoEnMapa(
        codigo: 'comun',
        nombre: 'Lote 4',
        ruta: '${carpeta.path}/comun.png',
        esquinas: acostado.esquinas,
        opacidad: 1,
      );
      File(comun.ruta).writeAsBytesSync(unPixel);

      await abrir(tester, [comun, grande()]);
      await abrirImagenes(tester);

      // Dos imagenes enteras: la del comun y la del grande.
      expect(find.byType(RotatedOverlayImage), findsNWidgets(2));
      expect(find.byType(PlanoConDetalle), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
