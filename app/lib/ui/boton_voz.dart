import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/voz.dart';

/// El parlante: prende y apaga las indicaciones habladas.
///
/// Va al lado del boton de la ruta, a la vista, y no en un menu: quien va
/// manejando y quiere que la app se calle -o que hable- lo necesita con un
/// toque y sin buscar.
///
/// Al prenderla la app dice "Voz activada", que es tambien la prueba de que
/// el telefono tiene con que hablar. Si no tiene una voz en espanol, lo
/// explica en vez de quedarse muda sin motivo.
class BotonVoz extends ConsumerWidget {
  const BotonVoz({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activa = ref.watch(vozActivaProvider);
    return IconButton.filledTonal(
      // Del alto de los botones de al lado: se acierta con guantes.
      style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
      iconSize: 28,
      tooltip: activa ? 'Apagar la voz' : 'Prender la voz',
      onPressed: () async {
        final avisos = ScaffoldMessenger.of(context);
        final habla = await ref.read(locutorProvider).alternar();
        if (habla) return;
        avisos.showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 9),
            content: Text(
              'Este telefono no tiene una voz en espanol instalada, asi que '
              'no va a hablar. Se instala en los Ajustes del telefono, '
              'buscando "Sintesis de voz".',
            ),
          ),
        );
      },
      icon: Icon(activa ? Icons.volume_up : Icons.volume_off),
    );
  }
}
