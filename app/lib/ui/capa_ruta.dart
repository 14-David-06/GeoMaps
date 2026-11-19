import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/ruteo.dart';

/// La ruta calculada, dibujada sobre el mapa.
///
/// Son tres cosas distintas y se dibujan distinto a proposito:
///
/// - **Lo que se maneja**, sobre las vias: linea llena y gruesa.
/// - **Lo que se camina** en las dos puntas: punteado. Del punto marcado a la
///   via casi nunca hay camino, y pintar esos metros como si lo hubiera manda a
///   alguien a meter la camioneta en el lote.
/// - **El punto marcado**: el destino, que no es donde termina la via.
///
/// Va encima de las vias y debajo del punto propio: la ruta se sigue mirando
/// donde estoy, no al reves.
class CapaRuta extends StatelessWidget {
  const CapaRuta({required this.ruta, this.progreso, super.key});

  final Ruta ruta;

  /// Donde va la persona. Con progreso, la ruta se dibuja **desde la flecha**:
  /// lo recorrido queda gris y lo que falta en azul, como en un navegador. Sin
  /// progreso -antes del primer fix- se dibuja entera.
  final ProgresoRuta? progreso;

  static const _color = Color(0xFF2979FF);
  static const _recorrido = Color(0xFF9E9E9E);

  @override
  Widget build(BuildContext context) {
    final p = progreso;
    if (p == null) {
      return PolylineLayer(
        polylines: [
          _porVia(ruta.porLaVia),
          // Los dos tramos a campo traviesa. Solo se dibujan si valen la pena:
          // 3 m de punteado no se ven y ensucian.
          if (ruta.metrosHastaLaVia > 8) _aPie([ruta.origen, ruta.entrada]),
          if (ruta.metrosDesdeLaVia > 8) _aPie([ruta.salida, ruta.destino]),
        ],
      );
    }

    // `completa` es [origen, ...porLaVia, destino]: el tramo 0 es el de a pie
    // hasta la via, el ultimo el de a pie hasta el punto, y los del medio son
    // via. El tramo i de la linea completa es el tramo i-1 de `porLaVia`.
    final linea = ruta.completa;
    final ultimo = linea.length - 2;
    final s = p.segmento;

    final recorrido = [...linea.sublist(0, s + 1), p.pie];

    return PolylineLayer(
      polylines: [
        if (s > 0 || ruta.metrosHastaLaVia > 8)
          Polyline(
            points: recorrido,
            color: _recorrido.withValues(alpha: 0.8),
            strokeWidth: 5,
            borderColor: Colors.white70,
            borderStrokeWidth: 1,
          ),
        if (s == 0) ...[
          _aPie([p.pie, ruta.entrada]),
          _porVia(ruta.porLaVia),
        ] else if (s < ultimo)
          _porVia([p.pie, ...ruta.porLaVia.sublist(s)]),
        if (s < ultimo && ruta.metrosDesdeLaVia > 8)
          _aPie([ruta.salida, ruta.destino]),
        if (s == ultimo) _aPie([p.pie, ruta.destino]),
      ],
    );
  }

  Polyline _porVia(List<LatLng> puntos) => Polyline(
    points: puntos,
    color: _color,
    strokeWidth: 6,
    // Sobre imagen satelital, una linea de color sin borde oscuro se pierde
    // contra el agua y contra el suelo humedo.
    borderColor: Colors.white,
    borderStrokeWidth: 2,
  );

  Polyline _aPie(List<LatLng> puntos) => Polyline(
    points: puntos,
    color: _color.withValues(alpha: 0.85),
    strokeWidth: 3.5,
    pattern: StrokePattern.dotted(spacingFactor: 2.2),
    borderColor: Colors.white70,
    borderStrokeWidth: 1,
  );
}

/// El punto marcado en el mapa.
class MarcadorDestino extends StatelessWidget {
  const MarcadorDestino({required this.destino, super.key});

  final LatLng destino;

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: [
        Marker(
          point: destino,
          width: 34,
          height: 44,
          // La punta del alfiler es la coordenada, no el centro del icono.
          alignment: Alignment.topCenter,
          child: const Icon(
            Icons.place,
            size: 40,
            color: Color(0xFFD32F2F),
            shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
          ),
        ),
      ],
    );
  }
}

/// La tarjeta de abajo: cuanto falta y por donde.
///
/// El dato que manda es **cuanto falta desde donde estoy**, no el largo total
/// de la ruta: quien va manejando quiere saber si le quedan 400 m o 6 km.
class PanelRuta extends StatelessWidget {
  const PanelRuta({
    required this.ruta,
    required this.progreso,
    required this.calculando,
    required this.onCerrar,
    this.onGuardar,
    this.guardada = false,
    this.nombreDestino,
    this.enRuta = false,
    this.onIniciar,
    this.onTerminar,
    this.botonVoz,
    super.key,
  });

  final Ruta ruta;

  /// El parlante que prende y apaga las indicaciones habladas. Va al lado
  /// del boton de iniciar o terminar; nulo donde no hay voz que ofrecer.
  final Widget? botonVoz;

  /// Si la ruta ya se inicio: se esta grabando por donde se va, y al terminar
  /// se pregunta que tal estuvo.
  final bool enRuta;

  /// Iniciar la ruta. Nulo si no se puede -ya hay otro recorrido grabandose-,
  /// y entonces el boton no se muestra.
  final VoidCallback? onIniciar;

  /// Terminar la ruta que se inicio, antes de llegar. Al llegar termina sola.
  final VoidCallback? onTerminar;

