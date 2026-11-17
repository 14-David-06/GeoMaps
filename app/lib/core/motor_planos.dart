import 'package:flutter/services.dart';

import 'geopdf.dart';

/// El lado nativo de importar un plano: elegir el PDF y dibujarlo.
///
/// ## Por que no son los plugins que habia
///
/// La primera version usaba `file_selector` para elegir y `printing` para
/// rasterizar. Alcanzaba para un plano de topografia de doble carta, y se caia
/// con cualquier hoja cartografica:
///
/// - El selector **lee el archivo entero a la memoria** y lo manda por el
///   canal a Dart, ademas de copiarlo. Un mapa con ortofoto adentro pesa 80 MB
///   o mas, y Android mata la app antes de que llegue.
/// - El rasterizador dibuja **la hoja completa** a un DPI fijo y devuelve los
///   pixeles crudos por el canal. Un pliego a 150 DPI son 35 millones de
///   pixeles: 140 MB que no entran en la memoria de la app, y despues hay que
///   recortarlos y comprimirlos en el hilo de la pantalla.
///
/// Aca el archivo nunca pasa por la memoria de Dart: el selector lo copia a
/// disco, y el dibujado pide **solo el recorte georreferenciado**, al tamano
/// final, y lo deja escrito como PNG. Lo hace `PdfRenderer`, el motor de PDF
/// de Android, que no agrega nada al tamano de la app.
class MotorPlanos {
  const MotorPlanos();

  static const _canal = MethodChannel('geomaps/planos');

  /// Abre el selector de archivos del telefono. Null si la persona cancelo.
  ///
  /// Lo que se elige se copia a la carpeta temporal de la app: un PDF que
  /// vive en Drive o en WhatsApp no tiene una ruta que se pueda abrir.
  Future<PdfElegido?> elegir() async {
    final r = await _llamar<Map<Object?, Object?>>('elegir');
    if (r == null) return null;
    return PdfElegido(
      ruta: r['ruta']! as String,
      nombre: (r['nombre'] as String?) ?? 'Plano.pdf',
    );
  }

  /// El tamano de una hoja tal como la ve el motor, en puntos.
  Future<HojaPdf> hoja(String ruta, int pagina) async {
    final r = await _llamar<Map<Object?, Object?>>('hoja', {
      'ruta': ruta,
      'pagina': pagina,
    });
    return HojaPdf(
      paginas: r!['paginas']! as int,
      ancho: (r['ancho']! as num).toDouble(),
      alto: (r['alto']! as num).toDouble(),
    );
  }

  /// Dibuja un rectangulo de la hoja a un PNG de [anchoPx] por [altoPx].
  ///
  /// El rectangulo va en el espacio del motor: puntos, origen arriba a la
  /// izquierda. Lo que el PDF no pinta queda **transparente**.
  ///
  /// Casi ningun plano llega asi: lo normal es que traiga pintada la hoja
  /// blanca, y esa hoja encima del mapa tapa el terreno. Por eso, si se pasa
  /// [destinoSinFondo], se escribe ahi una segunda copia **sin el papel**, con
  /// solo las lineas. Devuelve si esa copia se hizo: no se hace cuando el
  /// plano no tiene un papel que quitar -una ortofoto, o un plano que ya venia
  /// transparente-.
  Future<bool> dibujar({
    required String ruta,
    required int pagina,
    required double x,
    required double y,
    required double ancho,
    required double alto,
    required int anchoPx,
    required int altoPx,
    required String destino,
    String? destinoSinFondo,
  }) async {
    final r = await _llamar<Map<Object?, Object?>>('dibujar', {
      'ruta': ruta,
      'pagina': pagina,
      'x': x,
      'y': y,
      'ancho': ancho,
      'alto': alto,
      'anchoPx': anchoPx,
      'altoPx': altoPx,
      'destino': destino,
      'destinoSinFondo': destinoSinFondo,
    });
    return r?['sinFondo'] == true;
  }

  /// Los errores del lado nativo llegan con un codigo; aca se convierten en el
  /// mismo [GeoPdfInvalido] que usa el lector, para que la pantalla tenga un
  /// solo tipo de falla que mostrar.
  Future<T?> _llamar<T>(String metodo, [Map<String, Object?>? argumentos]) async {
    try {
      return await _canal.invokeMethod<T>(metodo, argumentos);
    } on PlatformException catch (e) {
      throw GeoPdfInvalido(switch (e.code) {
        'protegido' =>
          'El PDF esta protegido con clave. Pedilo sin proteccion, o '
              'convertilo desde el computador.',
        'memoria' =>
          'El plano es demasiado pesado para este telefono. Convertilo '
              'desde el computador.',
        'copia' =>
          'No se pudo leer el archivo elegido. Si esta en la nube, '
              'descargalo primero al telefono.',
        'sin_selector' =>
          'Este telefono no tiene una aplicacion para elegir archivos.',
        'ilegible' =>
          'El telefono no pudo abrir este PDF. Si se abre en el visor pero '
              'no aca, convertilo desde el computador.',
        _ => 'No se pudo importar el plano. (${e.message ?? e.code})',
      });
    } on MissingPluginException {
      throw const GeoPdfInvalido(
        'Importar planos solo funciona en el telefono.',
      );
    }
  }
}

/// El PDF que eligio la persona, ya copiado a la carpeta temporal.
class PdfElegido {
  const PdfElegido({required this.ruta, required this.nombre});

  final String ruta;

  /// Como se llamaba el archivo donde estaba: "Vias Meta 2026.pdf".
  final String nombre;
}

/// Una hoja del PDF segun el motor que la dibuja.
class HojaPdf {
  const HojaPdf({
    required this.paginas,
    required this.ancho,
    required this.alto,
  });

  final int paginas;
  final double ancho;
  final double alto;
}
