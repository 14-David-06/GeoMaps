import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../data/db/app_database.dart';
import 'providers.dart' show versionLocalProvider;

/// Quien esta usando la app.
///
/// GeoMaps no es una app interna: el registro es abierto. Se entra por dos
/// puertas — cuenta de Google, o correo y clave — y no hay proveedor de
/// identidad de por medio ni SDK de terceros administrando la sesion.
///
/// ## El intercambio
///
/// Con Google:
///
/// 1. `google_sign_in` devuelve un **idToken** de Google.
/// 2. La app lo manda a `POST /v1/sesion`.
/// 3. El backend lo verifica contra el JWKS de Google, asegura la fila en
///    Airtable y devuelve un **JWT propio**, de 30 dias.
///
/// Con clave: `POST /v1/registro` o `POST /v1/sesion/clave`, y el backend
/// devuelve ese mismo JWT propio.
///
/// En los dos casos el JWT se guarda en el Keystore de Android y va en todas
/// las llamadas siguientes. **Aca no se guarda la clave**: se manda una vez y
/// se descarta con el formulario. Lo mismo el idToken de Google, que ademas
/// vence en una hora.
///
/// ## Por que esto funciona en el monte
///
/// Que herramientas ve una cuenta en la app.
///
/// Una sola app para todos, y cada cuenta ve lo suyo: se asigna en el campo
/// `Perfiles` de `Usuarios` en Airtable. No es `rol` -eso es quien puede ver
/// datos ajenos-, es que hace la persona en campo.
///
/// El codigo de cada modulo vive en su carpeta (`lib/camiones/`), para que
/// sumar uno no enrede los otros.
enum Perfil {
  /// Ubicarse en la plantacion, planos, lotes, rutas. Lo que la app hacia
  /// siempre, y lo que tiene una cuenta sin perfil asignado.
  plantacion,

  /// El personal de camiones.
  camiones;

  /// Lo que trae una sesion sin perfiles: las guardadas antes de que
  /// existieran, o una cuenta con el campo vacio. Nadie pierde lo que tenia.
  static const porDefecto = {Perfil.plantacion};

  /// Los que llegan del backend. Uno que esta app no conoce se ignora: el
  /// backend puede estrenar un perfil antes de que este APK sepa dibujarlo.
  static Set<Perfil> deJson(Object? crudo) {
    final conocidos = {
      for (final p in (crudo as List<dynamic>? ?? const []))
        ...Perfil.values.where((v) => v.name == p),
    };
    return conocidos.isEmpty ? porDefecto : conocidos;
  }
}

/// El JWT propio dura 30 dias y **leerlo no necesita red**. Alguien entra con
/// senal una vez y trabaja un mes sin volver a ver una pantalla de login. Si la
/// sesion dependiera del token de Google, la app pediria login justo en el unico
/// lugar donde no se puede hacer.
class Sesion {
  const Sesion({
    required this.authUid,
    required this.codigoUsuario,
    required this.nombre,
    required this.correo,
    required this.rol,
    required this.venceEn,
    this.proveedor = 'Google',
    this.foto,
    this.perfiles = Perfil.porDefecto,
  });

  factory Sesion.deJson(Map<String, dynamic> j) => Sesion(
    authUid: j['auth_uid'] as String,
    codigoUsuario: j['codigo_usuario'] as String,
    nombre: j['nombre'] as String,
    correo: j['correo'] as String,
    rol: j['rol'] as String? ?? 'Usuario',
    // Las sesiones guardadas antes de que existiera la puerta de clave no
    // traen este campo: todas eran de Google.
    proveedor: j['proveedor'] as String? ?? 'Google',
    foto: j['foto'] as String?,
    venceEn: DateTime.parse(j['vence_en'] as String),
    perfiles: Perfil.deJson(j['perfiles']),
  );

  final String authUid;
  final String codigoUsuario;
  final String nombre;
  final String correo;
  final String rol;

  /// `Google` o `Correo`. Solo para mostrarlo en el perfil; nada del
  /// funcionamiento de la app depende de cual sea.
  final String proveedor;

  final String? foto;
  final DateTime venceEn;

  /// Se lee de la sesion guardada, sin red, como todo lo demas. Un cambio en
  /// Airtable llega al telefono la proxima vez que la persona entra.
  final Set<Perfil> perfiles;

  bool tiene(Perfil p) => perfiles.contains(p);

  Map<String, dynamic> aJson() => {
    'auth_uid': authUid,
    'codigo_usuario': codigoUsuario,
    'nombre': nombre,
    'correo': correo,
    'rol': rol,
    'proveedor': proveedor,
    'foto': foto,
    'vence_en': venceEn.toIso8601String(),
    'perfiles': [for (final p in perfiles) p.name],
  };

