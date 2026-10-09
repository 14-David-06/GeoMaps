import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/acopios.dart';
import 'capa_ruta.dart' show formatearDistancia;

/// El color de los acopios. Naranja porque es lo unico de ese color en el
/// mapa: blanco es pavimento, tierra es balastrada, azul es la ruta y el punto
/// propio. Un acopio tiene que encontrarse de un vistazo entre todo eso.
const colorAcopio = Color(0xFFFF6D00);

/// Los acopios del predio dibujados sobre el mapa.
///
/// Son cientos, y como los rotulos de los lotes, lo que se dibuja depende del
/// zoom:
///
/// - **de lejos** (z < [zoomMinimo]): nada. Cientos de puntos sobre un predio
///   que entra entero en la pantalla son una mancha naranja, no informacion.
/// - **de medio** : un punto por acopio.
/// - **de cerca** (z >= [zoomNumero]): el punto y su numero.
///
/// Los puntos se tocan para elegirlos, pero quien resuelve el toque es la
/// pantalla del mapa ([acopioCercano]) y no cada punto: un `GestureDetector`
/// por acopio son cientos de widgets mas, y un punto de 10 px es mas chico que
/// un dedo. Buscando el mas cercano al toque, se acierta aunque el dedo caiga
/// al lado.
class CapaAcopios extends StatefulWidget {
  const CapaAcopios({
    required this.acopios,
    required this.zoom,
    this.seleccionado,
    super.key,
  });

  final AcopiosPredio acopios;
  final double zoom;

  /// El que se toco o se busco. Se resalta para que se vea cual es.
  final Acopio? seleccionado;

  static const zoomMinimo = 13.0;
  static const zoomNumero = 16.0;

  @override
  State<CapaAcopios> createState() => _CapaAcopiosState();
}

class _CapaAcopiosState extends State<CapaAcopios> {
  // Los puntos y los rotulos se arman una vez y se guardan, por lo mismo que
  // las vias y los lotes: la pantalla se reconstruye en cada cuadro de zoom y
  // armar cientos de marcadores cada vez es trabajo tirado.
  late bool _grandes = _sonGrandes(widget.zoom);
  late List<CircleMarker> _puntos = _armarPuntos(widget.acopios, _grandes);
  late final List<Marker> _numeros = _armarNumeros(widget.acopios);

  static bool _sonGrandes(double zoom) => zoom >= 15;

  @override
  void didUpdateWidget(CapaAcopios anterior) {
    super.didUpdateWidget(anterior);
    final grandes = _sonGrandes(widget.zoom);
    if (grandes != _grandes || !identical(anterior.acopios, widget.acopios)) {
      _grandes = grandes;
      _puntos = _armarPuntos(widget.acopios, grandes);
    }
  }

  static List<CircleMarker> _armarPuntos(AcopiosPredio acopios, bool grandes) {
    return [
      for (final a in acopios.acopios)
        CircleMarker(
          point: a.punto,
          radius: grandes ? 6 : 4,
          color: colorAcopio,
          // El borde blanco lo despega de la palma oscura y del suelo.
          borderColor: Colors.white,
          borderStrokeWidth: grandes ? 2 : 1.2,
        ),
    ];
  }

  static List<Marker> _armarNumeros(AcopiosPredio acopios) {
    return [
      for (final a in acopios.acopios)
        if (a.numero.isNotEmpty)
          Marker(
            point: a.punto,
            width: 44,
            height: 18,
            // A la derecha del punto y no encima: encima lo tapa.
            alignment: const Alignment(1.25, 0),
            child: _Numero(texto: a.numero),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.zoom < CapaAcopios.zoomMinimo) {
      // El elegido se sigue viendo aunque se aleje el mapa: se busco para
      // encontrarlo, y alejarse para ver por donde se llega no puede borrarlo.
      final s = widget.seleccionado;
      return s == null ? const SizedBox.shrink() : _Resaltado(acopio: s);
    }

    return Stack(
      children: [
        CircleLayer(circles: _puntos),
        if (widget.zoom >= CapaAcopios.zoomNumero)
          MarkerLayer(markers: _numeros),
        if (widget.seleccionado != null)
          _Resaltado(acopio: widget.seleccionado!),
      ],
    );
  }
}

class _Resaltado extends StatelessWidget {
  const _Resaltado({required this.acopio});

  final Acopio acopio;

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: [
        Marker(
          point: acopio.punto,
          width: 30,
          height: 30,
          child: Container(
            decoration: BoxDecoration(
              color: colorAcopio,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(blurRadius: 6, color: Colors.black54),
              ],
            ),
            child: const Icon(Icons.inventory_2, color: Colors.white, size: 15),
          ),
        ),
      ],
    );
  }
}

