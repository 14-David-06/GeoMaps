import 'dart:math' as math;
// Con prefijo: flutter_map exporta su propio Path<LatLng> y tapa el de dibujo
// en las pantallas que usan las dos cosas.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Donde estoy y, si se sabe, hacia donde voy.
///
/// Dos dibujos y no uno: **flecha** cuando el rumbo es confiable, **circulo**
/// cuando no. El circulo solo dice "estoy aca", y sobre un lote todo igual eso
/// deja a cualquiera sin saber para donde arrancar; la flecha lo resuelve. Pero
/// una flecha apuntando a donde no es, es peor que ninguna: manda a caminar al
/// contrario. Por eso, cuando no se sabe el rumbo, se vuelve al circulo en vez
/// de inventar una direccion.
class PuntoPropio extends StatelessWidget {
  const PuntoPropio({this.rumbo, super.key});

  /// Grados desde el norte, en sentido horario. Nulo si no es confiable.
  final double? rumbo;

  @override
  Widget build(BuildContext context) {
    if (rumbo == null) {
      return Center(
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
          ),
        ),
      );
    }

    return Transform.rotate(
      angle: rumbo! * math.pi / 180,
      child: CustomPaint(painter: _FlechaPropia()),
    );
  }
}

/// La flecha del punto propio, apuntando al norte del widget; quien la rota es
/// el Transform de arriba.
///
/// No es un triangulo pelado: la base va con una muesca hacia adentro, que es
/// lo que hace que a simple vista se distinga la punta de la cola. Un triangulo
/// isosceles chico, sobre imagen satelital y en movimiento, se lee igual por
/// los dos lados.
class _FlechaPropia extends CustomPainter {
  @override
  void paint(Canvas lienzo, Size tamano) {
    final ancho = tamano.width;
    final alto = tamano.height;

    final figura = ui.Path()
      ..moveTo(ancho / 2, 0)
      ..lineTo(ancho * 0.92, alto)
      ..lineTo(ancho / 2, alto * 0.76)
      ..lineTo(ancho * 0.08, alto)
      ..close();

    // La sombra va primero y aparte: es lo que despega la flecha de una imagen
    // satelital oscura, donde el azul solo se hunde.
    lienzo.drawShadow(figura, Colors.black54, 3, false);
    lienzo.drawPath(figura, Paint()..color = Colors.blue);
    lienzo.drawPath(
      figura,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_FlechaPropia oldDelegate) => false;
}
