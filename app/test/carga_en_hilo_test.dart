import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/parcelas.dart';
import 'package:geomaps/core/ruteo.dart';
import 'package:geomaps/core/vias.dart';
import 'package:latlong2/latlong.dart';

/// Que los datos del predio sobrevivan el viaje al otro hilo.
///
/// `compute` no devuelve el mismo objeto: lo **copia** de un hilo al otro. Un
/// tipo que no se pueda copiar asi falla en tiempo de ejecucion y solo al
/// correrlo -el analizador no lo ve-, o sea que se descubriria en el potrero,
/// con el mapa sin abrir y sin ningun mensaje util.
///
/// Los datos del predio son confidenciales y no estan en el repositorio, que es
/// publico: si el asset no esta, el grupo se salta.
void main() {
  final vias = File('assets/zonas/guaicaramo-vias.json');
  final parcelas = File('assets/zonas/guaicaramo-parcelas.json');
  final hayDatos = vias.existsSync() && parcelas.existsSync();

  group('el parseo cruza de hilo', () {
    test('las vias llegan enteras', () async {
      final crudo = vias.readAsStringSync();
      final enElHilo = ViasPredio.deJson(crudo);
      final cruzadas = await compute(ViasPredio.deJson, crudo);

      expect(cruzadas.cuantas, enElHilo.cuantas);
      expect(cruzadas.cuantas, greaterThan(0));

      // Una coordenada concreta, no solo el conteo: un tipo que cruza a medias
      // -la lista si, los puntos vacios- pasaria una prueba de cantidad.
      final a = enElHilo.vias.first;
      final b = cruzadas.vias.first;
      expect(b.codBp, a.codBp);
      expect(b.tipo, a.tipo);
      expect(b.puntos.length, a.puntos.length);
      expect(b.puntos.first.latitude, a.puntos.first.latitude);
      expect(b.puntos.first.longitude, a.puntos.first.longitude);
    });

    test('las parcelas llegan enteras', () async {
      final crudo = parcelas.readAsStringSync();
      final enElHilo = ParcelasPredio.deJson(crudo);
      final cruzadas = await compute(ParcelasPredio.deJson, crudo);

      expect(cruzadas.parcelas.length, enElHilo.parcelas.length);
      expect(cruzadas.bloques.length, enElHilo.bloques.length);
      expect(cruzadas.parcelas, isNotEmpty);

      final a = enElHilo.parcelas.first;
      final b = cruzadas.parcelas.first;
      expect(b.codigo, a.codigo);
      expect(b.bloque, a.bloque);
      expect(b.hectareas, a.hectareas);
      expect(b.contorno.length, a.contorno.length);
      expect(b.centro.latitude, a.centro.latitude);
    });
  }, skip: hayDatos ? false : 'faltan los assets del predio');

  /// El grafo de ruteo tambien cruza, y con una red inventada: lo que se
  /// verifica es que el objeto sobreviva la copia y siga respondiendo lo
  /// mismo, no cuanto mide una via de Guaicaramo.
  test('el grafo de ruteo cruza de hilo y rutea igual', () async {
    const a = LatLng(4.4010, -72.9000);
    const c = LatLng(4.4010, -72.8900);
    const d = LatLng(4.4000, -72.9000);
    const f = LatLng(4.4000, -72.8900);
    Via via(List<LatLng> puntos) => Via(
      tipo: TipoVia.balastrada,
      interna: true,
      codBp: 'B.1-P.1',
      puntos: puntos,
    );
    final vias = ViasPredio([
      via([a, c]),
      via([d, f]),
      via([a, d]),
      via([c, f]),
    ]);

    final aca = RedVial.construir(vias).ruta(desde: a, hasta: f)!;
    final cruzada = (await compute(RedVial.construir, vias))
        .ruta(desde: a, hasta: f)!;

    expect(cruzada.metros, closeTo(aca.metros, 0.001));
    expect(cruzada.porLaVia.length, aca.porLaVia.length);
    expect(cruzada.porLaVia.first.latitude, aca.porLaVia.first.latitude);
  });
}
