import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/indicaciones.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:latlong2/latlong.dart';

/// Las indicaciones habladas de una ruta.
///
/// Son para quien maneja con las manos en el volante y para quien no alcanza
/// a leer la pantalla. Lo que se prueba es que digan lo justo: el giro donde
/// hay que girar -y solo ahi-, con tiempo para prepararse, y cuanto falta sin
/// hablar de mas.
///
/// La red es una cuadricula inventada, como la de una plantacion:
///
///                V1          V2          V3
///                |           |           |
///     lat 4.4030 +           +           +
///                |           |           |
///     lat 4.4000 O-----------+-----------+-----------+   H (de oeste a este)
///                |           |           |
///     lat 4.3970 +           +           +
///
/// Cada cuadra mide unos 330 m de alto y 330 de ancho.
void main() {
  const hLat = 4.4000;
  const norte = 4.4030;
  const sur = 4.3970;
  const oeste = -72.9000;
  const lon1 = -72.8970;
  const lon2 = -72.8940;
  const lon3 = -72.8910;
  const este = -72.8880;

  Via via(List<LatLng> puntos) => Via(
    tipo: TipoVia.balastrada,
    interna: true,
    codBp: 'B.1-P.1',
    puntos: puntos,
  );

  RedVial cuadricula({List<Via> extra = const []}) => RedVial.construir(
    ViasPredio([
      via(const [
        LatLng(hLat, oeste),
        LatLng(hLat, lon1),
        LatLng(hLat, lon2),
        LatLng(hLat, lon3),
        LatLng(hLat, este),
      ]),
      for (final lon in [lon1, lon2, lon3])
        via([LatLng(norte, lon), LatLng(hLat, lon), LatLng(sur, lon)]),
      ...extra,
    ]),
  );

  /// Camina la ruta de punta a punta, de a diez metros, y junta lo que la
  /// guia va diciendo.
  List<String> recorrer(Ruta ruta, GuiaRuta guia) {
    final dicho = <String>[];
    final linea = ruta.completa;
    const distancia = Distance();
    for (var i = 0; i < linea.length - 1; i++) {
      final largo = distancia(linea[i], linea[i + 1]);
      for (var m = 0.0; m < largo; m += 10) {
        final t = m / largo;
        final p = LatLng(
          linea[i].latitude + (linea[i + 1].latitude - linea[i].latitude) * t,
          linea[i].longitude +
              (linea[i + 1].longitude - linea[i].longitude) * t,
        );
        final frase = guia.alAvanzar(ruta.progreso(p));
        if (frase != null) dicho.add(frase);
      }
    }
    return dicho;
  }

  group('los giros', () {
    test('se gira donde la ruta dobla en un cruce', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(norte, lon2),
      )!;

      final maniobras = maniobrasDe(ruta);

      expect(maniobras, hasLength(1));
      expect(maniobras.single.giro, Giro.izquierda);
      expect(maniobras.single.punto.longitude, closeTo(lon2, 0.00001));
      // Desde el cruce quedan las tres cuadras... no: una cuadra, al norte.
      expect(maniobras.single.faltanAlFinalM, closeTo(332, 5));
    });

    test('hacia el otro lado es a la derecha', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(sur, lon2),
      )!;

      expect(maniobrasDe(ruta).single.giro, Giro.derecha);
    });

    test('pasar derecho por un cruce no se anuncia', () {
      // De punta a punta por la horizontal: tres cruces, ningun giro.
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(hLat, este),
      )!;

      expect(ruta.cruces, hasLength(3));
      expect(maniobrasDe(ruta), isEmpty);
    });

    test('una curva de la misma via no es un giro', () {
      // Una via sola que dobla en angulo recto: no hay para donde
      // equivocarse, y una voz que habla en cada curva se deja de escuchar.
      final red = RedVial.construir(
        ViasPredio([
          via(const [
            LatLng(hLat, oeste),
            LatLng(hLat, lon1),
            LatLng(norte, lon1),
          ]),
        ]),
      );
      final ruta = red.ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(norte, lon1),
      )!;

      expect(ruta.cruces, isEmpty);
      expect(maniobrasDe(ruta), isEmpty);
    });

    test('el vertice de al lado del cruce no confunde el angulo', () {
      // Las vias estan dibujadas a mano: a un metro del cruce hay otro
      // vertice, apenas corrido. El giro se mide mirando mas lejos.
      final red = RedVial.construir(
        ViasPredio([
          via(const [
            LatLng(hLat, oeste),
            LatLng(hLat + 0.00002, lon1 - 0.00003),
            LatLng(hLat, lon1),
            LatLng(hLat, lon2),
          ]),
          via(const [
            LatLng(norte, lon1),
            LatLng(hLat + 0.00003, lon1 + 0.00002),
            LatLng(hLat, lon1),
            LatLng(sur, lon1),
          ]),
        ]),
      );
      final ruta = red.ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(norte, lon1),
      )!;

      expect(maniobrasDe(ruta).single.giro, Giro.izquierda);
    });

    test('volver por donde se vino es dar la vuelta', () {
      // Una Y cerrada: se llega por una rama y se sale por la otra, casi en
      // sentido contrario.
      final red = RedVial.construir(
        ViasPredio([
          via(const [LatLng(hLat, oeste), LatLng(hLat, lon1)]),
          via(const [LatLng(hLat, lon1), LatLng(hLat + 0.0003, oeste)]),
          via(const [LatLng(hLat, lon1), LatLng(hLat, lon2)]),
        ]),
      );
      final ruta = red.ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(hLat + 0.0003, oeste),
      )!;

      expect(maniobrasDe(ruta).single.giro, Giro.vuelta);
    });
  });

  group('lo que se va diciendo', () {
    test('cada giro dos veces: con tiempo, y al llegar al cruce', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(norte, lon2),
      )!;

      final dicho = recorrer(ruta, GuiaRuta(ruta, destino: 'Acopio 38'));

      expect(dicho, [
        'Faltan 500 metros.',
        'En 150 metros, gira a la izquierda.',
        'Gira a la izquierda.',
        'Faltan 200 metros.',
      ]);
    });

    test('yendo derecho solo dice cuanto falta', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(hLat, este),
      )!;

      final dicho = recorrer(ruta, GuiaRuta(ruta));

      // Son 1.300 metros: el kilometro queda demasiado cerca de la salida
      // para anunciarlo.
      expect(dicho, ['Faltan 500 metros.', 'Faltan 200 metros.']);
    });

    test('dos giros pegados se dicen juntos', () {
      // Un zigzag: se dobla a la derecha y a los 40 metros a la izquierda.
      // Despues del primer giro no hay tiempo de avisar el segundo.
      const codo = 0.00036; // unos 40 m
      final red = cuadricula(
        extra: [
          via(const [LatLng(hLat - codo, lon1), LatLng(hLat - codo, lon2)]),
        ],
      );
      final ruta = red.ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(hLat - codo, lon1 + 0.002),
      )!;
      expect(maniobrasDe(ruta).map((m) => m.giro), [
        Giro.derecha,
        Giro.izquierda,
      ]);

      final dicho = recorrer(ruta, GuiaRuta(ruta));

      expect(
        dicho,
        contains('Gira a la derecha, y enseguida gira a la izquierda.'),
      );
      expect(
        dicho.where((f) => f.contains('izquierda')),
        hasLength(1),
        reason: 'el segundo giro no se repite por separado',
      );
    });

    test('donde termina la via lo dice, con el lado', () {
      // El punto queda 80 metros lote adentro, al sur de la horizontal.
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(hLat - 0.00072, lon1 + 0.0015),
      )!;
      expect(ruta.metrosDesdeLaVia, closeTo(80, 3));

      final dicho = recorrer(ruta, GuiaRuta(ruta));

      expect(
        dicho.last,
        'Hasta aquí llega la vía. El punto queda a 80 metros, a pie, a tu '
        'derecha.',
      );
    });

    test('no repite nada si el GPS se queda quieto o salta', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(norte, lon2),
      )!;
      final guia = GuiaRuta(ruta);
      // Parado a 30 m del cruce, con el GPS bailando.
      final cerca = ruta.progreso(const LatLng(hLat, lon2 - 0.00027));

      final dicho = [for (var i = 0; i < 20; i++) guia.alAvanzar(cerca)]
          .whereType<String>();

      expect(dicho, ['Gira a la izquierda.']);
    });

    test('quien sale cerca del destino no oye hitos que ya pasaron', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, lon1 + 0.0005),
        hasta: const LatLng(hLat, lon2),
      )!;
      expect(ruta.metrosTotales, lessThan(300));

      expect(recorrer(ruta, GuiaRuta(ruta)), isEmpty);
    });

    test('al empezar dice a donde va y cuanto es', () {
      final ruta = cuadricula().ruta(
        desde: const LatLng(hLat, oeste),
        hasta: const LatLng(norte, lon2),
      )!;

      final conNombre = GuiaRuta(ruta, destino: 'Acopio 38');
      expect(
        conNombre.alEmpezar(),
        'Ruta a Acopio 38. Un kilómetro, unos 2 minutos.',
      );
      expect(conNombre.alLlegar(), 'Llegaste a Acopio 38.');

      final sinNombre = GuiaRuta(ruta);
      expect(sinNombre.alEmpezar(), startsWith('Ruta al punto marcado.'));
      expect(sinNombre.alLlegar(), 'Llegaste al punto marcado.');
    });
  });

  group('como se dicen las medidas', () {
    test('las distancias, redondeadas', () {
      expect(decirDistancia(8), '10 metros');
      expect(decirDistancia(35), '40 metros');
      expect(decirDistancia(143), '150 metros');
      expect(decirDistancia(480), '500 metros');
      expect(decirDistancia(980), 'un kilómetro');
      expect(decirDistancia(1480), 'un kilómetro y medio');
      expect(decirDistancia(2100), '2 kilómetros');
      expect(decirDistancia(6400), '6 kilómetros y medio');
    });

    test('los tiempos, redondeados', () {
      expect(decirMinutos(0.6), 'un minuto');
      expect(decirMinutos(4.4), 'unos 4 minutos');
      expect(decirMinutos(58), 'una hora');
      expect(decirMinutos(95), 'una hora y media');
      expect(decirMinutos(125), 'unas 2 horas');
    });
  });
}
