import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import 'capa_ruta.dart' show formatearDistancia;

/// Medir sin guardar: distancia entre puntos y area de un poligono.
///
/// Es una herramienta efimera a proposito. La mitad de las veces que alguien
/// mide, quiere saber cuanto hay de aqui a alla y nada mas; obligarlo a crear
/// un trazado con nombre para eso llena la base de basura. Guardar es un boton
/// aparte, para cuando lo que se midio era un lote y vale la pena dejarlo.
///
/// Los puntos se ponen con el dedo, no con el GPS: es medir sobre la imagen.
/// Por eso lo que sale de aca se guarda como `manual` y no sirve de lindero.
class Medicion {
  const Medicion(this.puntos);

  final List<LatLng> puntos;

  List<PuntoGeo> get _geo => [
    for (final p in puntos) PuntoGeo(p.latitude, p.longitude),
  ];

  /// El largo de la linea, en el orden en que se marco.
  double get metros => longitudRutaM(_geo);

  /// Con tres puntos ya hay algo que cerrar.
  bool get esArea => puntos.length >= 3;

  double get hectareas => areaHa(_geo);
  double get perimetro => perimetroM(_geo);

  /// El area como se la dice: en metros cuadrados cuando es chica -un patio,
  /// un acopio- y en hectareas cuando es un lote.
  String get areaTexto {
    final m2 = hectareas * 10000;
    if (m2 < 10000) return '${m2.round()} m2';
    return '${hectareas.toStringAsFixed(2).replaceAll('.', ',')} ha';
  }
}

/// La medicion dibujada: los vertices, la linea entre ellos y, desde el tercer
/// punto, el area rellena con el lado que la cierra punteado.
class CapaMedicion extends StatelessWidget {
  const CapaMedicion({required this.puntos, super.key});

  final List<LatLng> puntos;

  static const _color = Color(0xFFFF6F00);

  @override
  Widget build(BuildContext context) {
    if (puntos.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: [
        if (puntos.length >= 3)
          PolygonLayer(
            polygons: [
              Polygon(
                points: puntos,
                color: _color.withValues(alpha: 0.22),
                borderStrokeWidth: 0,
              ),
            ],
          ),
        if (puntos.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: puntos,
                color: _color,
                strokeWidth: 4,
                borderColor: Colors.white,
                borderStrokeWidth: 1.5,
              ),
              // El lado que cierra el area no lo marco nadie: va punteado.
              if (puntos.length >= 3)
                Polyline(
                  points: [puntos.last, puntos.first],
                  color: _color,
                  strokeWidth: 3,
                  pattern: StrokePattern.dashed(segments: const [8, 8]),
                ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (var i = 0; i < puntos.length; i++)
              Marker(
                point: puntos[i],
                width: 18,
                height: 18,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // El ultimo va lleno: es el que saca "Deshacer".
                    color: i == puntos.length - 1 ? _color : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: _color, width: 3),
                    boxShadow: const [
                      BoxShadow(blurRadius: 3, color: Colors.black38),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// La tarjeta de abajo mientras se mide.
class PanelMedicion extends StatelessWidget {
  const PanelMedicion({
    required this.puntos,
    required this.onDeshacer,
    required this.onCerrar,
    this.onGuardar,
    super.key,
  });

  final List<LatLng> puntos;
  final VoidCallback onDeshacer;
  final VoidCallback onCerrar;

  /// Guardar lo medido como un area. Nulo si no se puede: sin sesion, o con
  /// menos de tres puntos.
  final VoidCallback? onGuardar;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final m = Medicion(puntos);

    final String titulo;
    final String detalle;
    if (puntos.isEmpty) {
      titulo = 'Medir';
      detalle = 'Toca el mapa para poner el primer punto.';
    } else if (puntos.length == 1) {
      titulo = 'Medir';
      detalle = 'Toca otro punto para medir la distancia.';
    } else if (!m.esArea) {
      titulo = formatearDistancia(m.metros);
      detalle = 'Un punto mas y se mide el area.';
    } else {
      titulo = m.areaTexto;
      detalle =
          'Perimetro ${formatearDistancia(m.perimetro)} · '
          '${puntos.length} puntos';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.straighten, color: CapaMedicion._color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titulo,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        detalle,
                        style: TextStyle(
                          fontSize: 15,
                          color: colores.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onCerrar,
                  tooltip: 'Dejar de medir',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            // Un Wrap y no una fila: con la letra agrandada los dos botones no
            // entran lado a lado, y el segundo baja en vez de salirse.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: puntos.isEmpty ? null : onDeshacer,
                      icon: const Icon(Icons.undo, size: 20),
                      label: const Text('Deshacer'),
                    ),
                    if (m.esArea)
                      FilledButton.tonalIcon(
                        onPressed: onGuardar,
                        icon: const Icon(Icons.save_outlined, size: 20),
                        label: const Text('Guardar area'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
