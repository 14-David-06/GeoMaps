import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'gps.dart';

export 'gps.dart' show PermisoUbicacionDenegado;

/// La posicion actual, para las pantallas que solo quieren mostrarla.
///
/// Es `autoDispose` a proposito: el GPS es lo que mas bateria consume en esta
/// app, y el home no tiene por que mantenerlo prendido cuando alguien lo dejo
/// atras. En cuanto la ultima pantalla que lo mira se va, el flujo se corta.
///
/// Sale del mismo [Gps] que usa el mapa: ver ahi por que no puede haber dos.
/// El motivo de un permiso negado llega como error, para mostrarlo tal cual:
/// "activa la ubicacion" y "el permiso quedo denegado para siempre" piden
/// cosas distintas de la persona.
final posicionProvider = StreamProvider.autoDispose<Position>(
  (ref) => Gps.instancia.posiciones,
);
