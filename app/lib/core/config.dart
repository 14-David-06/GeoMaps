import 'package:flutter/foundation.dart' show kIsWeb;

/// Configuracion de compilacion.
///
/// Todo entra por `--dart-define`, nunca por un archivo commiteado: un APK
/// anda en el bolsillo de alguien y cualquier cadena adentro es publica. Por
/// eso aca no hay ni un token de Airtable ni una llave del bucket, solo la URL
/// del backend y la llave propia de la app.
class Config {
  /// URL del backend. Por defecto apunta al despliegue de produccion, asi un
  /// APK compilado sin dart-define igual habla con el servidor real. Para
  /// desarrollo contra un backend local se pasa API_BASE: en el emulador de
  /// Android el localhost de la maquina es 10.0.2.2, no 127.0.0.1.
  static const apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://geo-maps-seven.vercel.app',
  );

  /// A donde se llama de verdad. En el telefono es [apiBase]. En el navegador
  /// es el mismo dominio que sirvio la app: la app web vive dentro del
  /// backend (`/geomaps/`), asi que no hay CORS, y un despliegue Preview de
  /// Vercel habla con su propio backend y no con produccion. API_BASE_WEB lo
  /// cambia, solo para probar.
  static String get api {
    if (!kIsWeb) return apiBase;
    const propia = String.fromEnvironment('API_BASE_WEB');
    return propia.isNotEmpty ? propia : Uri.base.origin;
  }

  /// Viaja en el header X-API-Key. No identifica al usuario, solo dice que
  /// quien llama es esta app.
  static const apiKey = String.fromEnvironment('API_KEY');

  /// Cuantos dias vale la sesion guardada sin volver a hablar con el backend.
  /// Tiene que coincidir con `JWT_TTL_DIAS` del backend: si la app cree que
  /// dura mas, deja trabajar y despues rechaza la sincronizacion con un 401
  /// que nadie va a saber leer en un potrero.
  static const diasMaxOffline = 30;

  /// Client id **Web** del proyecto de Google Cloud. Va como `serverClientId`
  /// de `google_sign_in`: sin el, Android entrega la sesion pero no entrega
  /// idToken, y sin idToken el backend no tiene nada que verificar. No es
  /// secreto, pero se pasa por dart-define para no tener que recompilar el
  /// codigo al cambiar de proyecto de Google.
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
}
