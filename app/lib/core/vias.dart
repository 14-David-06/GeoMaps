import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Las vias de un predio, para dibujarlas sobre el mapa.
///
/// Salen del KMZ de topografia via `tools/vias_guaicaramo.py`, que las deja en
/// un formato plano: el asset no es GeoJSON porque esto se parsea en un telefono
/// de campo mientras la app abre, y la sintaxis repetida de GeoJSON cuesta mas
/// de la mitad del archivo sin aportar nada.
class ViasPredio {
  const ViasPredio(this.vias);

  /// Lee el asset y lo parsea **fuera del hilo de la interfaz**.
  ///
  /// Son 353 KB y 1.664 vias: parsearlos donde corre la pantalla congela la
  /// app justo al abrir el mapa, que es el peor momento posible. `compute` lo
  /// manda a otro hilo; lo que se pierde son unos milisegundos en arrancarlo y
  /// en copiar el resultado de vuelta, contra una pantalla que no se traba.
  static Future<ViasPredio> cargar(String archivo) async {
    final crudo = await rootBundle.loadString('assets/zonas/$archivo');
    return compute(deJson, crudo);
  }

  /// El parseo puro. Es estatico y recibe el texto -no el mapa ya decodificado-
  /// porque asi es lo unico que `compute` necesita mandar al otro hilo, y
  /// porque deja la prueba corriendo sin levantar el binding de Flutter.
  static ViasPredio deJson(String crudo) {
    final j = jsonDecode(crudo) as Map<String, dynamic>;
    final tipos = (j['tipos'] as List).cast<String>();

    final vias = (j['vias'] as List)
        .map((v) {
          final m = v as Map<String, dynamic>;
          final planas = (m['c'] as List).cast<num>();

          // El array viene plano -lon, lat, lon, lat...- y se rearma de a pares.
          final puntos = <LatLng>[];
          for (var i = 0; i + 1 < planas.length; i += 2) {
            puntos.add(LatLng(planas[i + 1].toDouble(), planas[i].toDouble()));
          }

          return Via(
            tipo: TipoVia.desdeNombre(tipos[m['t'] as int]),
            interna: (m['i'] as int) == 1,
            codBp: m['b'] as String,
            puntos: puntos,
          );
        })
        .toList(growable: false);

    return ViasPredio(vias);
  }

  final List<Via> vias;

  int get cuantas => vias.length;
}

class Via {
  const Via({
    required this.tipo,
    required this.interna,
    required this.codBp,
    required this.puntos,
  });

  final TipoVia tipo;

  /// Si es una via del predio o una de afuera que solo pasa cerca.
  final bool interna;

  /// El bloque y la parcela a la que sirve (`B.10-P.9`). Puede venir vacio.
  ///
  /// El numero de parcela se repite entre bloques -hay un `P.10` en el B.4 y
  /// otro en el B.5-, asi que el codigo completo es lo unico que identifica.
  final String codBp;

  final List<LatLng> puntos;
}

/// De que es la via, que es lo que decide como se dibuja.
///
/// La distincion que de verdad importa es `proyectada`: son vias que **todavia
/// no existen**. Pintarlas como las demas manda a alguien a buscar una entrada
/// que no esta construida, y en un predio de miles de hectareas eso es un rodeo de
/// kilometros con el fruto arriba del tractor.
enum TipoVia {
  pavimentada('Pavimentada'),
  balastrada('Balastrada'),
  ruta('Ruta'),
  proyectada('Proyectada');

  const TipoVia(this.etiqueta);

  final String etiqueta;

  /// El plano trae `BalastradaP1` y `BalastradaP2` -una via balastrada partida
  /// en dos tramos de obra- que en el terreno son lo mismo que una balastrada.
  static TipoVia desdeNombre(String nombre) {
    if (nombre.startsWith('Balastrada')) return TipoVia.balastrada;
    return TipoVia.values.firstWhere(
      (t) => t.etiqueta == nombre,
      orElse: () => TipoVia.balastrada,
    );
  }

  /// Si existe en el terreno hoy.
  bool get construida => this != TipoVia.proyectada;
}
