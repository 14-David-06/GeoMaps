import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Cliente HTTP contra el backend.
///
/// Regla que ordena este archivo: **ningun metodo de aca puede ser necesario
/// para que la app funcione en campo.** Todos sirven para sincronizar,
/// descargar mapas o entrar por primera vez. Si uno falla, la pantalla que lo
/// llamo sigue andando con lo que tiene en la base local.
///
/// Toda llamada lleva estas cabeceras y no son lo mismo:
///
///   X-API-Key      -> quien llama es GeoMaps
///   Authorization  -> quien es la persona (nuestro JWT, 30 dias)
///   X-App-Version  -> que APK es (el versionCode). Si ya esta bloqueado, el
///                     backend responde 426 a todo menos a `/v1/version`
///
/// Las tres puertas de entrada — Google, registro con clave y login con clave —
/// devuelven el mismo cuerpo, y por eso comparten `_sesion`. Para el resto de
/// la app no existe la diferencia.
class ApiClient {
  ApiClient({http.Client? cliente, this.versionCode})
    : _http = cliente ?? http.Client();

  final http.Client _http;

  /// El versionCode de este APK. Null solo en pruebas.
  final int? versionCode;

  /// Se llama cuando el backend responde 426: esta version ya no sirve. Lo
  /// conecta `ActualizacionNotifier`, que vuelve a consultar y bloquea.
  void Function()? alVersionVencida;

  /// El JWT de la sesion activa. Lo pone `SesionState` al entrar.
  String? token;

  Uri _uri(String ruta) => Uri.parse('${Config.api}$ruta');

  Map<String, String> _cabeceras({bool conToken = true}) => {
    'Content-Type': 'application/json',
    if (Config.apiKey.isNotEmpty) 'X-API-Key': Config.apiKey,
    if (conToken && token != null) 'Authorization': 'Bearer $token',
    if (versionCode != null) 'X-App-Version': '$versionCode',
  };

  /// Arma el error de una respuesta fallida, y avisa si fue por version.
  ApiError _fallo(http.Response r) {
    if (r.statusCode == 426) alVersionVencida?.call();
    return ApiError.deRespuesta(r);
  }

  /// Cambia el idToken de Google por nuestro JWT. Es tambien el registro: si el
  /// `sub` no existia en Airtable, el backend crea la fila.
  Future<Map<String, dynamic>> entrar(String idTokenGoogle) =>
      _sesion('/v1/sesion', {'id_token': idTokenGoogle});

  /// Entra a una cuenta que ya existe, con correo y clave.
  Future<Map<String, dynamic>> entrarConClave(String correo, String clave) =>
      _sesion('/v1/sesion/clave', {'correo': correo, 'clave': clave});

  /// Crea una cuenta con correo y clave. Devuelve sesion abierta, no un "ya te
  /// podes loguear": el registro pasa con red y mandar a la persona a un
  /// segundo formulario desperdicia el unico rato con senal que va a tener.
  Future<Map<String, dynamic>> registrar({
    required String nombre,
    required String correo,
    required String clave,
  }) => _sesion('/v1/registro', {
    'nombre': nombre,
    'correo': correo,
    'clave': clave,
  });

