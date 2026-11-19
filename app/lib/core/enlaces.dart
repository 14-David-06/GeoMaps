import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

/// Las paginas publicas que sirve el backend (`backend/app/paginas.py`).
///
/// Play exige que la politica de privacidad se pueda abrir desde la app, no
/// solo desde la ficha de la tienda. Se abren en el navegador y no en una
/// vista embebida: son las mismas que lee el revisor de Google.
class Enlaces {
  static final privacidad = Uri.parse('${Config.api}/privacidad');

  /// Abre [uri] en el navegador. Falso si no hubo con que abrirlo.
  static Future<bool> abrir(Uri uri) => launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
}
