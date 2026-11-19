import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'importar_geopdf.dart' show ArchivosPlano;

/// El detalle de un plano grande: la misma hoja dibujada mas grande, partida
/// en cuadros.
///
/// ## Por que
///
/// Un plano se guarda como una sola imagen de hasta 4096 pixeles de lado, que
/// es lo que un telefono sabe mostrar de una pieza. A una hoja de topografia
/// eso le sobra; a un pliego -un mapa vial del departamento- lo deja en menos
/// de 90 puntos por pulgada, y al acercarse los nombres de las veredas son
/// una mancha.
///
/// La imagen entera se sigue haciendo, igual que siempre: es lo que se ve con
/// el plano alejado. Encima, cuando la hoja es grande, se dibuja **la misma
/// hoja al doble o mas de tamano, en cuadros**. De cerca el mapa pone solo
/// los cuadros que caen en la pantalla, asi que se ve nitido sin abrir nunca
/// una imagen gigante.
///
/// ## Donde queda
///
/// En una carpeta al lado de la imagen del plano, con un indice (`detalle.json`)
/// que dice cuantos cuadros son y cuales ya estan. No va en la base: si la
/// carpeta no esta, o esta a medias, el plano se ve con su imagen de siempre
/// y no hay dos datos que puedan quedar desacomodados.
class DetallePlano {
  const DetallePlano({
    required this.anchoVista,
    required this.altoVista,
    required this.ancho,
    required this.alto,
    this.lado = ladoDeCuadro,
    this.listos = const {},
    this.trabajo,
  });

  /// Los pixeles de cada cuadro. Chicos a proposito: en pantalla entran unos
  /// pocos a la vez, y lo que se abre de mas por los bordes es poco.
  static const ladoDeCuadro = 1024;

  /// Tope de pixeles del lado largo del detalle: el doble de la imagen entera.
  /// Mas que eso son cientos de cuadros, minutos de dibujado y decenas de
  /// megas por cada plano.
  static const ladoMaximo = 8192;

  /// El detalle que se busca, el mismo que para la imagen entera.
  static const dpiObjetivo = 200.0;

  /// Cuanto mas grande que la imagen entera tiene que salir el detalle para
  /// que valga la pena hacerlo.
  static const mejoraMinima = 1.3;

  /// El tamano de la imagen entera del plano, en pixeles.
  final int anchoVista;
  final int altoVista;

  /// El tamano de la hoja dibujada en detalle, sumando todos los cuadros.
  final int ancho;
  final int alto;

  final int lado;

  /// Los cuadros que ya estan dibujados, por numero.
  final Set<int> listos;

  /// Lo que hace falta para dibujar los que faltan. Nulo cuando ya no hay
  /// nada por hacer: estan todos, o los que faltan no se pudieron.
  final TrabajoDeDetalle? trabajo;

  int get columnas => (ancho / lado).ceil();
  int get filas => (alto / lado).ceil();
  int get total => columnas * filas;

  /// Si ya no queda nada por dibujar.
  bool get terminado => trabajo == null;

  /// Cuantas veces mas grande que la imagen entera es el detalle.
  double get mejora => ancho / anchoVista;

  /// El detalle que le corresponde a una hoja, o nulo si no hace falta.
  ///
  /// [anchoPt] y [altoPt] son el recorte del plano en puntos, y [anchoVista]
  /// y [altoVista] los pixeles con que quedo su imagen entera. Solo se hace
  /// detalle cuando esa imagen tuvo que achicarse: una hoja de topografia ya
  /// sale con todos sus puntos por pulgada y no gana nada.
  static DetallePlano? para({
    required double anchoPt,
    required double altoPt,
    required int anchoVista,
    required int altoVista,
  }) {
    final largo = math.max(anchoPt, altoPt);
    if (largo <= 0 || anchoVista <= 0) return null;
    final pixelesPorPunto = math.min(dpiObjetivo / 72, ladoMaximo / largo);
    if (pixelesPorPunto < anchoVista / anchoPt * mejoraMinima) return null;
    return DetallePlano(
      anchoVista: anchoVista,
      altoVista: altoVista,
      ancho: math.max(1, (anchoPt * pixelesPorPunto).round()),
      alto: math.max(1, (altoPt * pixelesPorPunto).round()),
    );
  }

  // ------------------------------------------------------------- cuadros

  /// El pedazo de la hoja que dibuja el cuadro [i], en pixeles del detalle.
  ///
  /// Cada cuadro se pasa un pixel sobre el de la derecha y el de abajo. Dos
  /// imagenes puestas canto con canto dejan ver una raya fina entre ellas
  /// cuando el mapa esta girado; montadas un pixel, no.
  ({int x, int y, int ancho, int alto}) pixeles(int i) {
    final x = (i % columnas) * lado;
    final y = (i ~/ columnas) * lado;
    var w = math.min(lado, ancho - x);
    var h = math.min(lado, alto - y);
    if (x + w < ancho) w += 1;
    if (y + h < alto) h += 1;
    return (x: x, y: y, ancho: w, alto: h);
  }

