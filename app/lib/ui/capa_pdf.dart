import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Un plano de topografia importado, dibujado encima del mapa.
///
/// ## Por que va con las cuatro esquinas y no con un rectangulo
///
/// Un plano de topografia esta dibujado en el sistema de coordenadas del pais
/// -aca MAGNA-SIRGAS- y el mapa esta en Web Mercator. Entre los dos hay un
/// giro de unos grados. Encajarlo en el rectangulo que lo contiene lo estira
/// hasta cuadrarlo, y ahi los linderos dejan de coincidir con el terreno: son
/// decenas de metros, justo del orden de lo que alguien esta tratando de
/// ubicar. `RotatedOverlayImage` toma tres esquinas y respeta el giro.
///
/// ## Donde va en la pila
///
/// Encima de la imagen satelital y **debajo** de los lotes, las vias y el punto
/// propio. El plano es contexto; saber donde estoy no lo puede tapar una hoja
/// escaneada.
class CapaPdf extends StatelessWidget {
  const CapaPdf({required this.planos, super.key});

  /// Los planos encendidos, del mas abajo al mas arriba.
  final List<PlanoEnMapa> planos;

  @override
  Widget build(BuildContext context) {
    if (planos.isEmpty) return const SizedBox.shrink();

    return OverlayImageLayer(
      overlayImages: [
        for (final p in planos)
          RotatedOverlayImage(
            imageProvider: FileImage(File(p.ruta)),
            topLeftCorner: p.noroeste,
            bottomLeftCorner: p.suroeste,
            bottomRightCorner: p.sureste,
            opacity: p.opacidad,
            // El plano se ve casi siempre agrandado -se rasterizo una vez y
            // despues alguien se acerca-. Con filtrado bajo, las lineas del
            // lindero se ven dentadas justo cuando se las esta mirando de
            // cerca; `medium` las deja limpias sin el costo de `high`.
            filterQuality: FilterQuality.medium,
          ),
      ],
    );
  }
}

/// Lo que la capa necesita saber de un plano para dibujarlo.
///
/// Es una vista de la fila de `Mapas`, no la fila entera: la capa no tiene por
/// que saber de llaves de S3 ni de estados de descarga.
class PlanoEnMapa {
  const PlanoEnMapa({
    required this.codigo,
    required this.nombre,
    required this.ruta,
    required this.esquinas,
    required this.opacidad,
  });

  final String codigo;
  final String nombre;

  /// El PNG en el telefono.
  final String ruta;

  /// Noroeste, noreste, sureste, suroeste.
  final List<LatLng> esquinas;

  final double opacidad;

  LatLng get noroeste => esquinas[0];
  LatLng get sureste => esquinas[2];
  LatLng get suroeste => esquinas[3];
}
