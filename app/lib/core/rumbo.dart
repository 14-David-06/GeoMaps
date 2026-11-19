import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Las cuentas del rumbo: hacia donde se va, y como lo persigue la camara.
///
/// Estan aparte de la pantalla del mapa porque son cuentas y nada mas, y asi
/// se prueban sin armar un mapa.

/// El rumbo del fix, o nulo si no hay que creerle.
///
/// El `heading` del GPS no es una brujula: es la direccion entre los ultimos
/// dos puntos. Quieto, esos dos puntos son ruido, y el valor gira solo. Por eso
/// se exige ir caminando de verdad -1,2 m/s es paso largo- antes de dibujar una
/// direccion. Debajo de eso se devuelve nulo y se pinta el circulo.
double? rumboConfiable(Position p) {
  if (p.speed < 1.2) return null;
  final rumbo = p.heading;
  if (rumbo.isNaN || rumbo < 0 || rumbo > 360) return null;
  return rumbo;
}

/// Diferencia de b menos a en grados, por el lado corto: de 350 a 10 son 20,
/// no -340. Sin esto el mapa da la vuelta entera al cruzar el norte.
double diferenciaAngular(double a, double b) {
  final d = (b - a) % 360;
  return d > 180 ? d - 360 : d;
}

/// El punto a [metros] de [desde] en direccion [rumbo]. Plano local: son unos
/// cientos de metros y no hace falta mas.
LatLng adelantar(LatLng desde, double rumbo, double metros) {
  final r = rumbo * math.pi / 180;
  final dLat = metros * math.cos(r) / 110540.0;
  final dLon =
      metros *
      math.sin(r) /
      (111320.0 * math.cos(desde.latitude * math.pi / 180));
  return LatLng(desde.latitude + dLat, desde.longitude + dLon);
}

/// Donde queda la camara despues de un cuadro.
class PasoDeCamara {
  const PasoDeCamara(this.centro, this.giro, {required this.llego});

  final LatLng centro;

  /// El giro del mapa en grados, como lo mide `flutter_map`: el rumbo con el
  /// signo cambiado.
  final double giro;

  /// Si con este cuadro ya quedo donde tenia que quedar: no hace falta otro.
  final bool llego;
}

/// Un cuadro de la camara que sigue a la posicion: se acerca una fraccion de
/// lo que falta. Asi el movimiento es suave y llega sin pasarse, sea un fix
/// nuevo o la brujula.
///
/// [centro], [giro] y [zoom] son los de la camara ahora. [rumbo] es hacia
/// donde se va, o nulo si no se sabe o si el mapa va con el norte arriba.
/// [conRumbo] dice si se esta en modo navegador: ahi, sin rumbo, el mapa se
/// queda con el giro que tenia en vez de volver al norte.
PasoDeCamara pasoDeCamara({
  required LatLng centro,
  required double giro,
  required double zoom,
  required LatLng posicion,
  required double? rumbo,
  required bool conRumbo,
  required double altoPantalla,
}) {
  // En modo navegador sin rumbo -quieto y sin brujula- se deja el giro que
  // tenia: volver al norte con cada fix y girar de nuevo al arrancar marea.
  final giroObjetivo = rumbo != null ? -rumbo : (conRumbo ? giro : 0.0);

  var objetivo = posicion;
  if (rumbo != null) {
    // La flecha va en el tercio de abajo: lo que importa es lo que viene.
    final metrosPorPixel =
        156543.03392 *
        math.cos(posicion.latitude * math.pi / 180) /
        math.pow(2, zoom);
    objetivo = adelantar(objetivo, rumbo, altoPantalla * 0.22 * metrosPorPixel);
  }

  const fraccion = 0.18;
  final dLat = objetivo.latitude - centro.latitude;
  final dLon = objetivo.longitude - centro.longitude;
  final dGiro = diferenciaAngular(giro, giroObjetivo);

  final cerca = dLat.abs() < 1e-7 && dLon.abs() < 1e-7 && dGiro.abs() < 0.2;
  // Lejos -abrir el mapa, o volver de mirar otra zona- se va de una: una
  // animacion de varios kilometros es un viaje en avion que nadie pidio.
  final lejos = dLat.abs() > 0.02 || dLon.abs() > 0.02;
  final f = cerca || lejos ? 1.0 : fraccion;

  return PasoDeCamara(
    LatLng(centro.latitude + dLat * f, centro.longitude + dLon * f),
    giro + dGiro * f,
    llego: cerca,
  );
}
