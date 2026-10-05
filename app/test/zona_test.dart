import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/zona.dart';

/// El perimetro del predio: que la geometria responda bien adentro y afuera.
///
/// **Ninguna coordenada del predio esta escrita aca.** Los datos del cliente son
/// confidenciales y este repositorio es publico, asi que los puntos de prueba
/// se derivan del propio asset y las unicas coordenadas literales son de
/// ciudades, que son informacion publica.
///
/// Si el asset no esta -un clon sin los datos, que es lo normal- las pruebas
/// que lo necesitan se saltan en vez de fallar. Lo que no se puede es que
/// fallen y empujen a alguien a commitear los datos para "arreglar" la suite.
void main() {
  final archivo = File('assets/zonas/guaicaramo.json');
  final hayDatos = archivo.existsSync();

  late Zona zona;

  setUpAll(() {
    if (!hayDatos) return;
    zona = Zona.deJson(
      jsonDecode(archivo.readAsStringSync()) as Map<String, dynamic>,
    );
  });

  group(
    'con los datos del predio',
    skip: hayDatos
        ? false
        : 'sin assets/zonas/guaicaramo.json (son confidenciales; '
              'ver assets/zonas/LEEME.md para generarlos)',
    () {
      test('el asset trae sectores con suficiente detalle', () {
        expect(zona.nombre, isNotEmpty);
        expect(zona.sectores, isNotEmpty);
        expect(
          zona.sectores.map((s) => s.length).reduce((a, b) => a + b),
          greaterThan(500),
          reason: 'el perimetro perdio vertices: se simplifico de mas',
        );
      });

      test('todos los lotes del predio caen adentro del perimetro', () {
        // El control que de verdad importa, y contra una fuente independiente:
        // el perimetro se armo uniendo los lotes, asi que si alguno queda
        // afuera, el cierre o el margen se calcularon mal y el mapa se apagaria
        // parado justo en ese lote.
        //
        // Los puntos salen del asset de parcelas -su punto representativo, que
        // esta garantizado adentro del lote- y no de coordenadas escritas aca.
        final lotes = File('assets/zonas/guaicaramo-parcelas.json');
        if (!lotes.existsSync()) {
          markTestSkipped('sin el asset de parcelas');
          return;
        }

        final j = jsonDecode(lotes.readAsStringSync()) as Map<String, dynamic>;
        final puntos = (j['parcelas'] as List).map((p) {
          final m = p as Map<String, dynamic>;
          return PuntoLatLon(
            lat: (m['y'] as num).toDouble(),
            lon: (m['x'] as num).toDouble(),
          );
        });

        final afuera = puntos.where((p) => !zona.contiene(p)).length;
        expect(afuera, 0);
      });

      test('los vertices del borde estan dentro del bbox declarado', () {
        for (final sector in zona.sectores) {
          for (final p in sector) {
            expect(zona.bbox.contiene(p), isTrue);
          }
        }
      });

      group('afuera del predio', () {
        // Ciudades, no datos del cliente. Sirven porque estan lejos: sin el
        // perimetro al lado, no dicen nada de donde queda el predio.
        const lugares = <String, PuntoLatLon>{
          'Bogota': PuntoLatLon(lat: 4.7110, lon: -74.0721),
          'Madrid': PuntoLatLon(lat: 40.4168, lon: -3.7038),
          'Oceano Atlantico': PuntoLatLon(lat: 0, lon: 0),
        };

        for (final entrada in lugares.entries) {
          test(entrada.key, () {
            expect(zona.contiene(entrada.value), isFalse);
          });
        }
      });

      test('a mas de un grado del predio, el borde queda lejisimos', () {
        // Un grado son mas de 100 km. Se construye desde el bbox del asset
        // para no escribir una coordenada del predio.
        final lejos = PuntoLatLon(
          lat: zona.bbox.latMax + 1.5,
          lon: zona.bbox.lonMax + 1.5,
        );
        expect(zona.contiene(lejos), isFalse);
        expect(zona.metrosAlBorde(lejos), greaterThan(100000));
      });

      test('apenas afuera del borde, la distancia es chica', () {
        // Justo al norte del predio: fuera, pero a pocos kilometros. Es la
        // diferencia entre decir "estas a 800 m" y "estas a 78 km".
        final apenasAfuera = PuntoLatLon(
          lat: zona.bbox.latMax + 0.002,
          lon: (zona.bbox.lonMin + zona.bbox.lonMax) / 2,
        );
        expect(zona.contiene(apenasAfuera), isFalse);
        expect(zona.metrosAlBorde(apenasAfuera), lessThan(5000));
      });
    },
  );

  group('la geometria, sin datos reales', () {
    // Un cuadrado de un grado de lado en medio del Atlantico. No es el predio
    // de nadie y prueba exactamente lo mismo: que el rayo cuente bien los
    // cruces y que la distancia al borde de un punto interior sea cero.
    final cuadrado = Zona(
      nombre: 'Prueba',
      sectores: const [
        [
          PuntoLatLon(lat: 0, lon: 0),
          PuntoLatLon(lat: 0, lon: 1),
          PuntoLatLon(lat: 1, lon: 1),
          PuntoLatLon(lat: 1, lon: 0),
          PuntoLatLon(lat: 0, lon: 0),
        ],
      ],
      bbox: const Caja(latMin: 0, lonMin: 0, latMax: 1, lonMax: 1),
    );

    test('adentro es adentro', () {
      expect(cuadrado.contiene(const PuntoLatLon(lat: 0.5, lon: 0.5)), isTrue);
      expect(cuadrado.metrosAlBorde(const PuntoLatLon(lat: 0.5, lon: 0.5)), 0);
    });

    test('afuera es afuera, aunque comparta latitud', () {
      expect(cuadrado.contiene(const PuntoLatLon(lat: 0.5, lon: 2)), isFalse);
      expect(cuadrado.contiene(const PuntoLatLon(lat: 2, lon: 0.5)), isFalse);
    });

    test('el bbox corta antes de recorrer los vertices', () {
      expect(cuadrado.contiene(const PuntoLatLon(lat: 40, lon: -3)), isFalse);
    });

    test('la distancia al borde se mide en metros', () {
      // Medio grado al norte del cuadrado: ~55 km, que es medio grado de
      // latitud. Si la cuenta estuviera en grados, daria 0,5.
      final d = cuadrado.metrosAlBorde(const PuntoLatLon(lat: 1.5, lon: 0.5));
      expect(d, inInclusiveRange(50000, 60000));
    });

    test('cerca acepta lo que queda a menos del margen del borde', () {
      // ~1,1 km al norte del borde: afuera del poligono, adentro del margen.
      const alLado = PuntoLatLon(lat: 1.01, lon: 0.5);
      expect(cuadrado.contiene(alLado), isFalse);
      expect(cuadrado.cerca(alLado, 3000), isTrue);
      expect(cuadrado.cerca(alLado, 500), isFalse);
      expect(cuadrado.cerca(const PuntoLatLon(lat: 0.5, lon: 0.5), 0), isTrue);
    });
  });
}
