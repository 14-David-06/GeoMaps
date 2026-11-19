import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'detalle_plano.dart';
import 'geopdf.dart';
import 'motor_planos.dart';

/// Convertir en el telefono un plano en PDF en una capa del mapa.
///
/// Es la mitad que corre **sin senal y sin esperar a nadie**: la persona elige
/// el PDF, y el plano queda encima del mapa en el momento. La otra mitad
/// -`tools/convertir_mapa.py`, con GDAL- produce teselas nitidas a cualquier
/// zoom, pero necesita un computador y alguien que la corra; en un potrero eso
/// es mañana, y el plano se necesita ahora.
///
/// ## Que hace, en orden
///
/// 1. Lee la georreferencia (`GeoPdf`), en un isolate aparte. Si no la trae,
///    se planta aca: es lo unico que no se puede suplir con esfuerzo.
/// 2. Le pide al motor de PDF del telefono que dibuje **solo el area
///    georreferenciada**. El marco, el membrete y la convencion del plano -que
///    son papel, no terreno- no se dibujan nunca: quedarian sobre el mapa
///    tapando el satelital alrededor del predio.
/// 3. El motor deja un PNG en la carpeta de la app, y se devuelve donde va.
///
/// ## El detalle irreversible: el tamano
///
/// Lo que se dibuja es lo que va a existir. Mas pixeles es mas nitidez al
/// acercarse y mas memoria **cada vez que la capa esta encendida**, porque la
/// imagen se abre entera. El tope es el lado mas largo que una pantalla de
/// telefono sabe mostrar de una sola pieza; una hoja cartografica grande queda
/// con menos puntos por pulgada que una de topografia.
///
/// Por eso a las hojas grandes se les hace ademas un **detalle**: la misma
/// hoja, mas grande, partida en cuadros ([DetallePlano]). Se dibuja despues,
/// con el plano ya puesto en el mapa ([afinar]), y de cerca se ven solo los
/// cuadros que entran en la pantalla.
class ImportadorGeoPdf {
  /// El detalle que se busca. Deja legibles los rotulos de un plano al
  /// acercarse, y solo se alcanza en hojas de hasta medio pliego.
  static const dpiObjetivo = 200.0;

  /// Tope de pixeles del lado largo. Por encima, las pantallas de gama media
  /// no pueden subir la imagen a la placa de video y la capa no aparece.
  static const ladoMaximo = 4096;

  /// Piso de pixeles del lado largo, para que un mapa chico dentro de una hoja
  /// (un recuadro de ubicacion) no quede en cuatro manchas.
  static const ladoMinimo = 1024;

  /// Importa el plano y deja el PNG listo para dibujar.
  ///
  /// [destino] es la carpeta donde vive la copia: se queda en el telefono, asi
  /// que el plano sigue estando manana en el lote aunque el PDF original se
  /// haya borrado de Descargas.
  static Future<PlanoImportado> importar({
    required File pdf,
    required Directory destino,
    required String codigo,
    MotorPlanos motor = const MotorPlanos(),
    void Function(PasoImportacion paso)? alAvanzar,
  }) async {
    // Primero la georreferencia: dibujar una hoja de 20 MB para descubrir
    // despues que no se puede ubicar es gastar el unico rato de bateria que
    // alguien tiene en el lote.
    alAvanzar?.call(PasoImportacion.leyendo);
    final geo = await _leerAparte(pdf.path);

    alAvanzar?.call(PasoImportacion.dibujando);
    final hoja = await motor.hoja(pdf.path, geo.indicePagina);
    final marco = encuadre(geo, anchoHoja: hoja.ancho, altoHoja: hoja.alto);

    // Dos copias: la hoja tal cual y la hoja sin el papel. Se hacen las dos de
    // entrada porque el PDF ya no va a estar cuando alguien quiera cambiar de
    // una a otra, y volver a dibujarlo seria pedirle que lo importe de nuevo.
    final conFondo = File('${destino.path}/$codigo.png');
    final sinFondo = File(ArchivosPlano.sinFondo(conFondo.path));
    final dibujo = await motor.dibujar(
      ruta: pdf.path,
      pagina: geo.indicePagina,
      x: marco.x,
      y: marco.y,
      ancho: marco.ancho,
      alto: marco.alto,
      anchoPx: marco.anchoPx,
      altoPx: marco.altoPx,
      destino: conFondo.path,
      destinoSinFondo: sinFondo.path,
    );
    final hayLineas = dibujo.sinFondo;

    final bytesConFondo = conFondo.lengthSync();
    final bytes = bytesConFondo + (hayLineas ? sinFondo.lengthSync() : 0);
    return PlanoImportado(
      // Queda puesta la copia sin papel: lo que se quiere ver encima del mapa
      // son las lineas del plano, no una hoja blanca tapando el terreno.
      ruta: hayLineas ? sinFondo.path : conFondo.path,
      esquinas: geo.esquinas,
      ancho: marco.anchoPx,
      alto: marco.altoPx,
      megas: bytes / 1048576,
      aviso: geo.aviso,
      detalle: _detalle(
        marco,
        anchoPt: geo.recorte.ancho,
        altoPt: geo.recorte.alto,
        pagina: geo.indicePagina,
        dibujo: dibujo,
        bytesConFondo: bytesConFondo,
      ),
    );
  }

