import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Los acopios del predio: donde se deja el fruto cosechado para que lo recoja
/// el tractor.
///
/// Salen de la capa `Acopios` del plano del Departamento Agronomico via
/// `tools/acopios_guaicaramo.py`. Son puntos y no areas: lo que se necesita de
/// un acopio es **como se llega**, y para eso alcanza con la posicion.
class AcopiosPredio {
  const AcopiosPredio(this.acopios);

  /// Lee el asset y lo parsea fuera del hilo de la interfaz, como las vias y
  /// los lotes: los tres se cargan al abrir el mapa.
  static Future<AcopiosPredio> cargar(String archivo) async {
    final crudo = await rootBundle.loadString('assets/zonas/$archivo');
    return compute(deJson, crudo);
  }

  static AcopiosPredio deJson(String crudo) {
    final j = jsonDecode(crudo) as Map<String, dynamic>;
    final acopios = (j['acopios'] as List)
        .map((a) {
          final m = a as Map<String, dynamic>;
          return Acopio(
            numero: m['n'] as String,
            lote: m['l'] as String,
            punto: LatLng(
              (m['y'] as num).toDouble(),
              (m['x'] as num).toDouble(),
            ),
          );
        })
        .toList(growable: false);
    return AcopiosPredio(acopios);
  }

  final List<Acopio> acopios;

  /// Los que coinciden con lo que se escribio en el buscador.
  ///
  /// Se busca por numero y por lote a la vez, porque en campo se los nombra
  /// asi: "el 30 del B.9-P.2". Cada palabra tiene que aparecer en alguno de
  /// los dos; "30 b.9" encuentra el acopio 30 de todos los lotes del bloque 9.
  List<Acopio> buscar(String texto) {
    final palabras = texto
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (palabras.isEmpty) return acopios;

    // Primero los de numero exacto: buscar "3" no puede enterrar el acopio 3
    // debajo del 30, el 31 y el 300. Se separa en dos listas y no se ordena
    // porque `sort` no garantiza conservar el orden del plano entre iguales.
    final exactos = <Acopio>[];
    final resto = <Acopio>[];
    for (final a in acopios) {
      final numero = a.numero.toLowerCase();
      final lote = a.lote.toLowerCase();
      final coincide = palabras.every(
        (p) => numero.startsWith(p) || lote.contains(p),
      );
      if (!coincide) continue;
      (palabras.contains(numero) ? exactos : resto).add(a);
    }
    return [...exactos, ...resto];
  }
}

class Acopio {
  const Acopio({required this.numero, required this.lote, required this.punto});

  /// Como esta rotulado en el plano: `30`, `30A`. Puede venir vacio.
  ///
  /// Se repite entre lotes -hay un acopio 30 en muchos-, asi que a secas no
  /// identifica: lo que lo vuelve unico es el numero junto con el [lote].
  final String numero;

  /// El lote donde cae (`B.9-P.2`), o vacio si cae fuera de todo lote.
  final String lote;

  final LatLng punto;

  /// Como se lo nombra en pantalla: "Acopio 30".
  String get nombre => numero.isEmpty ? 'Acopio sin numero' : 'Acopio $numero';

  /// El nombre completo, con el lote: "Acopio 30 · B.9-P.2".
  String get etiqueta => lote.isEmpty ? nombre : '$nombre · $lote';
}
