import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:latlong2/latlong.dart';

/// El ruteo por las vias del predio.
///
/// Se prueba con una red inventada y no con la de Guaicaramo: los datos del
/// predio son confidenciales y no estan en el repositorio, y ademas una red
/// dibujada a mano es la unica forma de saber cual es la respuesta correcta.
///
/// La red de la prueba es una escalera de 1 km de lado:
///
///     A ---- B ---- C      lat 4.4010   (pavimentada, arriba)
///     |             |
///     D ---- E ---- F      lat 4.4000   (balastrada, abajo)
///
/// con los dos travesanos verticales en las puntas, y un ramal que entronca
/// contra el medio del tramo D-E sin compartir vertice.
void main() {
  // ~111 m por milesima de grado de latitud; a esta latitud la longitud anda
  // por 111 m tambien. Los numeros de la prueba se leen en esa escala.
  const arriba = 4.4010;
  const abajo = 4.4000;

  Via via(TipoVia tipo, List<LatLng> puntos, {String cod = 'B.1-P.1'}) =>
      Via(tipo: tipo, interna: true, codBp: cod, puntos: puntos);

  const a = LatLng(arriba, -72.9000);
  const b = LatLng(arriba, -72.8950);
  const c = LatLng(arriba, -72.8900);
  const d = LatLng(abajo, -72.9000);
  const e = LatLng(abajo, -72.8950);
  const f = LatLng(abajo, -72.8900);

  ViasPredio escalera({List<Via> extra = const []}) => ViasPredio([
    via(TipoVia.pavimentada, [a, b, c]),
    via(TipoVia.balastrada, [d, e, f]),
    via(TipoVia.balastrada, [a, d]),
    via(TipoVia.balastrada, [c, f]),
    ...extra,
  ]);

  test('arma un grafo conexo con las vias construidas', () {
    final red = RedVial.construir(escalera());

    // Seis vertices, aunque cuatro de ellos vienen repetidos en dos vias: los
    // extremos compartidos tienen que colapsar en un solo nodo, o no hay grafo.
    expect(red.cuantosNodos, 6);
    expect(red.cuantosTramos, 6);
  });

  test('la ruta va por la via y no en linea recta', () {
    final red = RedVial.construir(escalera());

    // De A a F: en recta son ~560 m en diagonal, pero por via hay que bajar o
    // cruzar. La ruta tiene que ser mas larga que la recta y pasar por nodos.
    final ruta = red.ruta(desde: a, hasta: f)!;

    expect(ruta.metros, greaterThan(1000));
    expect(ruta.porLaVia.length, greaterThan(2));
  });

  test('elige el lado corto de la escalera', () {
    final red = RedVial.construir(escalera());

    // De B (medio de arriba) a E (medio de abajo) hay dos caminos simetricos de
    // ~1.1 km. Cualquiera sirve, pero no puede salir uno de 2 km dando toda la
    // vuelta.
    final ruta = red.ruta(desde: b, hasta: e)!;
    expect(ruta.metros, lessThan(1300));
  });

  test('no rutea por vias proyectadas', () {
    // Un atajo directo B-E, pero proyectado: todavia no esta construido. La
    // ruta tiene que seguir dando la vuelta por la escalera.
    final conAtajo = escalera(
      extra: [
        via(TipoVia.proyectada, [b, e]),
      ],
    );
    final red = RedVial.construir(conAtajo);

    final ruta = red.ruta(desde: b, hasta: e)!;
    expect(ruta.metros, greaterThan(500));
  });

  test('usa el atajo cuando esta construido', () {
    final conAtajo = escalera(
      extra: [
        via(TipoVia.balastrada, [b, e]),
      ],
    );
    final red = RedVial.construir(conAtajo);

    final ruta = red.ruta(desde: b, hasta: e)!;
    // Ahora son los ~110 m del travesano del medio.
    expect(ruta.metros, lessThan(200));
  });

  test('suelda un ramal que entronca contra el medio de un tramo', () {
    // El ramal baja hasta un punto que cae sobre D-E pero no es un vertice de
    // D-E, y ademas queda a un metro largo: asi viene el KMZ de topografia.
    const entronque = LatLng(4.40001, -72.8975);
    const punta = LatLng(4.3990, -72.8975);
    final red = RedVial.construir(
      escalera(
        extra: [
          via(TipoVia.balastrada, [entronque, punta]),
        ],
      ),
    );

    // Sin soldadura el ramal quedaria aislado y no habria ruta hasta el.
    final ruta = red.ruta(desde: a, hasta: punta);
    expect(ruta, isNotNull);
    expect(ruta!.metros, greaterThan(100));
  });

  test('no inventa ruta para un punto lejos de toda via', () {
    final red = RedVial.construir(escalera());

    // A 20 km de la red. Decir "no hay ruta" es la respuesta correcta.
    expect(red.ruta(desde: a, hasta: const LatLng(4.6, -72.9)), isNull);
  });

  test('no inventa ruta entre dos pedazos que no se tocan', () {
    // Una via suelta a 5 km de la escalera: esta sobre la red, pero no hay
    // forma de llegar por via.
    final lejos = [
      const LatLng(4.4500, -72.9000),
      const LatLng(4.4500, -72.8900),
    ];
    final red = RedVial.construir(
      escalera(extra: [via(TipoVia.balastrada, lejos)]),
    );

    expect(red.ruta(desde: a, hasta: lejos.last), isNull);
  });

  test('separa los metros de via de los que hay que caminar', () {
    final red = RedVial.construir(escalera());

    // Un punto 200 m al norte de B: no esta sobre ninguna via.
    const enElLote = LatLng(4.4028, -72.8950);
    final ruta = red.ruta(desde: d, hasta: enElLote)!;

    expect(ruta.metrosDesdeLaVia, greaterThan(150));
    expect(ruta.metrosTotales, greaterThan(ruta.metros));
    // El tramo a pie es mas lento que el mismo largo en vehiculo.
    expect(ruta.minutos, greaterThan(ruta.minutosPorLaVia));
  });

  group('progreso sobre la ruta', () {
    final red = RedVial.construir(escalera());
    final ruta = red.ruta(desde: a, hasta: c)!;

    test('parado sobre la via, el desvio es casi cero', () {
      final p = ruta.progreso(b);
      expect(p.desvioM, lessThan(5));
      expect(p.hayQueRecalcular(5), isFalse);
    });

    test('avanzar por la ruta descuenta lo que falta', () {
      expect(
        ruta.progreso(b).metrosRestantes,
        lessThan(ruta.progreso(a).metrosRestantes),
      );
    });

    test('salirse de la via pide recalcular', () {
      // 200 m al norte de B: ninguna tolerancia de GPS explica eso.
      final p = ruta.progreso(const LatLng(4.4028, -72.8950));
      expect(p.desvioM, greaterThan(150));
      expect(p.hayQueRecalcular(5), isTrue);
    });

    test('un GPS malo no dispara un recalculo por si solo', () {
      // 50 m de desvio con un fix de 40 m de error es, probablemente, el mismo
      // lugar. Recalcular ahi cambia la ruta en la pantalla de alguien que va
      // manejando bien.
      final p = ruta.progreso(const LatLng(4.40145, -72.8950));
      expect(p.desvioM, greaterThan(ProgresoRuta.umbralM));
      expect(p.hayQueRecalcular(40), isFalse);
      expect(p.hayQueRecalcular(5), isTrue);
    });

    test('el corte entre lo recorrido y lo que falta cae sobre la ruta', () {
      // A mitad de A-B, 20 m al norte: el pie se lleva sobre la via, no queda
      // debajo de la posicion cruda.
      final p = ruta.progreso(const LatLng(4.40118, -72.8975));
      expect(p.pie.latitude, closeTo(arriba, 0.00002));
      expect(p.pie.longitude, closeTo(-72.8975, 0.00002));
      // Va por la via: ni en el tramo a pie del arranque ni en el del final.
      expect(p.segmento, greaterThan(0));
      expect(p.segmento, lessThan(ruta.completa.length - 2));
    });

    test('llegando al destino se da por llegado', () {
      expect(ruta.progreso(c).llego, isTrue);
      expect(ruta.progreso(a).llego, isFalse);
    });
  });
}
