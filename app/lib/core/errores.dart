import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:uuid/uuid.dart';

import 'fuente_teselas.dart' show SinTesela;

/// Un fallo de la app que espera subir.
class InformeError {
  InformeError({
    required this.codigo,
    required this.mensaje,
    required this.ocurrioEn,
    this.traza,
    this.donde,
    this.veces = 1,
    this.versionCode,
    this.versionNombre,
    this.sistema,
  });

  factory InformeError.deJson(Map<String, dynamic> j) => InformeError(
    codigo: j['codigo'] as String,
    mensaje: j['mensaje'] as String,
    traza: j['traza'] as String?,
    donde: j['donde'] as String?,
    ocurrioEn: DateTime.parse(j['ocurrio_en'] as String),
    veces: (j['veces'] as num?)?.toInt() ?? 1,
    versionCode: (j['version_code'] as num?)?.toInt(),
    versionNombre: j['version_nombre'] as String?,
    sistema: j['sistema'] as String?,
  );

  /// UUID que se genera aca. Reintentar una subida cortada no duplica.
  final String codigo;
  final String mensaje;
  final String? traza;

  /// En que parte de la app salto, cuando Flutter lo sabe.
  final String? donde;

  /// La primera vez, con la hora del telefono.
  final DateTime ocurrioEn;

  /// Cuantas veces se repitio mientras esperaba subir.
  int veces;

  final int? versionCode;
  final String? versionNombre;

  /// Marca, modelo y version de Android.
  final String? sistema;

  /// Lo que viaja al backend y lo que se guarda en el telefono: es lo mismo.
  Map<String, dynamic> aJson() => {
    'codigo': codigo,
    'mensaje': mensaje,
    'traza': ?traza,
    'donde': ?donde,
    'ocurrio_en': ocurrioEn.toUtc().toIso8601String(),
    'veces': veces,
    'version_code': ?versionCode,
    'version_nombre': ?versionNombre,
    'sistema': ?sistema,
  };

  /// Lo que hace que dos fallos sean "el mismo": el mensaje y de donde salio.
  String get firma => RegistroErrores.firmaDe(mensaje, traza);
}

/// El cuaderno de errores de la app: un archivo en el telefono.
///
/// Un fallo en el telefono de un conductor, sin esto, solo se conoce si el
/// conductor lo cuenta, y lo que cuenta es "se cerro". Aca cada fallo queda
/// anotado -sin senal, como todo en esta app- con la version del APK y el
/// modelo del telefono, y sube al backend cuando engancha
/// (`state/errores.dart`).
///
/// Es un archivo y no una tabla de la base local a proposito: la base puede
/// ser justamente lo que fallo, y agregar una tabla obliga a una migracion.
///
/// Tres cuidados, que son los que hacen que anotar errores no empeore nada:
///
/// - **Nunca lanza.** Un cuaderno de errores que falla es otra fuente de
///   errores, y esta se anotaria a si misma sin fin.
/// - **No anota los cortes de red.** Sin senal son miles por jornada, entre
///   imagenes del mapa que no bajan y subidas que no salen, y ninguno es un
///   fallo de la app.
/// - **El mismo fallo se cuenta, no se repite.** Una pantalla que falla al
///   dibujarse falla sesenta veces por segundo: queda una fila con `veces`.
class RegistroErrores {
  RegistroErrores(
    this._archivo, {
    this.versionCode,
    this.versionNombre,
    this.sistema,
    DateTime Function()? reloj,
  }) : _reloj = reloj ?? DateTime.now;

  final File _archivo;
  final int? versionCode;
  final String? versionNombre;
  final String? sistema;
  final DateTime Function() _reloj;

  /// Cuantos fallos distintos se guardan. Con el cuaderno lleno se va el mas
  /// viejo: si el servidor tarda meses en recibirlos, lo que interesa es lo
  /// que falla ahora.
  static const maximo = 40;

  // Los topes del backend (`schemas_errores.py`), con margen.
  static const largoMensaje = 1500;
  static const largoTraza = 6000;
  static const largoDonde = 250;

  List<InformeError>? _informes;
  Future<List<InformeError>>? _carga;
  Future<void>? _escritura;
  bool _sucio = false;

