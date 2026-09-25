import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:printing/printing.dart';

import 'geopdf.dart';

/// Convertir en el telefono un plano de topografia en una capa del mapa.
///
/// Es la mitad que corre **sin senal y sin esperar a nadie**: la persona elige
/// el PDF, y el plano queda encima del mapa en el momento. La otra mitad
/// -`tools/convertir_mapa.py`, con GDAL- produce teselas nitidas a cualquier
/// zoom, pero necesita un computador y alguien que la corra; en un potrero eso
/// es mañana, y el plano se necesita ahora.
///
/// ## Que hace, en orden
///
/// 1. Lee la georreferencia (`GeoPdf`). Si no la trae, se planta aca: es lo
///    unico que no se puede suplir con esfuerzo.
/// 2. Rasteriza la pagina con el motor de PDF del sistema.
/// 3. **Recorta** al area georreferenciada. Sin esto, el marco, el membrete y
///    la convencion del plano -que son papel, no terreno- quedarian dibujados
///    sobre el mapa, tapando el satelital alrededor del predio.
/// 4. Guarda un PNG en la carpeta de la app y devuelve donde va.
///
/// ## El detalle irreversible: el DPI
///
/// Lo que se rasteriza es lo que va a existir. Mas DPI es mas nitidez al
/// acercarse y mas memoria, y el cuadrado: rasterizar una hoja doble carta a
/// 300 DPI son ~25 millones de pixeles, que en un telefono de campo es pedir
/// problemas. 150 DPI deja los rotulos de bloque legibles y cabe holgado.
class ImportadorGeoPdf {
  /// El detalle con el que se rasteriza. Ver la nota de arriba.
  static const dpiPorDefecto = 150.0;

  /// Tope de pixeles del lado largo. Un plano gigante a 150 DPI igual puede
  /// pasarse; por encima de esto, Android empieza a matar la app por memoria
  /// sin decir por que.
  static const ladoMaximo = 4096;

  /// Importa el plano y deja el PNG listo para dibujar.
  ///
  /// [destino] es la carpeta donde vive la copia: se queda en el telefono, asi
  /// que el plano sigue estando manana en el lote aunque el PDF original se
  /// haya borrado de Descargas.
  static Future<PlanoImportado> importar({
    required File pdf,
    required Directory destino,
    required String codigo,
    double dpi = dpiPorDefecto,
  }) async {
    final bytes = await pdf.readAsBytes();

    // Primero la georreferencia: rasterizar una hoja de 20 MB para descubrir
    // despues que no se puede ubicar es gastar el unico rato de bateria que
    // alguien tiene en el lote.
    final geo = GeoPdf.leer(bytes);

    final pagina = await _rasterizar(bytes, dpi);
    final recortada = _recortar(pagina, geo);

    final archivo = File('${destino.path}/$codigo.png');
    await archivo.writeAsBytes(img.encodePng(recortada));

    return PlanoImportado(
      ruta: archivo.path,
      esquinas: geo.esquinas,
      ancho: recortada.width,
      alto: recortada.height,
      megas: archivo.lengthSync() / 1048576,
    );
  }

  static Future<img.Image> _rasterizar(Uint8List bytes, double dpi) async {
    await for (final pagina in Printing.raster(bytes, dpi: dpi, pages: [0])) {
      // `pixels` viene en RGBA, que es justo lo que espera `image`.
      return img.Image.fromBytes(
        width: pagina.width,
        height: pagina.height,
        bytes: pagina.pixels.buffer,
        numChannels: 4,
      );
    }
    throw const GeoPdfInvalido(
      'El telefono no pudo abrir este PDF. Si se abre en el visor pero no '
      'aca, convertilo desde el computador.',
    );
  }

  /// Deja solo el area georreferenciada.
  ///
  /// El recuadro viene en puntos PostScript, con el origen **abajo** a la
  /// izquierda; la imagen tiene el origen **arriba**. Invertir la Y es el paso
  /// que, olvidado, recorta la franja opuesta de la hoja -y como casi siempre
  /// hay plano a ambos lados, el error pasa por "quedo corrido" en vez de por
  /// un recorte al reves.
  static img.Image _recortar(img.Image pagina, GeoPdf geo) {
    final escalaX = pagina.width / geo.pagina.ancho;
    final escalaY = pagina.height / geo.pagina.alto;

    final x = ((geo.recuadro.izquierda - geo.pagina.izquierda) * escalaX)
        .round();
    final y = ((geo.pagina.arriba - geo.recuadro.arriba) * escalaY).round();
    final ancho = (geo.recuadro.ancho * escalaX).round();
    final alto = (geo.recuadro.alto * escalaY).round();

    final recortada = img.copyCrop(
      pagina,
      x: x.clamp(0, pagina.width - 1),
      y: y.clamp(0, pagina.height - 1),
      width: ancho.clamp(1, pagina.width),
      height: alto.clamp(1, pagina.height),
    );

    final lado = recortada.width > recortada.height
        ? recortada.width
        : recortada.height;
    if (lado <= ladoMaximo) return recortada;

    return img.copyResize(
      recortada,
      width: recortada.width > recortada.height ? ladoMaximo : null,
      height: recortada.width > recortada.height ? null : ladoMaximo,
      interpolation: img.Interpolation.average,
    );
  }
}

/// Un plano ya importado: donde quedo la imagen y donde va en el mundo.
class PlanoImportado {
  const PlanoImportado({
    required this.ruta,
    required this.esquinas,
    required this.ancho,
    required this.alto,
    required this.megas,
  });

  /// El PNG recortado, en la carpeta de la app.
  final String ruta;

  /// Noroeste, noreste, sureste, suroeste.
  final List<LatLng> esquinas;

  final int ancho;
  final int alto;
  final double megas;

  /// `minLon,minLat,maxLon,maxLat`, para encuadrar el mapa sobre el plano.
  String get bbox {
    final lats = esquinas.map((e) => e.latitude);
    final lons = esquinas.map((e) => e.longitude);
    final minLat = lats.reduce((a, b) => a < b ? a : b);
    final maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLon = lons.reduce((a, b) => a < b ? a : b);
    final maxLon = lons.reduce((a, b) => a > b ? a : b);
    return '$minLon,$minLat,$maxLon,$maxLat';
  }

  /// Las esquinas como se guardan en la base: `lat,lon` separadas por `;`.
  String get esquinasSerializadas =>
      esquinas.map((e) => '${e.latitude},${e.longitude}').join(';');

  /// Lo contrario, para leerlas de la base.
  static List<LatLng> esquinasDeTexto(String texto) => texto
      .split(';')
      .map((p) {
        final xy = p.split(',');
        return LatLng(double.parse(xy[0]), double.parse(xy[1]));
      })
      .toList(growable: false);
}
