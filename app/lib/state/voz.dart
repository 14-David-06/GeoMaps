import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/voz.dart';

/// La voz del telefono. Una sola para toda la app: dos sintetizadores
/// hablando a la vez se pisan.
final vozProvider = Provider<Voz>((ref) => VozTts());

/// Si la app habla o no. Lo decide la persona con el boton del parlante, y
/// queda guardado: quien la apago no tiene por que apagarla en cada ruta.
///
/// Arranca prendida. Las indicaciones habladas son para quien maneja y para
/// quien no alcanza a leer la pantalla; el que no las quiere las apaga con un
/// toque, y el que las necesita no tiene que descubrir que existen.
class VozActiva extends StateNotifier<bool> {
  VozActiva() : super(true) {
    _leer();
  }

  static const _llave = 'voz_activa';

  Future<void> _leer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final guardado = prefs.getBool(_llave);
      if (guardado != null && mounted) state = guardado;
    } catch (_) {
      // Sin preferencias queda prendida, que es el valor de fabrica.
    }
  }

  Future<void> poner(bool activa) async {
    state = activa;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_llave, activa);
    } catch (_) {}
  }
}

final vozActivaProvider = StateNotifierProvider<VozActiva, bool>(
  (ref) => VozActiva(),
);

/// Dice las cosas, si la voz esta prendida.
///
/// Es lo que usa el resto de la app. Separa las dos preguntas -si hay que
/// decirlo y como se dice- para que quien anuncia un giro no tenga que
/// acordarse de mirar el interruptor.
class Locutor {
  Locutor(this._ref);

  final Ref _ref;

  /// Dice [texto] si la voz esta prendida. No hace falta esperarla.
  void decir(String texto) {
    if (!_ref.read(vozActivaProvider)) return;
    _ref.read(vozProvider).decir(texto);
  }

  /// Prende o apaga la voz. Al prenderla lo dice, que es tambien la forma de
  /// comprobar que el telefono tiene con que hablar; al apagarla se calla en
  /// el acto, sin terminar la frase.
  ///
  /// Devuelve falso si se quiso prender y el telefono no tiene voz en
  /// espanol: queda prendida igual -por si la instalan-, pero hay que
  /// avisarle a la persona que no va a oir nada.
  Future<bool> alternar() async {
    final activa = !_ref.read(vozActivaProvider);
    await _ref.read(vozActivaProvider.notifier).poner(activa);
    final voz = _ref.read(vozProvider);
    if (!activa) {
      await voz.callar();
      return true;
    }
    if (!await voz.disponible()) return false;
    await voz.decir('Voz activada.');
    return true;
  }
}

final locutorProvider = Provider<Locutor>(Locutor.new);