  /// Por encima de esto, la imagen entera pesa como una foto y no como un
  /// dibujo: bytes por pixel del PNG.
  static const pesoDeFoto = 0.9;

  /// El detalle que hay que hacerle al plano, o nulo si no le hace falta.
  ///
  /// No se le hace a una hoja que ya salio con todo su detalle, ni a una
  /// **ortofoto o un plano escaneado**: sus cuadros pesan diez veces lo que
  /// los de un dibujo -mas de cien megas por plano- y un telefono de campo no
  /// tiene ese lugar. Se los reconoce porque su imagen entera pesa como una
  /// foto; un plano dibujado, con sus lineas sobre papel liso, pesa muy poco.
  static DetallePlano? _detalle(
    Encuadre marco, {
    required double anchoPt,
    required double altoPt,
    required int pagina,
    required Dibujo dibujo,
    required int bytesConFondo,
  }) {
    final esFoto = bytesConFondo / (marco.anchoPx * marco.altoPx) > pesoDeFoto;
    if (esFoto) return null;
    return DetallePlano.para(
      anchoPt: anchoPt,
      altoPt: altoPt,
      anchoVista: marco.anchoPx,
      altoVista: marco.altoPx,
    )?.conTrabajo(
      TrabajoDeDetalle(
        pagina: pagina,
        x: marco.x,
        y: marco.y,
        ancho: marco.ancho,
        alto: marco.alto,
        lineas: dibujo.sinFondo,
        papel: dibujo.papel,
      ),
    );
  }

  /// Dibuja los cuadros de detalle que le faltan a un plano.
  ///
  /// Va despues de [importar] y aparte, porque tarda: son decenas de
  /// dibujados, y el plano ya esta en el mapa mientras tanto. Cada cuadro que
  /// termina queda anotado en el indice, asi que si la app se cierra en la
  /// mitad no se pierde lo hecho y se puede seguir.
  ///
  /// [rutaVista] es la imagen del plano; [pdf] el archivo del que sale.
  /// [seguir] se consulta antes de cada cuadro: en cuanto dice que no, se
  /// corta ahi y queda para retomar. Devuelve el detalle como quedo.
  ///
  /// Si un cuadro no se puede dibujar la falla sale tal cual: lo hecho hasta
  /// ahi ya esta guardado, y decidir que se hace con el resto es de quien
  /// llama.
  static Future<DetallePlano> afinar({
    required String rutaVista,
    required DetallePlano detalle,
    required File pdf,
    MotorPlanos motor = const MotorPlanos(),
    bool Function()? seguir,
    void Function(DetallePlano detalle)? alAvanzar,
  }) async {
    final trabajo = detalle.trabajo;
    if (trabajo == null) return detalle;

    await Directory(DetallePlano.carpetaDe(rutaVista)).create(recursive: true);
    // Los nombres de los cuadros salen de la copia con papel; la de las
    // lineas es esa misma con su sufijo.
    final base = ArchivosPlano.conFondo(rutaVista);
    final porPixelX = trabajo.ancho / detalle.ancho;
    final porPixelY = trabajo.alto / detalle.alto;

    var actual = detalle;
    for (final i in detalle.pendientes()) {
      if (seguir != null && !seguir()) return actual;
      final p = actual.pixeles(i);
      final destino = actual.archivoDe(base, i);
      await motor.dibujar(
        ruta: pdf.path,
        pagina: trabajo.pagina,
        x: trabajo.x + p.x * porPixelX,
        y: trabajo.y + p.y * porPixelY,
        ancho: p.ancho * porPixelX,
        alto: p.alto * porPixelY,
        anchoPx: p.ancho,
        altoPx: p.alto,
        destino: destino,
        destinoSinFondo: trabajo.lineas
            ? ArchivosPlano.sinFondo(destino)
            : null,
        papel: trabajo.papel,
      );
      actual = actual.conListo(i);
      await actual.guardar(rutaVista);
      alAvanzar?.call(actual);
    }

    actual = actual.conTrabajo(null);
    await actual.guardar(rutaVista);
    alAvanzar?.call(actual);
    return actual;
  }

