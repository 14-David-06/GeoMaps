import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

/// Una zona de trabajo delimitada: el predio de un cliente, dibujado.
///
/// Sirve para responder una sola pregunta, y responderla **sin red**: estoy
/// parado adentro de este predio, si o no. De ahi cuelga que un mapa se habilite
/// o no: un mapa de 300 MB de Guaicaramo no tiene por que aparecer en un
/// telefono que esta en Villavicencio.
///
/// El poligono viene en un asset generado por `tools/perimetro_guaicaramo.py`
/// desde el plano del Departamento Agronomico. Ahi esta explicado de donde sale
/// y como se verifica.
class Zona {
  const Zona({
    required this.nombre,
    required this.sectores,
    required this.bbox,
  });

  factory Zona.deJson(Map<String, dynamic> j) {
    final sectores = (j['sectores'] as List)
        .map(
          (s) => (s as List)
              .map(
                (p) => PuntoLatLon(
                  lat: (p[1] as num).toDouble(),
                  lon: (p[0] as num).toDouble(),
                ),
              )
              .toList(growable: false),
        )
        .toList(growable: false);

    final b = (j['bbox'] as List).map((v) => (v as num).toDouble()).toList();
    return Zona(
      nombre: j['nombre'] as String,
      sectores: sectores,
      // En el archivo el bbox va en orden GeoJSON: lon/lat, no lat/lon.
      bbox: Caja(lonMin: b[0], latMin: b[1], lonMax: b[2], latMax: b[3]),
    );
  }

  /// Carga una zona de los assets. Es `async` una sola vez por arranque; el
  /// resultado se guarda del lado del provider.
  static Future<Zona> cargar(String archivo) async {
    final crudo = await rootBundle.loadString('assets/zonas/$archivo');
    return Zona.deJson(jsonDecode(crudo) as Map<String, dynamic>);
  }

  final String nombre;

  /// El predio puede no ser una sola mancha. Guaicaramo son cuatro sectores
  /// separados, y tratarlos como uno solo -uniendo por el hull- meteria adentro
  /// varios kilometros de tierra que no son de la plantacion.
  final List<List<PuntoLatLon>> sectores;

  /// El rectangulo que contiene todo. Es el descarte barato: una comparacion de
  /// cuatro numeros deja afuera al 99% de las posiciones del mundo sin recorrer
  /// unos cientos de vertices.
  final Caja bbox;

  /// Si el punto cae adentro del predio.
  bool contiene(PuntoLatLon p) {
    if (!bbox.contiene(p)) return false;
    for (final sector in sectores) {
      if (_dentroDelAnillo(p, sector)) return true;
    }
    return false;
  }

  /// Si el punto cae adentro del predio o a menos de [margenM] de su borde.
  ///
  /// El perimetro sale de unir los **lotes**, y lo que no es lote queda
  /// afuera: oficinas, planta, campamentos, reservas y buena parte de las vias
  /// entre sectores. Pararse ahi es estar en la plantacion, y el mapa se tiene
  /// que abrir igual.
  bool cerca(PuntoLatLon p, double margenM) =>
      contiene(p) || metrosAlBorde(p) <= margenM;

  /// Distancia al borde del predio en metros, para decirle a alguien que esta
  /// afuera **que tan afuera**. "Estas a 800 m del predio" y "estas a 40 km" son
  /// dos situaciones distintas: la primera se resuelve caminando.
  ///
  /// Devuelve 0 si esta adentro. No es exacta al metro y no hace falta que lo
  /// sea: es para orientar a una persona, no para medir un lindero.
  double metrosAlBorde(PuntoLatLon p) {
    if (contiene(p)) return 0;

    var minimo = double.infinity;
    for (final sector in sectores) {
      for (var i = 0; i < sector.length - 1; i++) {
        final d = _distanciaAlSegmento(p, sector[i], sector[i + 1]);
        if (d < minimo) minimo = d;
      }
    }
    return minimo;
  }

  /// Punto en poligono por lanzamiento de rayo.
  ///
  /// Se trabaja en grados sin proyectar. A esta latitud y para un predio de 20
  /// km, la deformacion no mueve ningun borde lo suficiente como para cambiar
  /// una respuesta que ya lleva 50 m de margen.
  static bool _dentroDelAnillo(PuntoLatLon p, List<PuntoLatLon> anillo) {
    var dentro = false;
    var j = anillo.length - 1;
    for (var i = 0; i < anillo.length; i++) {
      final a = anillo[i];
      final b = anillo[j];
      if ((a.lat > p.lat) != (b.lat > p.lat)) {
        final corte =
            (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon;
        if (p.lon < corte) dentro = !dentro;
      }
      j = i;
    }
    return dentro;
  }

  static double _distanciaAlSegmento(
    PuntoLatLon p,
    PuntoLatLon a,
    PuntoLatLon b,
  ) {
    // Plano local: los grados se pasan a metros con el factor de la latitud del
    // punto. Sobre unos pocos kilometros es indistinguible de hacerlo bien.
    final mPorLon = _metrosPorGradoLon(p.lat);
    final px = (p.lon - a.lon) * mPorLon;
    final py = (p.lat - a.lat) * _metrosPorGradoLat;
    final bx = (b.lon - a.lon) * mPorLon;
    final by = (b.lat - a.lat) * _metrosPorGradoLat;

    final largo2 = bx * bx + by * by;
    // Segmento degenerado: dos vertices repetidos. Se mide contra el vertice.
    if (largo2 == 0) return math.sqrt(px * px + py * py);

    var t = (px * bx + py * by) / largo2;
    t = t.clamp(0.0, 1.0);
    final dx = px - t * bx;
    final dy = py - t * by;
    return math.sqrt(dx * dx + dy * dy);
  }

  static const _metrosPorGradoLat = 110540.0;

  static double _metrosPorGradoLon(double lat) =>
      111320.0 * math.cos(lat * math.pi / 180);
}

class PuntoLatLon {
  const PuntoLatLon({required this.lat, required this.lon});

  final double lat;
  final double lon;
}

/// Un rectangulo en grados.
class Caja {
  const Caja({
    required this.latMin,
    required this.lonMin,
    required this.latMax,
    required this.lonMax,
  });

  final double latMin;
  final double lonMin;
  final double latMax;
  final double lonMax;

  bool contiene(PuntoLatLon p) =>
      p.lat >= latMin && p.lat <= latMax && p.lon >= lonMin && p.lon <= lonMax;
}
