import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/zona.dart';
import 'package:geomaps/state/ubicacion_provider.dart';
import 'package:geomaps/state/zona_guaicaramo.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// El mapa de Guaicaramo mientras el GPS no engancha.
///
/// Solo se abre adentro del predio, y adentro del predio es justo donde no hay
/// internet y el primer fix tarda. Por eso vale haber estado adentro hace
/// poco. Lo que se cuida aca es cuanto es "hace poco": tiene que alcanzar
/// para el lunes de quien trabajo el viernes, y no ser para siempre.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const clave = 'zona.guaicaramo.ultimaVezAdentro';

  /// Como ve la app el predio si la ultima vez adentro fue hace [hace], con
  /// el GPS todavia sin contestar.
  Future<EstadoZona> sinGps({Duration? hace}) async {
    SharedPreferences.setMockInitialValues({
      if (hace != null)
        clave: DateTime.now().subtract(hace).millisecondsSinceEpoch,
    });
    final c = ProviderContainer(
      overrides: [
        // El perimetro todavia se esta leyendo y el GPS no dio nada: es el
        // arranque de la app en un lote sin senal.
        zonaGuaicaramoProvider.overrideWith((ref) => Completer<Zona>().future),
        posicionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(c.dispose);
    final escucha = c.listen(estadoGuaicaramoProvider, (_, _) {});
    addTearDown(escucha.close);
    // El recuerdo se lee del telefono al arrancar, no en el acto.
    await pumpEventQueue();
    return c.read(estadoGuaicaramoProvider);
  }

  test(
    'quien estuvo adentro hace un rato abre el mapa sin esperar al GPS',
    () async {
      final estado = await sinGps(hace: const Duration(hours: 3));

      expect(estado.habilitado, isTrue);
      expect(estado.recordadoDe, isNotNull);
      expect(estado.explicacion, contains('Estabas en la plantacion'));
    },
  );

  test('el lunes temprano vale haber trabajado el viernes', () async {
    // De viernes a las 5 de la tarde a lunes a las 7 de la manana.
    final estado = await sinGps(hace: const Duration(hours: 62));

    expect(estado.habilitado, isTrue);
  });

  test('pasados los tres dias ya no alcanza: hay que esperar al GPS', () async {
    final estado = await sinGps(hace: const Duration(hours: 73));

    expect(estado.habilitado, isFalse);
    expect(estado.motivo, MotivoZona.buscandoGps);
  });

  test('sin haber estado nunca adentro, se espera al GPS', () async {
    final estado = await sinGps();

    expect(estado.habilitado, isFalse);
    expect(estado.motivo, MotivoZona.buscandoGps);
  });
}