  /// Va en una funcion aparte a proposito: lo que se manda al isolate es el
  /// cierre con **todo** lo que tenga a la vista, y aca lo unico a la vista es
  /// la ruta. Adentro de `importar` se llevaria tambien el aviso de avance,
  /// que cuelga de la pantalla y no se puede mandar.
  static Future<GeoPdf> _leerAparte(String ruta) =>
      Isolate.run(() => GeoPdf.leerArchivo(ruta));

  /// Que rectangulo pedirle al motor y de cuantos pixeles.
  ///
  /// El lector y el motor miden la misma hoja, pero el motor redondea a puntos
  /// enteros y puede aplicar una unidad propia del PDF; por eso el recorte se
  /// lleva a la medida del motor con la proporcion entre las dos, y no se
  /// asume que coinciden.
  static Encuadre encuadre(
    GeoPdf geo, {
    required double anchoHoja,
    required double altoHoja,
  }) {
    var kx = anchoHoja / geo.anchoVisible;
    var ky = altoHoja / geo.altoVisible;
    // Hasta 1% es el redondeo del motor, no otra escala.
    if ((kx - 1).abs() < 0.01) kx = 1;
    if ((ky - 1).abs() < 0.01) ky = 1;

    final r = geo.recorte;
    final largo = math.max(r.ancho, r.alto);
    var pixelesPorPunto = dpiObjetivo / 72;
    if (largo * pixelesPorPunto > ladoMaximo) {
      pixelesPorPunto = ladoMaximo / largo;
    } else if (largo * pixelesPorPunto < ladoMinimo) {
      pixelesPorPunto = ladoMinimo / largo;
    }

    return Encuadre(
      x: r.x * kx,
      y: r.y * ky,
      ancho: r.ancho * kx,
      alto: r.alto * ky,
      anchoPx: math.max(1, (r.ancho * pixelesPorPunto).round()),
      altoPx: math.max(1, (r.alto * pixelesPorPunto).round()),
    );
  }
}

/// Los dos archivos de un plano importado: la hoja tal cual y la hoja sin el
/// papel.
///
/// Van con el mismo nombre y un sufijo, en vez de con una columna en la base
/// que diga cual esta puesto: la fila ya guarda la ruta del archivo que se
/// dibuja, y de esa ruta sale la otra. No hay dos datos que puedan quedar
/// desacomodados.
abstract final class ArchivosPlano {
  static const _sufijo = '-lineas.png';

  /// La ruta es la de la copia sin papel.
  static bool esSinFondo(String ruta) => ruta.endsWith(_sufijo);

  /// La copia con la hoja entera, sea cual sea la que se pase.
  static String conFondo(String ruta) => esSinFondo(ruta)
      ? '${ruta.substring(0, ruta.length - _sufijo.length)}.png'
      : ruta;

  /// La copia con solo las lineas, sea cual sea la que se pase.
  static String sinFondo(String ruta) => esSinFondo(ruta)
      ? ruta
      : '${ruta.endsWith('.png') ? ruta.substring(0, ruta.length - 4) : ruta}'
            '$_sufijo';
}

/// En que anda la importacion, para decirlo en la pantalla: un plano grande
/// tarda, y un boton que solo gira hace pensar que la app se colgo.
enum PasoImportacion { leyendo, dibujando }

/// El rectangulo de la hoja que se dibuja, en la medida del motor, y el
/// tamano en pixeles de la imagen que sale.
class Encuadre {
  const Encuadre({
    required this.x,
    required this.y,
    required this.ancho,
    required this.alto,
    required this.anchoPx,
    required this.altoPx,
  });

  final double x;
  final double y;
  final double ancho;
  final double alto;
  final int anchoPx;
  final int altoPx;
}

/// Un plano ya importado: donde quedo la imagen y donde va en el mundo.
class PlanoImportado {
  const PlanoImportado({
    required this.ruta,
    required this.esquinas,
    required this.ancho,
    required this.alto,
    required this.megas,
    this.aviso,
    this.detalle,
  });

  /// El PNG recortado, en la carpeta de la app.
  final String ruta;

  /// El detalle que le falta hacer, si la hoja es grande. Nulo si con la
  /// imagen entera alcanza.
  final DetallePlano? detalle;

  /// Noroeste, noreste, sureste, suroeste.
  final List<LatLng> esquinas;

  final int ancho;
  final int alto;
  final double megas;

  /// Algo que hay que decirle a la persona aunque el plano haya entrado: por
  /// ejemplo, que usa un sistema viejo y puede quedar corrido.
  final String? aviso;

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