  /// Lo mismo en partes de la hoja, de 0 a 1: izquierda, arriba, derecha y
  /// abajo. Con [montado] en falso es el cuadro justo, sin el pixel de mas.
  ({double x0, double y0, double x1, double y1}) parte(
    int i, {
    bool montado = true,
  }) {
    final p = pixeles(i);
    final w = montado ? p.ancho : math.min(lado, ancho - p.x);
    final h = montado ? p.alto : math.min(lado, alto - p.y);
    return (
      x0: p.x / ancho,
      y0: p.y / alto,
      x1: (p.x + w) / ancho,
      y1: (p.y + h) / alto,
    );
  }

  /// Los cuadros que tocan una parte de la hoja, dada de 0 a 1. Lo que cae
  /// afuera de la hoja no cuenta.
  List<int> cuadrosEn({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) {
    if (x1 <= 0 || y1 <= 0 || x0 >= 1 || y0 >= 1) return const [];
    int tope(double v, int n) => v.floor().clamp(0, n - 1);
    final c0 = tope(x0 * ancho / lado, columnas);
    final c1 = tope(x1 * ancho / lado, columnas);
    final f0 = tope(y0 * alto / lado, filas);
    final f1 = tope(y1 * alto / lado, filas);
    return [
      for (var f = f0; f <= f1; f++)
        for (var c = c0; c <= c1; c++) f * columnas + c,
    ];
  }

  /// Los que faltan dibujar, del centro de la hoja hacia afuera: en el centro
  /// suele estar lo que se fue a mirar, y asi es lo primero que se aclara.
  List<int> pendientes() {
    final cx = (columnas - 1) / 2;
    final cy = (filas - 1) / 2;
    double lejos(int i) {
      final dx = i % columnas - cx;
      final dy = i ~/ columnas - cy;
      return dx * dx + dy * dy;
    }

    return [
      for (var i = 0; i < total; i++)
        if (!listos.contains(i)) i,
    ]..sort((a, b) {
      final d = lejos(a).compareTo(lejos(b));
      return d != 0 ? d : a.compareTo(b);
    });
  }

  DetallePlano conListo(int i) => DetallePlano(
    anchoVista: anchoVista,
    altoVista: altoVista,
    ancho: ancho,
    alto: alto,
    lado: lado,
    listos: {...listos, i},
    trabajo: trabajo,
  );

  DetallePlano conTrabajo(TrabajoDeDetalle? nuevo) => DetallePlano(
    anchoVista: anchoVista,
    altoVista: altoVista,
    ancho: ancho,
    alto: alto,
    lado: lado,
    listos: listos,
    trabajo: nuevo,
  );

  // ------------------------------------------------------------ archivos

  /// La carpeta del detalle de un plano, dada la ruta de su imagen -la copia
  /// con papel o la de las lineas, da igual-.
  static String carpetaDe(String rutaVista) {
    final base = ArchivosPlano.conFondo(rutaVista);
    final sinExtension = base.endsWith('.png')
        ? base.substring(0, base.length - 4)
        : base;
    return '$sinExtension-detalle';
  }

  static String indiceDe(String rutaVista) =>
      '${carpetaDe(rutaVista)}/detalle.json';

  /// El PDF de donde sale el detalle. Se queda en la carpeta mientras se
  /// dibujan los cuadros, y se borra al terminar: son megas.
  static String originalDe(String rutaVista) =>
      '${carpetaDe(rutaVista)}/original.pdf';

  /// La imagen del cuadro [i], en la misma version -con papel o solo las
  /// lineas- que la imagen del plano que se pasa.
  String archivoDe(String rutaVista, int i) {
    final cuadro =
        '${carpetaDe(rutaVista)}/f${i ~/ columnas}c${i % columnas}.png';
    return ArchivosPlano.esSinFondo(rutaVista)
        ? ArchivosPlano.sinFondo(cuadro)
        : cuadro;
  }

  /// El detalle de un plano, o nulo si no tiene -o si el indice no se puede
  /// leer, que para el mapa es lo mismo: se ve con la imagen de siempre-.
  static DetallePlano? leer(String rutaVista) {
    try {
      final archivo = File(indiceDe(rutaVista));
      if (!archivo.existsSync()) return null;
      return DetallePlano.deJson(
        jsonDecode(archivo.readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Escribe el indice. Primero a un archivo aparte y despues se cambia el
  /// nombre: si la app se cierra en la mitad, queda el indice anterior entero
  /// y no medio archivo.
  Future<void> guardar(String rutaVista) async {
    final destino = File(indiceDe(rutaVista));
    await destino.parent.create(recursive: true);
    final borrador = File('${destino.path}.nuevo');
    await borrador.writeAsString(jsonEncode(aJson()), flush: true);
    await borrador.rename(destino.path);
  }

  Map<String, dynamic> aJson() => {
    'v': 1,
    'vista': [anchoVista, altoVista],
    'detalle': [ancho, alto],
    'lado': lado,
    'listos': listos.toList()..sort(),
    'trabajo': ?trabajo?.aJson(),
  };

  factory DetallePlano.deJson(Map<String, dynamic> j) {
    final vista = (j['vista'] as List).cast<num>();
    final detalle = (j['detalle'] as List).cast<num>();
    final trabajo = j['trabajo'];
    final d = DetallePlano(
      anchoVista: vista[0].toInt(),
      altoVista: vista[1].toInt(),
      ancho: detalle[0].toInt(),
      alto: detalle[1].toInt(),
      lado: (j['lado'] as num).toInt(),
      listos: {for (final i in j['listos'] as List) (i as num).toInt()},
      trabajo: trabajo is Map<String, dynamic>
          ? TrabajoDeDetalle.deJson(trabajo)
          : null,
    );
    if (d.anchoVista <= 0 || d.ancho <= 0 || d.alto <= 0 || d.lado <= 0) {
      throw const FormatException('Indice de detalle con medidas imposibles');
    }
    return d;
  }
}

/// Lo que hace falta para dibujar los cuadros de un plano: que hoja, que
/// pedazo de ella, y que papel hay que quitarle.
class TrabajoDeDetalle {
  const TrabajoDeDetalle({
    required this.pagina,
    required this.x,
    required this.y,
    required this.ancho,
    required this.alto,
    required this.lineas,
    this.papel,
  });

  final int pagina;

  /// El recorte georreferenciado de la hoja, en la medida del motor de PDF.
  final double x;
  final double y;
  final double ancho;
  final double alto;

  /// Si ademas de cada cuadro se guarda su copia sin papel.
  final bool lineas;

  /// El color del papel -rojo, verde y azul-, decidido mirando la hoja
  /// entera. Todos los cuadros quitan el mismo.
  final List<int>? papel;

  Map<String, dynamic> aJson() => {
    'pagina': pagina,
    'x': x,
    'y': y,
    'ancho': ancho,
    'alto': alto,
    'lineas': lineas,
    'papel': ?papel,
  };

  factory TrabajoDeDetalle.deJson(Map<String, dynamic> j) => TrabajoDeDetalle(
    pagina: (j['pagina'] as num).toInt(),
    x: (j['x'] as num).toDouble(),
    y: (j['y'] as num).toDouble(),
    ancho: (j['ancho'] as num).toDouble(),
    alto: (j['alto'] as num).toDouble(),
    lineas: j['lineas'] == true,
    papel: (j['papel'] as List?)?.map((c) => (c as num).toInt()).toList(),
  );
}

/// Donde cae en el terreno una parte de un plano.
///
/// [plano] son las esquinas del plano entero -noroeste, noreste, sureste y
/// suroeste- y la parte va de 0 a 1 sobre la imagen. Devuelve las cuatro
/// esquinas de esa parte, en el mismo orden.
///
/// La cuenta se hace sobre el mapa proyectado y no sobre latitud y longitud.
/// El mapa apoya la imagen entera con tres de sus esquinas -la cuarta sale de
/// las otras- y la estira derecha *en la pantalla*; un cuadro repartido en
/// grados quedaria corrido unos metros respecto de la imagen entera, y al
/// acercarse el lindero saltaria de lugar.
List<LatLng> esquinasDeParte(
  List<LatLng> plano, {
  required double x0,
  required double y0,
  required double x1,
  required double y1,
}) {
  final arriba = _proyectar(plano[0]);
  final abajoDerecha = _proyectar(plano[2]);
  final abajo = _proyectar(plano[3]);
  // A lo ancho, de la esquina de abajo-izquierda a la de abajo-derecha; a lo
  // alto, de la de arriba-izquierda a la de abajo-izquierda.
  final ux = abajoDerecha.$1 - abajo.$1;
  final uy = abajoDerecha.$2 - abajo.$2;
  final vx = abajo.$1 - arriba.$1;
  final vy = abajo.$2 - arriba.$2;

  LatLng en(double s, double t) =>
      _desproyectar((arriba.$1 + s * ux + t * vx, arriba.$2 + s * uy + t * vy));

  return [en(x0, y0), en(x1, y0), en(x1, y1), en(x0, y1)];
}

// Mercator esferico, el del mapa. El radio no importa: se va y se vuelve.
(double, double) _proyectar(LatLng p) {
  final lat = p.latitude * math.pi / 180;
  return (
    p.longitude * math.pi / 180,
    math.log(math.tan(math.pi / 4 + lat / 2)),
  );
}

LatLng _desproyectar((double, double) p) => LatLng(
  (2 * math.atan(math.exp(p.$2)) - math.pi / 2) * 180 / math.pi,
  p.$1 * 180 / math.pi,
);
