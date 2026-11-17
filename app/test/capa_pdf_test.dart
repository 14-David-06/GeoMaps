import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