  bool get vencida => DateTime.now().isAfter(venceEn);

  /// Cuantos dias de trabajo sin senal quedan. La app lo muestra para que nadie
  /// se entere de que la sesion vencio estando en un lote.
  int get diasRestantes => venceEn.difference(DateTime.now()).inDays;
}

/// Estado del login. Tres situaciones, no dos: entrando importa porque el
/// intercambio con Google tarda y la pantalla no puede quedarse muda.
class EstadoSesion {
  const EstadoSesion({
    this.sesion,
    this.cargando = false,
    this.error,
    this.arrancando = false,
  });

  final Sesion? sesion;

  /// Hay un intento de entrar en curso. La pantalla de ingreso lo muestra en
  /// su boton y **sigue en pantalla**: si el intento falla, el correo que la
  /// persona escribio tiene que seguir ahi.
  final bool cargando;
  final String? error;

  /// Todavia se esta leyendo la sesion guardada, al abrir la app. Dura
  /// milisegundos y es lo unico que se espera con la pantalla en blanco.
  final bool arrancando;

  /// Con la sesion al dia: puede subir y traer cosas del servidor.
  bool get autenticado => sesion != null && !sesion!.vencida;

  /// La sesion vencio y la persona **sigue adentro**: trabaja con lo que hay
  /// en el telefono, y nada sube hasta que vuelva a entrar con senal.
  ///
  /// No se la saca a la pantalla de ingreso porque entrar necesita red, y la
  /// sesion vence donde vence: a veces en el lote, que es el unico lugar donde
  /// no se puede volver a entrar. La app le avisa y la deja trabajar.
  bool get vencida => sesion?.vencida ?? false;
}

class SesionNotifier extends StateNotifier<EstadoSesion> {
  SesionNotifier(this._api) : super(const EstadoSesion(arrancando: true)) {
    _restaurar();
  }

  /// Con alguien ya adentro y sin leer el almacen seguro, que en una prueba
  /// no existe: es como se arma una pantalla que necesita una sesion.
  @visibleForTesting
  SesionNotifier.conSesion(this._api, Sesion sesion)
    : super(EstadoSesion(sesion: sesion));

  final ApiClient _api;