  /// Guardar la ruta para volver a abrirla. Nulo mientras se recalcula: la
  /// linea que se ve en ese momento es la vieja.
  final VoidCallback? onGuardar;

  /// Si esta ruta ya se guardo. El boton queda marcado y no guarda dos veces.
  final bool guardada;

  /// Donde va respecto de la ruta. Nulo mientras no haya llegado un fix.
  final ProgresoRuta? progreso;

  /// Si en este momento se esta recalculando por un desvio.
  final bool calculando;

  /// A donde va, si el destino tiene nombre (un acopio). Nulo para un punto
  /// marcado a mano.
  final String? nombreDestino;

  final VoidCallback onCerrar;

  @override
  Widget build(BuildContext context) {
    final restantes = progreso?.metrosRestantes ?? ruta.metrosTotales;

    // Los minutos se escalan con lo que falta: recalcular el tiempo exacto de
    // la parte restante costaria otro ruteo por fix y no cambiaria la decision
    // de nadie.
    final minutos = ruta.metrosTotales <= 0
        ? 0.0
        : ruta.minutos * (restantes / ruta.metrosTotales);

    final colores = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      color: colores.surface,
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  calculando ? Icons.autorenew : Icons.directions,
                  color: colores.primary,
                  size: 30,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    // Sin esto la columna se estira a todo el alto que le ofrece
                    // el Stack y la tarjeta tapa el mapa entero.
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (nombreDestino != null)
                        Text(
                          nombreDestino!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: colores.primary,
                          ),
                        ),
                      Text(
                        '${formatearDistancia(restantes)}  ·  ${formatearMinutos(minutos)}',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _detalle(),
                        style: TextStyle(
                          fontSize: 16,
                          color: colores.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: guardada ? null : onGuardar,
                  icon: Icon(
                    guardada ? Icons.bookmark : Icons.bookmark_add_outlined,
                  ),
                  tooltip: guardada ? 'Ruta guardada' : 'Guardar la ruta',
                ),
                IconButton(
                  onPressed: onCerrar,
                  icon: const Icon(Icons.close),
                  tooltip: enRuta ? 'Terminar la ruta' : 'Quitar la ruta',
                ),
              ],
            ),
            // Iniciar es un boton y no algo que pasa solo al marcar el punto:
            // marcar un destino es mirar cuanto falta, y de ahi a salir hay un
            // paso. Lo que se inicia se graba y se califica al final.
            if (_boton() case final boton?)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Row(
                  children: [
                    Expanded(child: boton),
                    if (botonVoz != null) ...[
                      const SizedBox(width: 8),
                      botonVoz!,
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// El boton del momento: iniciar, terminar, o ninguno.
  Widget? _boton() {
    if (enRuta && onTerminar != null) {
      return FilledButton.tonalIcon(
        onPressed: onTerminar,
        icon: const Icon(Icons.flag_outlined, size: 20),
        label: const Text('Terminar la ruta'),
      );
    }
    if (!enRuta && onIniciar != null) {
      return FilledButton.icon(
        onPressed: calculando ? null : onIniciar,
        icon: const Icon(Icons.navigation, size: 20),
        label: const Text('Iniciar la ruta'),
      );
    }
    return null;
  }

  String _detalle() {
    if (calculando) return 'Te saliste de la ruta, recalculando...';
    if (enRuta) return 'En ruta: se esta grabando por donde vas';

    // Los metros a pie se avisan siempre que sean algo mas que el ancho de la
    // via: son los que no se hacen en camioneta.
    final aPie = ruta.metrosDesdeLaVia;
    if (aPie > 25) {
      return 'Por via hasta ${formatearDistancia(ruta.metros)}, '
          'y los ultimos ${formatearDistancia(aPie)} a pie';
    }
    return 'Por las vias del predio';
  }
}

/// Mientras se arma el grafo y se busca el camino.
///
/// La primera ruta de cada sesion tarda unas decimas de segundo -hay que armar
/// el grafo de las vias- y sin este cartel esa demora se lee como que el mapa
/// ignoro el gesto.
class CalculandoRuta extends StatelessWidget {
  const CalculandoRuta({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      elevation: 6,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            // Expandido: con la letra agrandada el renglon no entra en una
            // sola linea y sin esto se salia de la tarjeta.
            Expanded(
              child: Text('Trazando la ruta por las vias del predio...'),
            ),
          ],
        ),
      ),
    );
  }
}

/// El aviso de que se puede pedir una ruta.
///
/// Mantener pulsado el mapa no lo adivina nadie, y una funcion que no se
/// descubre es una funcion que no existe. Se muestra hasta que la persona marca
/// su primer destino, y despues no vuelve.
class PistaRuta extends StatelessWidget {
  const PistaRuta({this.conAcopios = false, super.key});

  /// Si el predio tiene acopios, que tambien se tocan para ir a ellos.
  final bool conAcopios;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.touch_app_outlined, color: Colors.white, size: 17),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              conAcopios
                  ? 'Toca un acopio o manten pulsado un punto para trazar '
                        'la ruta'
                  : 'Manten pulsado un punto para trazar la ruta',
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

/// Metros en la unidad en la que se habla de ellos en campo.
String formatearDistancia(double metros) {
  if (metros < 1000) {
    // De a 10 m: el GPS no sabe mas que eso y un numero al metro miente.
    return '${(metros / 10).round() * 10} m';
  }
  return '${(metros / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

String formatearMinutos(double minutos) {
  if (minutos < 1) return 'menos de 1 min';
  if (minutos < 60) return '${minutos.round()} min';
  final horas = minutos ~/ 60;
  final resto = (minutos % 60).round();
  return resto == 0 ? '$horas h' : '$horas h $resto min';
}