class _Numero extends StatelessWidget {
  const _Numero({required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        texto,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          shadows: [
            Shadow(blurRadius: 3, color: Colors.black87),
            Shadow(blurRadius: 6, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}

/// El acopio mas cercano a un toque en la pantalla, si hay uno a distancia de
/// dedo.
///
/// Se mide en pixeles y no en metros: lo que importa es si el dedo cayo sobre
/// el punto **tal como se ve**, y eso depende del zoom.
Acopio? acopioCercano({
  required AcopiosPredio acopios,
  required MapCamera camara,
  required Offset toque,
  double radioPx = 26,
}) {
  Acopio? mejor;
  var mejorD2 = radioPx * radioPx;
  for (final a in acopios.acopios) {
    final d = camara.latLngToScreenOffset(a.punto) - toque;
    final d2 = d.dx * d.dx + d.dy * d.dy;
    if (d2 < mejorD2) {
      mejorD2 = d2;
      mejor = a;
    }
  }
  return mejor;
}

/// La tarjeta del acopio elegido, abajo: cual es y el boton para ir.
///
/// Elegir un acopio no traza la ruta de una: un toque de mas sobre el mapa,
/// con una ruta ya en curso, no puede cambiar a donde va alguien que esta
/// manejando. Se elige, se confirma con "Como llegar", y recien ahi se rutea.
class FichaAcopio extends StatelessWidget {
  const FichaAcopio({
    required this.acopio,
    required this.desde,
    required this.onIr,
    required this.onCerrar,
    super.key,
  });

  final Acopio acopio;

  /// La posicion propia, para decir a cuanto queda en linea recta.
  final LatLng? desde;

  final VoidCallback onIr;
  final VoidCallback onCerrar;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final d = desde;
    final lejos = d == null
        ? null
        : const Distance().as(LengthUnit.Meter, d, acopio.punto);

    final detalle = [
      if (acopio.lote.isNotEmpty) 'Lote ${acopio.lote}',
      if (lejos != null) 'a ${formatearDistancia(lejos)} en linea recta',
    ].join('  ·  ');

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      color: colores.surface,
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            const Icon(Icons.inventory_2, color: colorAcopio, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    acopio.nombre,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (detalle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detalle,
                      style: TextStyle(fontSize: 12.5, color: colores.outline),
                    ),
                  ],
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: onIr,
              icon: const Icon(Icons.directions, size: 18),
              label: const Text('Como llegar'),
            ),
            IconButton(
              onPressed: onCerrar,
              icon: const Icon(Icons.close),
              tooltip: 'Cerrar',
            ),
          ],
        ),
      ),
    );
  }
}

/// Buscar un acopio por numero o por lote.
///
/// Con cientos de acopios, encontrar "el 30 del B.9-P.2" recorriendo el mapa
/// con el dedo es imposible: hay un 30 en casi cada lote. Se escribe y se elige.
Future<Acopio?> buscarAcopio(BuildContext context, AcopiosPredio acopios) {
  return showModalBottomSheet<Acopio>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _Buscador(acopios: acopios),
  );
}

class _Buscador extends StatefulWidget {
  const _Buscador({required this.acopios});

  final AcopiosPredio acopios;

  @override
  State<_Buscador> createState() => _BuscadorState();
}

class _BuscadorState extends State<_Buscador> {
  String _texto = '';

  /// Mas que esto no lo recorre nadie con el dedo, y armar cientos de filas en
  /// cada tecla se nota en un telefono de campo.
  static const _maximo = 60;

  @override
  Widget build(BuildContext context) {
    final encontrados = widget.acopios.buscar(_texto);
    final mostrados = encontrados.take(_maximo).toList();

    return Padding(
      // Que el teclado no tape la lista.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Numero o lote: "30 B.9-P.2"',
                  border: OutlineInputBorder(),
                ),
                onChanged: (t) => setState(() => _texto = t),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  encontrados.length > _maximo
                      ? '${encontrados.length} acopios. Escribi el lote para '
                            'acotar.'
                      : '${encontrados.length} acopios',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: mostrados.length,
                itemBuilder: (context, i) {
                  final a = mostrados[i];
                  return ListTile(
                    leading: const Icon(Icons.inventory_2, color: colorAcopio),
                    title: Text(a.nombre),
                    subtitle: Text(
                      a.lote.isEmpty ? 'Fuera de los lotes' : 'Lote ${a.lote}',
                    ),
                    onTap: () => Navigator.of(context).pop(a),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