  static const _almacen = FlutterSecureStorage(
    // El Keystore de Android, no SharedPreferences: un token de 30 dias en
    // texto plano es una sesion prestada a cualquiera que agarre el telefono
    // un minuto.
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _llaveToken = 'jwt';
  static const _llaveSesion = 'sesion';

  late final GoogleSignIn _google = GoogleSignIn(
    scopes: const ['email', 'profile'],
    // El client id **Web**, no el de Android. Sin esto, Android abre sesion
    // pero no devuelve idToken y el backend se queda sin nada que verificar.
    serverClientId: Config.googleServerClientId.isEmpty
        ? null
        : Config.googleServerClientId,
  );

  /// Lee la sesion guardada. Corre al arrancar y **no toca la red**: si el
  /// telefono abre en un potrero, tiene que entrar igual.
  Future<void> _restaurar() async {
    try {
      final crudo = await _almacen.read(key: _llaveSesion);
      final token = await _almacen.read(key: _llaveToken);
      if (crudo == null || token == null) {
        state = const EstadoSesion();
        return;
      }
      final sesion = Sesion.deJson(jsonDecode(crudo) as Map<String, dynamic>);
      // Vencida o no, la persona queda adentro (ver `EstadoSesion.vencida`).
      // El token vencido se monta igual: el servidor lo rechaza con un
      // mensaje que dice justo eso, y es lo que muestra la sincronizacion.
      _api.token = token;
      state = EstadoSesion(sesion: sesion);
    } catch (_) {
      // Un almacen ilegible no puede dejar la app sin arrancar: se trata como
      // "no hay sesion" y se pide login.
      state = const EstadoSesion();
    }
  }

  /// La sesion vencida de quien esta volviendo a entrar, si es el caso.
  ///
  /// Se conserva mientras dura el intento y si el intento falla: quien probo
  /// entrar sin senal, o se equivoco de clave, tiene que seguir adentro con
  /// lo suyo, no quedar afuera por haber intentado.
  Sesion? get _vencida {
    final actual = state.sesion;
    return actual != null && actual.vencida ? actual : null;
  }

  Future<void> entrar() async {
    final vencida = _vencida;
    state = EstadoSesion(sesion: vencida, cargando: true);
    try {
      if (Config.googleServerClientId.isEmpty) {
        throw Exception(
          'Falta GOOGLE_SERVER_CLIENT_ID en dart_defines.json. Es el client id '
          'de tipo Web del proyecto de Google Cloud.',
        );
      }

      final cuenta = await _google.signIn();
      if (cuenta == null) {
        // La persona cancelo. No es un error y no se muestra como tal.
        state = EstadoSesion(sesion: vencida);
        return;
      }

      final idToken = (await cuenta.authentication).idToken;
      if (idToken == null) {
        throw Exception(
          'Google no devolvio idToken. Casi siempre significa que el '
          'serverClientId no es el client id de tipo Web.',
        );
      }

      await _abrir(() => _api.entrar(idToken));
    } on ApiError catch (e) {
      state = EstadoSesion(sesion: vencida, error: e.mensaje);
    } catch (e) {
      state = EstadoSesion(sesion: vencida, error: _traducir(e));
    }
  }

  /// Entra con correo y clave a una cuenta que ya existe.
  Future<void> entrarConClave(String correo, String clave) =>
      _conFormulario(() => _api.entrarConClave(correo, clave));

  /// Crea una cuenta con correo y clave y queda adentro, sin un segundo paso.
  Future<void> registrar({
    required String nombre,
    required String correo,
    required String clave,
  }) => _conFormulario(
    () => _api.registrar(nombre: nombre, correo: correo, clave: clave),
  );

  /// El envoltorio de las dos puertas de clave: cargando, llamada, error.
  ///
  /// No traduce nada por su cuenta. Los mensajes de estos dos endpoints los
  /// escribio el backend para que los lea una persona ("Ese correo ya entra con
  /// Google", "Volve a probar en 12 minutos"), y reescribirlos aca solo podria
  /// empeorarlos.
  Future<void> _conFormulario(
    Future<Map<String, dynamic>> Function() llamada,
  ) async {
    final vencida = _vencida;
    state = EstadoSesion(sesion: vencida, cargando: true);
    try {
      await _abrir(llamada);
    } on ApiError catch (e) {
      state = EstadoSesion(sesion: vencida, error: e.mensaje);
    } catch (e) {
      state = EstadoSesion(sesion: vencida, error: _traducir(e));
    }
  }

  /// Guarda el token y la sesion, y deja la app adentro.
  ///
  /// Es el unico lugar donde se escribe en el almacen seguro. Que las tres
  /// puertas pasen por aca es lo que garantiza que una sesion abierta con clave
  /// se guarde y se restaure igual que una abierta con Google.
  Future<void> _abrir(Future<Map<String, dynamic>> Function() llamada) async {
    final datos = await llamada();
    final sesion = Sesion.deJson(datos);
    _api.token = datos['token'] as String;

    await _almacen.write(key: _llaveToken, value: _api.token);
    await _almacen.write(key: _llaveSesion, value: jsonEncode(sesion.aJson()));

    state = EstadoSesion(sesion: sesion);
  }

  bool _renovando = false;
  DateTime? _ultimaRenovacion;

  /// Cada cuanto vale la pena volver a preguntar. Del otro lado es una
  /// consulta a Airtable, que topa en cinco por segundo para todos.
  static const _entreRenovaciones = Duration(hours: 1);

  /// Cambia el JWT por uno nuevo, con lo que la cuenta tenga hoy.
  ///
  /// Sirve para dos cosas. Los **perfiles** viajan adentro del token: darle a
  /// alguien el modulo de camiones en Airtable no le llegaba hasta que cerrara
  /// sesion y volviera a entrar. Y el **plazo** se corre: quien abre la app
  /// con senal de vez en cuando no vuelve a ver el login.
  ///
  /// Es callada a proposito. Sin red, o contra un backend que todavia no tiene
  /// el endpoint, no pasa nada: la sesion guardada sigue valiendo lo que
  /// valia. Lo unico que si saca a la persona es que la cuenta ya no exista o
  /// este suspendida, que es justo cuando el token viejo no deberia servir.
  ///
  /// Devuelve si la sesion quedo renovada. Con [forzar] no espera el plazo
  /// entre renovaciones: es el boton de "actualizar mi cuenta".
  Future<bool> renovar({bool forzar = false}) async {
    final actual = state.sesion;
    if (actual == null || _renovando || _api.token == null) return false;
    final ultima = _ultimaRenovacion;
    if (!forzar &&
        ultima != null &&
        DateTime.now().difference(ultima) < _entreRenovaciones) {
      return false;
    }

    _renovando = true;
    try {
      final datos = await _api.renovarSesion();
      final nueva = Sesion.deJson(datos);
      // Mientras se esperaba la respuesta pudo cerrarse la sesion o entrar
      // otra cuenta: el token que llego ya no es de quien esta adentro.
      if (state.sesion?.authUid != actual.authUid ||
          nueva.authUid != actual.authUid) {
        return false;
      }
      _api.token = datos['token'] as String;
      await _almacen.write(key: _llaveToken, value: _api.token);
      await _almacen.write(key: _llaveSesion, value: jsonEncode(nueva.aJson()));
      _ultimaRenovacion = DateTime.now();
      if (mounted) state = EstadoSesion(sesion: nueva);
      return true;
    } on ApiError catch (e) {
      if (e.codigo == 403 && state.sesion?.authUid == actual.authUid) {
        await _limpiar();
        if (mounted) state = EstadoSesion(error: e.mensaje);
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      _renovando = false;
    }
  }

  /// Cierra sesion. No borra nada del telefono: lo que no subio queda en la
  /// base local, atado a la cuenta que lo hizo.
  ///
  /// Las pantallas no llaman a esto directo sino a `cerrarSesion`
  /// (`ui/cerrar_sesion.dart`), que antes avisa si queda algo sin subir y
  /// ofrece subirlo: un cierre de sesion que deja la jornada de alguien
  /// esperando en un telefono ajeno es la peor falla posible de esta app.
  Future<void> salir() async {
    // Inofensivo si la persona entro con clave: sin sesion de Google abierta,
    // `signOut` no hace nada. Una rama por proveedor aca no compraria nada.
    try {
      // En la app web no hay entrada con Google (ver LoginPage), y tocar el
      // plugin ahi baja el script de accounts.google.com.
      if (!kIsWeb) await _google.signOut();
    } catch (_) {
      // Los servicios de Google del telefono pueden estar rotos -es la razon
      // por la que existe la puerta de clave-, y eso no puede dejar a alguien
      // sin poder cerrar su sesion: la nuestra se cierra igual.
    }
    try {
      await _limpiar();
    } catch (_) {
      // Lo mismo si el almacen seguro del telefono no responde.
    }
    state = const EstadoSesion();
  }

  /// Borra la cuenta en el backend, despues lo suyo en el telefono, y sale.
  ///
  /// En ese orden: si el backend falla (sin red, por ejemplo), no se toco nada
  /// y la persona puede reintentar. Al reves, quedaria con la cuenta viva y
  /// sin los trazados que todavia no habia subido.
  Future<void> eliminarCuenta(AppDatabase db) async {
    await _api.eliminarCuenta();
    await db.borrarDatosDeCuenta();
    await salir();
  }

  Future<void> _limpiar() async {
    _api.token = null;
    await _almacen.delete(key: _llaveToken);
    await _almacen.delete(key: _llaveSesion);
  }

  /// El codigo de estado de Google dentro del mensaje del error.
  ///
  /// En debug llega como `ApiException: 10: `, pero en el APK de release R8
  /// ofusca el nombre de la clase y llega como `s5.10: ` (la letra cambia en
  /// cada build). Buscar el texto literal `ApiException` solo andaba en debug.
  static int? _codigoGoogle(String texto) {
    final m = RegExp(r'(?:ApiException: |\b[A-Za-z]\w{0,3}\.)(\d+):')
        .firstMatch(texto);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Traduce los errores crudos de Google a algo accionable.
  ///
  /// `ApiException: 10` es el mas comun y el mas mudo: significa que la huella
  /// SHA-1 del APK no esta registrada en Google Cloud. Mostrarlo tal cual manda
  /// a la persona a reintentar veinte veces sin que nada cambie.
  String _traducir(Object e) {
    final texto = e.toString();
    final codigo = _codigoGoogle(texto);
    if (codigo == 10) {
      return 'Google rechazo la app (error 10). La huella SHA-1 de este APK no '
          'esta registrada en Google Cloud. Es configuracion, no algo que se '
          'arregle reintentando.';
    }
    if (codigo == 7 || texto.contains('SocketException')) {
      return 'Sin conexion. El primer ingreso necesita red una sola vez; '
          'despues la app funciona un mes sin senal.';
    }
    if (codigo == 12501) {
      return 'Se cancelo el ingreso.';
    }
    return texto.replaceFirst('Exception: ', '');
  }
}

final apiProvider = Provider<ApiClient>(
  (ref) => ApiClient(versionCode: ref.watch(versionLocalProvider)?.code),
);

final sesionProvider = StateNotifierProvider<SesionNotifier, EstadoSesion>(
  (ref) => SesionNotifier(ref.watch(apiProvider)),
);
