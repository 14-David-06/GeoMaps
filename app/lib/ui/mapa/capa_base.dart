import 'package:flutter/material.dart';

/// Las dos formas de mirar el terreno.
///
/// No sobra ninguna: el satelite muestra el cultivo, la ronda del cano y donde
/// termina el potrero, lo que un mapa de calles nunca va a mostrar, pero se
/// pierde para ubicarse porque no tiene nombres. Las calles tienen la via y el
/// caserio y no tienen ni un arbol. En campo se alterna entre las dos.
///
/// Ninguna pide llave ni cuenta.
enum CapaBase {
  satelite(
    'Satelite',
    Icons.satellite_alt,
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    // Esri no sirve teselas nativas mas alla de z19 en zona rural. Sin este
    // tope, acercarse mas deja la pantalla en gris en vez de escalar la ultima.
    19,
    'Esri, Maxar, Earthstar Geographics',
  ),
  calles(
    'Calles',
    Icons.map_outlined,
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    19,
    '(c) OpenStreetMap',
  );

  const CapaBase(
    this.titulo,
    this.icono,
    this.url,
    this.zoomMax,
    this.atribucion,
  );

  final String titulo;
  final IconData icono;
  final String url;
  final int zoomMax;

  /// De quien es la imagen. Los dos servidores piden mostrarlo para usarla.
  final String atribucion;

  CapaBase get otra => this == satelite ? calles : satelite;

  /// La regla de uso del servidor publico de OSM pide identificar la app en el
  /// user agent.
  String get paquete => 'com.siriusregenerative.geomaps';
}
