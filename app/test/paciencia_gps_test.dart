import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/state/gps.dart';

/// Cuanto espera la app sin un fix antes de reabrir el GPS.
///
/// Sin internet no hay GPS asistido: el telefono tiene que bajar del satelite
/// lo que con red le llega en un segundo, y eso pide entre uno y varios
/// minutos **seguidos** de escucha. Reabrir el GPS cada 40 segundos -como se
/// hacia- le cortaba esa escucha justo antes de terminar, una y otra vez. Lo
/// que se prueba es que la espera se alargue mientras el fix no llega, y que
/// vuelva a ser corta en cuanto llega.
void main() {
  final inicio = DateTime(2026, 11, 18, 6);
  DateTime a(int segundos) => inicio.add(Duration(seconds: segundos));

  test('el primer cambio de proveedor sigue siendo a los 40 segundos', () {
    final p = PacienciaGps();

    expect(p.seAgoto(a(40), inicio), isFalse);
    expect(p.seAgoto(a(41), inicio), isTrue);
  });

  test('despues de cada cambio espera el doble', () {
    final p = PacienciaGps();

    p.alCambiar();
    expect(p.espera, const Duration(seconds: 80));
    expect(p.seAgoto(a(60), inicio), isFalse, reason: 'antes cortaba aca');
    expect(p.seAgoto(a(81), inicio), isTrue);

    p.alCambiar();
    expect(p.espera, const Duration(seconds: 160));
  });

  test('no espera mas de cinco minutos', () {
    final p = PacienciaGps();
    for (var i = 0; i < 12; i++) {
      p.alCambiar();
    }

    expect(p.espera, const Duration(minutes: 5));
  });

  test('con un fix vuelve a la espera corta', () {
    // El que se queda sin senal bajo la palma despues de andar bien no tiene
    // por que esperar cinco minutos a que se pruebe el otro proveedor.
    final p = PacienciaGps()
      ..alCambiar()
      ..alCambiar()
      ..alFix();

    expect(p.espera, const Duration(seconds: 40));
  });

  test('en diez minutos sin fix reabre tres veces, no trece', () {
    final p = PacienciaGps();
    var desde = inicio;
    final cambios = <int>[];
    // El vigia mira cada 15 segundos.
    for (var s = 15; s <= 600; s += 15) {
      if (p.seAgoto(a(s), desde)) {
        p.alCambiar();
        desde = a(s);
        cambios.add(s);
      }
    }

    // Antes: a los 45, 90, 135... trece veces. Ahora cada tramo es mas largo
    // que el anterior, y el ultimo le deja al GPS cinco minutos seguidos.
    expect(cambios, [45, 135, 300]);
  });
}
