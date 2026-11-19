import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geomaps/core/rumbo.dart';
import 'package:latlong2/latlong.dart';

/// Las cuentas del rumbo y de la camara que sigue a la posicion.
///
/// Lo que se cuida es lo que marea o confunde en campo: una flecha que apunta
/// a cualquier lado estando quieto, un mapa que da la vuelta entera al cruzar
/// el norte, y una camara que salta o que no termina nunca de acomodarse.
void main() {
  Position fix({double velocidad = 0, double rumbo = 0}) => Position(
    latitude: 4.40,
    longitude: -72.90,
    timestamp: DateTime.utc(2026, 11, 18, 15),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: rumbo,
    headingAccuracy: 0,
    speed: velocidad,
    speedAccuracy: 0,
  );

  group('el rumbo del GPS', () {
    test('quieto no se le cree: gira solo', () {
      expect(rumboConfiable(fix(velocidad: 0.3, rumbo: 210)), isNull);
    });

    test('caminando de verdad, si', () {
      expect(rumboConfiable(fix(velocidad: 1.5, rumbo: 210)), 210);
    });

    test('un valor que no es un angulo se descarta', () {
      expect(rumboConfiable(fix(velocidad: 8, rumbo: double.nan)), isNull);
      expect(rumboConfiable(fix(velocidad: 8, rumbo: -1)), isNull);
      expect(rumboConfiable(fix(velocidad: 8, rumbo: 400)), isNull);
    });
  });

  group('la diferencia entre dos angulos', () {
    test('va por el lado corto al cruzar el norte', () {
      expect(diferenciaAngular(350, 10), 20);
      expect(diferenciaAngular(10, 350), -20);
    });

    test('sirve con los giros negativos que usa el mapa', () {
      // El mapa gira al reves que el rumbo: -350 y -10 estan a 20 grados.
      expect(diferenciaAngular(-10, -350), closeTo(20, 1e-9));
      expect(diferenciaAngular(0, -90), -90);
    });

    test('nunca pasa de media vuelta', () {
      for (var a = -720.0; a <= 720; a += 37) {
        for (var b = -720.0; b <= 720; b += 41) {
          expect(diferenciaAngular(a, b).abs(), lessThanOrEqualTo(180));
        }
      }
    });
  });

  group('adelantar un punto', () {
    const aca = LatLng(4.40, -72.90);
    const metros = Distance();

    test('queda a esa distancia', () {
      for (final rumbo in [0.0, 45.0, 90.0, 200.0, 315.0]) {
        final alla = adelantar(aca, rumbo, 300);
        expect(metros.distance(aca, alla), closeTo(300, 3), reason: '$rumbo');
      }
    });

    test('hacia donde dice el rumbo', () {
      expect(adelantar(aca, 0, 100).latitude, greaterThan(aca.latitude));
      expect(adelantar(aca, 90, 100).longitude, greaterThan(aca.longitude));
      expect(adelantar(aca, 180, 100).latitude, lessThan(aca.latitude));
      expect(adelantar(aca, 270, 100).longitude, lessThan(aca.longitude));
    });
  });

  group('un cuadro de la camara', () {
    const posicion = LatLng(4.4000, -72.9000);

    PasoDeCamara paso({
      LatLng centro = const LatLng(4.4010, -72.9000),
      double giro = 0,
      double? rumbo,
      bool conRumbo = false,
    }) => pasoDeCamara(
      centro: centro,
      giro: giro,
      zoom: 17,
      posicion: posicion,
      rumbo: rumbo,
      conRumbo: conRumbo,
      altoPantalla: 760,
    );

    test('se acerca de a poco, sin saltar', () {
      final p = paso();

      // Estaba 0,001 grados al norte: recorre una parte y no todo.
      expect(p.centro.latitude, lessThan(4.4010));
      expect(p.centro.latitude, greaterThan(4.4000));
      expect(p.llego, isFalse);
    });

    test('cuadro a cuadro termina llegando, y avisa', () {
      var centro = const LatLng(4.4010, -72.8990);
      var cuadros = 0;
      var llego = false;
      while (!llego && cuadros < 400) {
        final p = paso(centro: centro);
        centro = p.centro;
        llego = p.llego;
        cuadros++;
      }

      expect(llego, isTrue, reason: 'la camara no puede quedarse animando');
      expect(centro.latitude, closeTo(posicion.latitude, 1e-6));
      expect(centro.longitude, closeTo(posicion.longitude, 1e-6));
    });

    test('desde lejos va de una: no hay viaje en avion', () {
      final p = paso(centro: const LatLng(4.60, -74.08));

      expect(p.centro.latitude, closeTo(posicion.latitude, 1e-9));
      expect(p.centro.longitude, closeTo(posicion.longitude, 1e-9));
    });

    test('con el norte arriba, vuelve el giro a cero', () {
      final p = paso(centro: posicion, giro: -40);

      expect(p.giro, greaterThan(-40));
      expect(p.giro, lessThan(0));
    });

    test('en modo navegador gira hacia donde se va, por el lado corto', () {
      // Mapa girado para ir al norte-noroeste (350) y ahora se va al 10.
      final p = paso(giro: -350, rumbo: 10, conRumbo: true);

      // Tiene que pasar por el norte (-360), no desandar toda la vuelta.
      expect(p.giro, lessThan(-350));
      expect(p.giro, greaterThan(-370));
    });

    test('en modo navegador la flecha queda abajo: se mira adelante', () {
      // Yendo al norte, el centro de la camara va al norte de la posicion.
      final p = paso(centro: posicion, rumbo: 0, conRumbo: true);

      expect(p.centro.latitude, greaterThan(posicion.latitude));
      expect(p.centro.longitude, closeTo(posicion.longitude, 1e-9));
    });

    test('en modo navegador sin rumbo se queda con el giro que tenia', () {
      // Quieto y sin brujula: volver al norte y girar de nuevo marea.
      final p = paso(centro: posicion, giro: -120, conRumbo: true);

      expect(p.giro, -120);
      expect(p.llego, isTrue);
    });
  });
}
