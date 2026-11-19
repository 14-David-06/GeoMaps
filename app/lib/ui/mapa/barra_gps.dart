import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/ubicacion.dart';
import '../theme.dart';

/// La barra de arriba del mapa. Dice la precision en metros, que es el dato
/// que decide si lo que se esta levantando sirve para un lindero o solo para
/// ubicarse.
class BarraGps extends StatelessWidget {
  const BarraGps({required this.posicion, required this.error, super.key});

  final Position? posicion;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final String texto;
    final Color color;

    if (error != null) {
      texto = error!;
      color = ColoresEstado.mal;
    } else if (posicion == null) {
      // Sin internet no hay GPS asistido y el primer fix tarda: decirlo evita
      // que alguien crea que la app se colgo y la cierre justo antes del fix.
      texto =
          'Buscando senal GPS... Sin internet puede tardar unos minutos; '
          'a cielo abierto es mas rapido.';
      color = ColoresEstado.aviso;
    } else if (Ubicacion.esDeCache(posicion!)) {
      texto =
          'Ultima posicion conocida (${Ubicacion.hace(posicion!)}). '
          'Buscando senal GPS...';
      color = ColoresEstado.aviso;
    } else {
      final p = posicion!;
      texto =
          '${p.latitude.toStringAsFixed(6)}, '
          '${p.longitude.toStringAsFixed(6)}   '
          '+/- ${p.accuracy.toStringAsFixed(0)} m';
      // El umbral no es cosmetico: por encima de 10 m el punto no sirve para
      // marcar un vertice de lindero, y quien lo marca tiene que verlo en el
      // momento, no descubrirlo despues en la oficina.
      color = p.accuracy <= 10 ? ColoresEstado.bien : ColoresEstado.aviso;
    }

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          // Fondo solido y no translucido: la app se usa a pleno sol y un
          // control semitransparente sobre imagen satelital no se ve.
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.gps_fixed, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                texto,
                style: const TextStyle(
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