  /// Las tres puertas devuelven el mismo cuerpo, asi que comparten la llamada.
  ///
  /// El registro responde 201 y los logins 200. Se aceptan los dos para no
  /// tener una rama por endpoint que diga lo mismo.
  Future<Map<String, dynamic>> _sesion(
    String ruta,
    Map<String, String> cuerpo,
  ) async {
    final r = await _http
        .post(
          _uri(ruta),
          headers: _cabeceras(conToken: false),
          body: jsonEncode(cuerpo),
        )
        // En red rural un timeout largo no ayuda: si a los 20 s no contesto, no
        // va a contestar, y la persona necesita el mensaje para decidir si se
        // mueve a buscar senal.
        .timeout(const Duration(seconds: 20));

    if (r.statusCode != 200 && r.statusCode != 201) {
      throw _fallo(r);
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Comprueba que la sesion siga valiendo. No consulta Airtable del otro lado.
  Future<Map<String, dynamic>> yo() async {
    final r = await _http
        .get(_uri('/v1/yo'), headers: _cabeceras())
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// La version vigente del APK y la URL para bajarlo. No pide sesion: una app
  /// bloqueada o con la sesion vencida igual tiene que poder actualizarse.
  ///
  /// Devuelve el cuerpo crudo; `publicada` en falso significa que todavia no
  /// se publico ninguna version por el canal de actualizaciones.
  Future<Map<String, dynamic>> version() async {
    final r = await _http
        .get(_uri('/v1/version'), headers: _cabeceras(conToken: false))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw ApiError.deRespuesta(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Sube una tanda de lo pendiente. Devuelve, por cada UUID, si quedo.
  ///
  /// El timeout es mas largo que el de las demas: del otro lado cada trazado
  /// son tres escrituras (S3 y dos de Airtable) y Airtable admite cinco por
  /// segundo.
  Future<Map<String, dynamic>> sincronizar(Map<String, dynamic> cuerpo) async {
    final r = await _http
        .post(_uri('/v1/sync'), headers: _cabeceras(), body: jsonEncode(cuerpo))
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Borra la cuenta y todo lo que subio. No tiene vuelta atras.
  Future<void> eliminarCuenta() async {
    final r = await _http
        .delete(_uri('/v1/cuenta'), headers: _cabeceras())
        // Del otro lado son varias tandas contra Airtable y S3.
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 204) throw _fallo(r);
  }

  /// Las vueltas pendientes por recoger de la planilla de SiriusFleet.
  Future<Map<String, dynamic>> vueltasPendientes() async {
    final r = await _http
        .get(_uri('/v1/camiones/vueltas'), headers: _cabeceras())
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// El conductor toma una vuelta.
  ///
  /// [clave] solo en las cuentas que tienen una: las de Google confirman con
  /// la sesion. Lo que no se manda no viaja como texto vacio, viaja ausente.
  /// [salida] es donde esta el camion al tomarla (`lat`, `lon`,
  /// `precision_m`): de ahi sale y ahi tiene que volver.
  Future<Map<String, dynamic>> confirmarVuelta(
    String vueltaId, {
    String? clave,
    Map<String, Object?>? salida,
  }) async {
    final r = await _http
        .post(
          _uri('/v1/camiones/vueltas/$vueltaId/confirmar'),
          headers: _cabeceras(),
          body: jsonEncode({
            if (clave != null && clave.isNotEmpty) 'clave': clave,
            'salida': ?salida,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// La vuelta sin finalizar de esta cuenta, segun el servidor: `control`
  /// dice si esta llevando el seguimiento, y `viaje` cual tiene abierta.
  Future<Map<String, dynamic>> miViaje() async {
    final r = await _http
        .get(_uri('/v1/camiones/viaje'), headers: _cabeceras())
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Avisa por donde va la vuelta: llego a los vagones, volvio, la finalizo.
  /// Manda todo lo que se sabe del viaje, asi que repetirlo no hace dano.
  Future<Map<String, dynamic>> seguimientoViaje(
    String codigo,
    Map<String, Object?> cuerpo,
  ) async {
    final r = await _http
        .post(
          _uri('/v1/camiones/viajes/$codigo/seguimiento'),
          headers: _cabeceras(),
          body: jsonEncode(cuerpo),
        )
        // Corto a proposito: se llama al finalizar, con el conductor
        // esperando. Lo que no llegue sube despues con el recorrido.
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Devuelve a la lista una vuelta que este conductor tomo y no va a hacer.
  Future<void> soltarVuelta(String vueltaId) async {
    final r = await _http
        .post(
          _uri('/v1/camiones/vueltas/$vueltaId/soltar'),
          headers: _cabeceras(),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw _fallo(r);
  }

  /// Cambia el JWT por uno nuevo, con los perfiles que la cuenta tenga hoy.
  /// Devuelve el mismo cuerpo que las puertas de entrada.
  Future<Map<String, dynamic>> renovarSesion() async {
    final r = await _http
        .post(_uri('/v1/sesion/renovar'), headers: _cabeceras())
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Pide a donde subir la foto de un punto. Devuelve la `url` prefirmada
  /// del bucket y el `content_type` con el que hay que mandarla.
  Future<Map<String, dynamic>> pedirSubidaFoto(
    Map<String, dynamic> cuerpo,
  ) async {
    final r = await _http
        .post(
          _uri('/v1/fotos'),
          headers: _cabeceras(),
          body: jsonEncode(cuerpo),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Sube un archivo directo al bucket, contra una URL prefirmada.
  ///
  /// No lleva ninguna de las cabeceras del backend: la URL ya dice quien es y
  /// que puede hacer, y una cabecera de mas hace que el bucket rechace la
  /// firma. El plazo es largo porque es lo unico pesado que sube la app, y en
  /// red rural medio mega puede tardar un minuto.
  Future<void> subirArchivo(
    String url,
    List<int> bytes,
    String contentType,
  ) async {
    final r = await _http
        .put(
          Uri.parse(url),
          headers: {'Content-Type': contentType},
          body: bytes,
        )
        .timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) {
      throw ApiError(
        r.statusCode,
        'El almacenamiento no recibio el archivo (${r.statusCode}). Se '
        'reintenta en la proxima sincronizacion.',
      );
    }
  }

  /// Avisa que la foto ya esta en el bucket. Devuelve su `llave`.
  Future<Map<String, dynamic>> confirmarFoto(
    String codigo,
    Map<String, dynamic> cuerpo,
  ) async {
    final r = await _http
        .post(
          _uri('/v1/fotos/$codigo/confirmar'),
          headers: _cabeceras(),
          body: jsonEncode(cuerpo),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw _fallo(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Sube una tanda de informes de error. Devuelve los codigos que el
  /// servidor recibio, que son los que el telefono puede borrar.
  Future<List<String>> reportarErrores(
    List<Map<String, dynamic>> errores,
  ) async {
    final r = await _http
        .post(
          _uri('/v1/errores'),
          headers: _cabeceras(),
          body: jsonEncode({'errores': errores}),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw _fallo(r);
    final cuerpo = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (cuerpo['recibidos'] as List<dynamic>).cast<String>();
  }

  // TODO: GET  /v1/proyectos            -> espejo del directorio
  // TODO: GET  /v1/mapas?proyecto=      -> fichas de mapas listos
  // TODO: GET  /v1/mapas/{id}/descarga  -> URL prefirmada del MBTiles
  // TODO: POST /v1/archivos             -> sube KML/GPX/PDF/foto a S3
}

/// Un error del backend con el texto que el backend quiso dar.
///
/// El `detail` de FastAPI se muestra tal cual porque esta escrito para que lo
/// lea alguien parado en un lote, no para un log. Un "Error 401" generico ahi no
/// sirve de nada.
class ApiError implements Exception {
  ApiError(this.codigo, this.mensaje);

  factory ApiError.deRespuesta(http.Response r) {
    String mensaje;
    try {
      final cuerpo = jsonDecode(utf8.decode(r.bodyBytes));
      final detalle = cuerpo is Map ? cuerpo['detail'] : null;
      if (detalle is String) {
        mensaje = detalle;
      } else if (detalle is List) {
        // La validacion de FastAPI responde una lista de campos, escrita para
        // un programador. Pasa cuando la app y el servidor no son de la misma
        // version: mostrarla cruda en un lote no le sirve a nadie.
        mensaje =
            'El servidor no acepto los datos (${r.statusCode}). Puede que la '
            'app o el servidor esten desactualizados: avisale a soporte.';
      } else {
        mensaje = 'El servidor respondio ${r.statusCode}.';
      }
    } catch (_) {
      mensaje = 'El servidor respondio ${r.statusCode}.';
    }
    return ApiError(r.statusCode, mensaje);
  }

  final int codigo;
  final String mensaje;

  /// La sesion vencio o no vale. Es el unico caso que obliga a volver al login.
  bool get sesionInvalida => codigo == 401;

  /// Esta version del APK ya no se acepta. La app muestra la pantalla de
  /// actualizar; no es algo que se arregle reintentando.
  bool get requiereActualizar => codigo == 426;

  @override
  String toString() => mensaje;
}
