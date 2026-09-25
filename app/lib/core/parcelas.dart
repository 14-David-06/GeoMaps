import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Los lotes del predio: las parcelas, agrupadas en bloques.
///
/// Salen del plano del Departamento Agronomico via
/// `tools/parcelas_guaicaramo.py`. Son los poligonos reales, no las etiquetas
/// sueltas del KMZ: un punto dice que hay un lote ahi, pero no donde termina, y
/// lo que se necesita en campo es justamente el lindero.
class ParcelasPredio {
  const ParcelasPredio({required this.parcelas, required this.bloques});

  /// Lee el asset y lo parsea **fuera del hilo de la interfaz**.
  ///
  /// Son 254 KB, 581 lotes y sus contornos. Ver `ViasPredio.cargar`: el motivo
  /// es el mismo, y los dos se cargan en el mismo momento -al abrir el mapa-,
  /// asi que sumaban su congelada.
  static Future<ParcelasPredio> cargar(String archivo) async {
    final crudo = await rootBundle.loadString('assets/zonas/$archivo');
    return compute(deJson, crudo);
  }

  /// El parseo puro, para que `compute` solo tenga que mandar el texto.
  static ParcelasPredio deJson(String crudo) {
    final j = jsonDecode(crudo) as Map<String, dynamic>;

    final parcelas = (j['parcelas'] as List)
        .map((p) {
          final m = p as Map<String, dynamic>;
          final planas = (m['c'] as List).cast<num>();

          final contorno = <LatLng>[];
          for (var i = 0; i + 1 < planas.length; i += 2) {
            contorno.add(
              LatLng(planas[i + 1].toDouble(), planas[i].toDouble()),
            );
          }

          return Parcela(
            codigo: m['p'] as String,
            bloque: m['b'] as String,
            hectareas: (m['h'] as num).toDouble(),
            centro: LatLng(
              (m['y'] as num).toDouble(),
              (m['x'] as num).toDouble(),
            ),
            contorno: contorno,
          );
        })
        .toList(growable: false);

    final bloques = (j['bloques'] as List)
        .map((b) {
          final m = b as Map<String, dynamic>;
          return Bloque(
            nombre: m['b'] as String,
            centro: LatLng(
              (m['lat'] as num).toDouble(),
              (m['lon'] as num).toDouble(),
            ),
            hectareas: (m['ha'] as num).toDouble(),
            cuantasParcelas: m['n'] as int,
          );
        })
        .toList(growable: false);

    return ParcelasPredio(parcelas: parcelas, bloques: bloques);
  }

  final List<Parcela> parcelas;
  final List<Bloque> bloques;
}

class Parcela {
  const Parcela({
    required this.codigo,
    required this.bloque,
    required this.hectareas,
    required this.centro,
    required this.contorno,
  });

  /// Como identifica el plano a este lote. Dos formas conviven:
  ///
  /// - **Codigo** (`B.10-P.9`), que es la mayoria. Va completo y no solo
  ///   `P.9` porque el numero de parcela se repite entre bloques -hay un `P.10`
  ///   en el B.4 y otro en el B.5-, asi que a secas es ambiguo.
  /// - **Nombre propio**, que son unos pocos. No son palma: son los lotes de
  ///   citricos, frutales y viveros del predio, y en campo se los llama asi.
  ///
  /// El resto viene sin rotulo en el plano. Se dibujan igual: el
  /// lindero vale aunque no se sepa el nombre.
  final String codigo;

  /// Si el rotulo es un codigo de bloque y parcela, y no un nombre propio.
  bool get esCodigo => _reCodigo.hasMatch(codigo);

  /// `B.10`. Vacio si la parcela no tiene codigo.
  final String bloque;

  final double hectareas;

  /// Un punto adentro del lote, para colgar la etiqueta. Es el punto
  /// representativo y no el centroide: en un lote con forma de ele, el
  /// centroide cae afuera y la etiqueta quedaria sobre el vecino.
  final LatLng centro;

  final List<LatLng> contorno;

  /// Como se lo nombra en pantalla, en una ficha o un listado.
  String get etiqueta => codigo.isEmpty ? 'Lote sin codigo' : codigo;

  /// El texto que se escribe **encima del lote en el mapa**, o nulo si no hay
  /// nada util que escribir.
  ///
  /// Se acorta a proposito. Un par de rotulos del plano llegan larguisimos
  /// -medio centenar de caracteres, dos rotulos vecinos que el emparejamiento
  /// por cercania junto- y escribir eso sobre un lote tapa el lote y los tres de
  /// al lado. El nombre
  /// completo sigue en `codigo` para cuando haya una ficha que lo muestre.
  String? get rotulo {
    if (codigo.isEmpty) return null;
    if (codigo.length <= _largoRotulo) return codigo;
    return '${codigo.substring(0, _largoRotulo - 1).trimRight()}…';
  }

  static const _largoRotulo = 18;
}

/// `B.10-P.9`, con o sin sufijos. Lo que sigue despues -"(R.)" de renovacion-
/// no identifica al lote.
final _reCodigo = RegExp(r'^B\.\d+-P\.\d+$');

class Bloque {
  const Bloque({
    required this.nombre,
    required this.centro,
    required this.hectareas,
    required this.cuantasParcelas,
  });

  final String nombre;
  final LatLng centro;
  final double hectareas;
  final int cuantasParcelas;
}
