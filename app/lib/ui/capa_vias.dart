import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../core/vias.dart';

/// Las vias del predio dibujadas sobre el mapa.
///
/// Se dibujan como vectores y no como teselas: son 353 KB que viajan adentro del
/// APK y se ven nitidas a cualquier zoom, sin pedirle un byte a la red. Un
/// predio sin senal es exactamente donde hacen falta.
///
/// Van **debajo** del punto propio y del circulo de precision, que se agregan
/// despues en `MapaPage`: saber donde estoy no lo puede tapar una linea.
///
/// ## Por que tiene estado si no cambia nada
///
/// Son 1.664 vias, y arrastrar el mapa reconstruye la pantalla en cada cuadro.
/// Armar 1.664 `Polyline` sesenta veces por segundo es el trabajo que hacia que
/// el mapa se sintiera pesado al moverlo, y era trabajo tirado: el resultado es
/// identico mientras el predio sea el mismo.
///
/// Por eso la lista se arma una vez y se guarda. No hace falta filtrar por lo
/// que se ve: `PolylineLayer` ya descarta solo lo que queda fuera de pantalla.
/// Lo que se ahorra aca es **construirlas**, que es lo que pasaba antes de que
/// el mapa tuviera oportunidad de descartar nada.
class CapaVias extends StatefulWidget {
  const CapaVias({required this.vias, super.key});

  final ViasPredio vias;

  @override
  State<CapaVias> createState() => _CapaViasState();
}

class _CapaViasState extends State<CapaVias> {
  late List<Polyline> _lineas = _armar(widget.vias);

  @override
  void didUpdateWidget(CapaVias anterior) {
    super.didUpdateWidget(anterior);
    // Solo si de verdad cambio el predio. Es el unico caso en que la lista
    // guardada dejaria de servir.
    if (!identical(anterior.vias, widget.vias)) {
      _lineas = _armar(widget.vias);
    }
  }

  static List<Polyline> _armar(ViasPredio vias) {
    // Dos pasadas: primero las proyectadas, para que las vias que existen de
    // verdad queden dibujadas encima en los cruces.
    final proyectadas = <Polyline>[];
    final construidas = <Polyline>[];

    for (final via in vias.vias) {
      final estilo = _EstiloVia.de(via);
      final linea = Polyline(
        points: via.puntos,
        color: estilo.color,
        strokeWidth: estilo.grosor,
        pattern: estilo.patron,
        // El borde oscuro es lo que hace legible una linea clara sobre imagen
        // satelital a pleno sol. Sin el, una balastrada sobre suelo desnudo
        // desaparece: son del mismo color.
        borderColor: Colors.black54,
        borderStrokeWidth: estilo.borde,
      );
      (via.tipo.construida ? construidas : proyectadas).add(linea);
    }

    return [...proyectadas, ...construidas];
  }

  @override
  Widget build(BuildContext context) => PolylineLayer(polylines: _lineas);
}

/// Como se ve cada tipo de via.
class _EstiloVia {
  const _EstiloVia({
    required this.color,
    required this.grosor,
    required this.borde,
    required this.patron,
  });

  factory _EstiloVia.de(Via via) {
    // Una via externa es de paso: se dibuja mas tenue para que no compita con
    // las del predio, que son las que se recorren.
    final alfa = via.interna ? 1.0 : 0.55;

    switch (via.tipo) {
      case TipoVia.pavimentada:
      case TipoVia.ruta:
        return _EstiloVia(
          color: Colors.white.withValues(alpha: alfa),
          grosor: 3.4,
          borde: 1.6,
          patron: const StrokePattern.solid(),
        );
      case TipoVia.balastrada:
        // Color tierra: es lo que la via es, y al lado del blanco de la
        // pavimentada se distinguen de un vistazo sin leer ninguna leyenda.
        return _EstiloVia(
          color: const Color(0xFFFFC46B).withValues(alpha: alfa),
          grosor: 2.6,
          borde: 1.2,
          patron: const StrokePattern.solid(),
        );
      case TipoVia.proyectada:
        // Punteada y apagada. Es la unica diferencia visual que tiene que
        // saltar sin explicacion: esta via no esta construida.
        return _EstiloVia(
          color: const Color(0xFFB0BEC5).withValues(alpha: 0.75 * alfa),
          grosor: 2.0,
          borde: 0,
          patron: StrokePattern.dashed(segments: const [7, 6]),
        );
    }
  }

  final Color color;
  final double grosor;
  final double borde;
  final StrokePattern patron;
}

/// La leyenda de las vias.
///
/// Chica y arriba a la izquierda. Existe por el punteado: el color de una
/// balastrada se adivina, pero que una linea gris punteada signifique "todavia
/// no esta construida" no lo adivina nadie.
class LeyendaVias extends StatelessWidget {
  const LeyendaVias({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        // Fondo solido, como el resto de los controles sobre el mapa.
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          _Renglon(color: Colors.white, texto: 'Pavimentada'),
          SizedBox(height: 5),
          _Renglon(color: Color(0xFFFFC46B), texto: 'Balastrada'),
          SizedBox(height: 5),
          _Renglon(
            color: Color(0xFFB0BEC5),
            texto: 'Proyectada (no construida)',
            punteada: true,
          ),
        ],
      ),
    );
  }
}

class _Renglon extends StatelessWidget {
  const _Renglon({
    required this.color,
    required this.texto,
    this.punteada = false,
  });

  final Color color;
  final String texto;
  final bool punteada;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 3,
          child: punteada
              ? Row(
                  children: List.generate(
                    3,
                    (i) => Expanded(
                      child: Container(
                        margin: EdgeInsets.only(right: i == 2 ? 0 : 3),
                        color: color,
                      ),
                    ),
                  ),
                )
              : Container(color: color),
        ),
        const SizedBox(width: 8),
        Text(
          texto,
          style: const TextStyle(color: Colors.white, fontSize: 11.5),
        ),
      ],
    );
  }
}
