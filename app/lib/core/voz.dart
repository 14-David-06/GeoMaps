import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_tts/flutter_tts.dart';

/// Quien dice las cosas en voz alta.
///
/// Es una interfaz para que el resto de la app -y las pruebas- no sepan nada
/// del sintetizador: piden que se diga una frase y siguen con lo suyo.
abstract class Voz {
  /// Dice [texto]. Si ya estaba diciendo otra cosa, la corta: en una ruta lo
  /// que importa es lo ultimo. Nunca lanza y no hace falta esperarla.
  Future<void> decir(String texto);

  /// Deja de hablar.
  Future<void> callar();

  /// Si el telefono puede hablar en espanol. En falso, [decir] no hace nada.
  Future<bool> disponible();
}

/// La voz del telefono, con el sintetizador de Android.
///
/// Funciona sin red si la voz en espanol esta instalada, que es lo normal en
/// un telefono configurado en espanol. Se prefiere una voz instalada a una
/// que haya que ir a buscar a internet, porque en el lote no hay.
///
/// Tres cuidados:
///
/// - **Nunca lanza.** Un telefono sin sintetizador, o con el servicio caido,
///   se queda callado: la ruta sigue en la pantalla como siempre.
/// - **Se oye por encima de la musica.** Pide el foco de audio un momento y
///   la musica baja sola mientras habla, como con cualquier navegador.
/// - **Despacio.** Un poco mas lento que la voz de fabrica: se escucha con el
///   motor prendido y con una sola pasada.
class VozTts implements Voz {
  FlutterTts? _tts;
  Future<bool>? _preparada;

  /// Los espanoles que sirven, del mas parecido al de aca al mas lejano.
  static const _idiomas = ['es-CO', 'es-US', 'es-MX', 'es-419', 'es-ES', 'es'];

  @override
  Future<bool> disponible() => _preparada ??= _preparar();

  @override
  Future<void> decir(String texto) async {
    try {
      if (!await disponible()) return;
      await _tts?.speak(texto, focus: true);
    } catch (_) {
      // Ver arriba: sin voz no pasa nada mas que eso.
    }
  }

  @override
  Future<void> callar() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  Future<bool> _preparar() async {
    try {
      final tts = FlutterTts();
      final idioma = await _elegirIdioma(tts);
      if (idioma == null) return false;
      await tts.setLanguage(idioma);
      // 0,5 es la velocidad de fabrica en Android.
      await tts.setSpeechRate(0.46);
      await tts.setVolume(1);
      await tts.setPitch(1);
      // Sale por el canal de indicaciones, como un navegador: se oye aunque
      // el telefono este en silencio para llamadas.
      // Solo Android: el plugin web no lo tiene, y fallar aca dejaba la app
      // web sin voz.
      if (!kIsWeb) await tts.setAudioAttributesForNavigation();
      // No se espera a que termine de hablar: quien pide una frase esta en
      // medio de atender una posicion del GPS.
      await tts.awaitSpeakCompletion(false);
      _tts = tts;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// El primer espanol instalado en el telefono; si ninguno lo esta, el
  /// primero que el sintetizador diga que puede hablar (bajandolo de la red).
  Future<String?> _elegirIdioma(FlutterTts tts) async {
    for (final idioma in _idiomas) {
      try {
        if (await tts.isLanguageInstalled(idioma) == true) return idioma;
      } catch (_) {}
    }
    for (final idioma in _idiomas) {
      try {
        if (await tts.isLanguageAvailable(idioma) == true) return idioma;
      } catch (_) {}
    }
    return null;
  }
}

/// Una voz que no dice nada. Para las pruebas y para las plataformas donde no
/// hay sintetizador.
class VozMuda implements Voz {
  const VozMuda();

  @override
  Future<void> decir(String texto) async {}

  @override
  Future<void> callar() async {}

  @override
  Future<bool> disponible() async => false;
}
