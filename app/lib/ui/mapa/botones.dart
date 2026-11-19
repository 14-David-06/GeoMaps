import 'package:flutter/material.dart';

import 'seguidor.dart';

/// Los botones del costado del mapa: herramientas, buscar, capas y centrar.
///
/// Son cuatro y no mas a proposito. Un boton por herramienta y otro por capa
/// ya eran cinco y tapaban el costado del mapa; con cada cosa nueva iba a ser
/// uno mas. Lo nuevo entra adentro de herramientas o de capas.
class BotonesDelMapa extends StatelessWidget {
  const BotonesDelMapa({
    required this.modo,
    required this.alAbrirHerramientas,
    required this.alAbrirCapas,
    required this.alCentrar,
    this.alBuscarAcopio,
    super.key,
  });

  /// Como va la camara: de eso depende el dibujo del boton de centrar.
  final ModoCamara modo;

  final VoidCallback alAbrirHerramientas;
  final VoidCallback alAbrirCapas;

  /// Nulo mientras no haya posicion: no hay donde centrar.
  final VoidCallback? alCentrar;

  /// Nulo si el mapa no abrio un predio con acopios, y el boton no va.
  final VoidCallback? alBuscarAcopio;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FloatingActionButton.small(
          heroTag: 'herramientas',
          onPressed: alAbrirHerramientas,
          tooltip: 'Herramientas',
          child: const Icon(Icons.construction),
        ),
        if (alBuscarAcopio != null) ...[
          const SizedBox(height: 12),
          FloatingActionButton.small(
            heroTag: 'buscar',
            onPressed: alBuscarAcopio,
            tooltip: 'Buscar un acopio',
            child: const Icon(Icons.search),
          ),
        ],
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'capas',
          onPressed: alAbrirCapas,
          tooltip: 'Capas',
          child: const Icon(Icons.layers_outlined),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'centrar',
          onPressed: alCentrar,
          tooltip: switch (modo) {
            ModoCamara.libre => 'Seguir mi posicion',
            ModoCamara.rumbo => 'Norte arriba',
            ModoCamara.centrado => 'Girar hacia donde voy',
          },
          child: Icon(switch (modo) {
            ModoCamara.libre => Icons.location_searching,
            ModoCamara.rumbo => Icons.navigation,
            ModoCamara.centrado => Icons.my_location,
          }),
        ),
      ],
    );
  }
}