  /// Si [error] es un corte de red o una imagen del mapa que no hay, y no un
  /// fallo de la app.
  static bool esRuido(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException ||
      error is ClientException ||
      error is SinTesela;

  /// El mensaje, y los tres primeros renglones de la traza: alcanza para
  /// distinguir dos fallos y no cambia si el mismo fallo llega por otro lado.
  static String firmaDe(String mensaje, String? traza) {
    final corto = mensaje.length > 200 ? mensaje.substring(0, 200) : mensaje;
    final arriba = (traza ?? '')
        .split('\n')
        .where((r) => r.trim().isNotEmpty)
        .take(3)
        .join('\n');
    return '$corto\n$arriba';
  }

  /// Anota un fallo. Nunca lanza, pase lo que pase.
  Future<void> anotar(Object error, StackTrace? traza, {String? donde}) async {
    try {
      if (esRuido(error)) return;
      final informes = await _cargar();

      final mensaje = _recortar(error.toString().trim(), largoMensaje);
      if (mensaje.isEmpty) return;
      final trazaTexto = traza == null
          ? null
          : _recortar(traza.toString().trim(), largoTraza);
      final firma = firmaDe(mensaje, trazaTexto);

      final igual = informes.where((i) => i.firma == firma).firstOrNull;
      if (igual != null) {
        igual.veces++;
        // Se guarda a la 2, la 4, la 8...: el numero exacto no importa tanto
        // como no escribir el archivo sesenta veces por segundo.
        if (igual.veces & (igual.veces - 1) != 0) return;
      } else {
        if (informes.length >= maximo) informes.removeAt(0);
        informes.add(
          InformeError(
            codigo: const Uuid().v4(),
            mensaje: mensaje,
            traza: trazaTexto == null || trazaTexto.isEmpty ? null : trazaTexto,
            donde: donde == null || donde.trim().isEmpty
                ? null
                : _recortar(donde.trim(), largoDonde),
            ocurrioEn: _reloj(),
            versionCode: versionCode,
            versionNombre: versionNombre,
            sistema: sistema,
          ),
        );
      }
      await _guardar();
    } catch (_) {
      // Ver arriba: esto no puede ser otra fuente de errores.
    }
  }

  /// Lo que espera subir, lo mas viejo primero.
  Future<List<InformeError>> pendientes() async {
    try {
      return List.of(await _cargar());
    } catch (_) {
      return const [];
    }
  }

  /// Saca los que el servidor ya recibio.
  Future<void> quitar(Iterable<String> codigos) async {
    try {
      final fuera = codigos.toSet();
      if (fuera.isEmpty) return;
      final informes = await _cargar();
      informes.removeWhere((i) => fuera.contains(i.codigo));
      await _guardar();
    } catch (_) {}
  }

  /// Borra todo. Es parte de eliminar la cuenta desde la app.
  Future<void> vaciar() async {
    try {
      (await _cargar()).clear();
      await _guardar();
    } catch (_) {}
  }

  Future<List<InformeError>> _cargar() =>
      _carga ??= _leer().then((leidos) => _informes = leidos);

  Future<List<InformeError>> _leer() async {
    try {
      if (!await _archivo.exists()) return [];
      final crudo = jsonDecode(await _archivo.readAsString());
      return [
        for (final j in (crudo as Map<String, dynamic>)['informes'] as List)
          InformeError.deJson(j as Map<String, dynamic>),
      ];
    } catch (_) {
      // Un archivo a medio escribir -se fue la bateria- se da por perdido:
      // peor seria no poder anotar nunca mas.
      return [];
    }
  }

  /// Escribe el archivo. Si ya hay una escritura en curso no arranca otra:
  /// deja dicho que hay que volver a escribir, y la que esta corriendo lo hace
  /// al terminar. Dos escrituras a la vez dejan el archivo mezclado.
  Future<void> _guardar() {
    _sucio = true;
    return _escritura ??= _escribir().whenComplete(() {
      _escritura = null;
    });
  }

  Future<void> _escribir() async {
    while (_sucio) {
      _sucio = false;
      final informes = _informes ?? const <InformeError>[];
      await _archivo.parent.create(recursive: true);
      await _archivo.writeAsString(
        jsonEncode({
          'informes': [for (final i in informes) i.aJson()],
        }),
        flush: true,
      );
    }
  }

  static String _recortar(String texto, int largo) =>
      texto.length <= largo ? texto : '${texto.substring(0, largo - 1)}…';
}
