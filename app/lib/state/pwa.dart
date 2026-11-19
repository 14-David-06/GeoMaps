import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/pwa.dart';

/// El estado de la app web (instalada o no, guardada para usar sin senal,
/// version nueva esperando) para las pantallas. Fuera del navegador es
/// siempre el inicial y no cambia.
final estadoPwaProvider = Provider<EstadoPwa>((ref) {
  void alCambiar() => ref.invalidateSelf();
  Pwa.estado.addListener(alCambiar);
  ref.onDispose(() => Pwa.estado.removeListener(alCambiar));
  return Pwa.estado.value;
});

/// La persona eligio seguir en Safari sin instalar. Vale hasta cerrar la
/// pestana: la proxima vez se le vuelve a sugerir.
final seguirEnNavegadorProvider = StateProvider<bool>((ref) => false);
