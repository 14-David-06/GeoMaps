import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geomaps/camiones/seguimiento.dart';
import 'package:geomaps/core/geo.dart';
import 'package:geomaps/core/voz.dart';
import 'package:geomaps/state/voz.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Una voz que anota lo que le piden decir, en vez de decirlo.
class _VozAnotada implements Voz {
  _VozAnotada({this.hayEspanol = true});

  final bool hayEspanol;
  final dicho = <String>[];
  var calladas = 0;

  @override
  Future<void> decir(String texto) async {
    if (hayEspanol) dicho.add(texto);
  }

  @override
  Future<void> callar() async => calladas++;

  @override
  Future<bool> disponible() async => hayEspanol;
}

/// La voz de la app: cuando habla, cuando se calla, y que dice en una vuelta.
///
/// Es para quien maneja con las manos en el volante y para quien no alcanza a
/// leer la pantalla. Lo que se cuida es que el interruptor mande de verdad
/// -apagada no dice nada, ni lo que ya venia diciendo- y que quede guardado.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer contenedor(_VozAnotada voz) {
    final c = ProviderContainer(
      overrides: [vozProvider.overrideWithValue(voz)],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('el interruptor', () {
    test('de fabrica viene prendida, y dice lo que le piden', () async {
      final voz = _VozAnotada();
      final c = contenedor(voz);

      c.read(locutorProvider).decir('Gira a la derecha.');

      expect(c.read(vozActivaProvider), isTrue);
      expect(voz.dicho, ['Gira a la derecha.']);
    });

    test('apagada no dice nada, y corta lo que venia diciendo', () async {
      final voz = _VozAnotada();
      final c = contenedor(voz);
      await pumpEventQueue();

      expect(await c.read(locutorProvider).alternar(), isTrue);
      c.read(locutorProvider).decir('Gira a la derecha.');

      expect(c.read(vozActivaProvider), isFalse);
      expect(voz.dicho, isEmpty);
      expect(voz.calladas, 1, reason: 'no termina la frase que estaba');
    });

    test(
      'al prenderla lo dice: es la prueba de que el telefono habla',
      () async {
        SharedPreferences.setMockInitialValues({'voz_activa': false});
        final voz = _VozAnotada();
        final c = contenedor(voz);
        // El valor guardado se lee al arrancar.
        c.read(vozActivaProvider);
        await pumpEventQueue();
        expect(c.read(vozActivaProvider), isFalse);

        expect(await c.read(locutorProvider).alternar(), isTrue);

        expect(c.read(vozActivaProvider), isTrue);
        expect(voz.dicho, ['Voz activada.']);
      },
    );

    test('queda guardado para la proxima vez', () async {
      final c = contenedor(_VozAnotada());
      await pumpEventQueue();
      await c.read(locutorProvider).alternar();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('voz_activa'), isFalse);

      // La app se cierra y vuelve: sigue apagada.
      final otra = contenedor(_VozAnotada());
      otra.read(vozActivaProvider);
      await pumpEventQueue();
      expect(otra.read(vozActivaProvider), isFalse);
    });

    test(
      'sin voz en espanol en el telefono, avisa que no va a hablar',
      () async {
        SharedPreferences.setMockInitialValues({'voz_activa': false});
        final voz = _VozAnotada(hayEspanol: false);
        final c = contenedor(voz);
        c.read(vozActivaProvider);
        await pumpEventQueue();

        final habla = await c.read(locutorProvider).alternar();

        expect(habla, isFalse, reason: 'la pantalla lo explica');
        // Queda prendida igual: si le instalan la voz, empieza a hablar sola.
        expect(c.read(vozActivaProvider), isTrue);
      },
    );
  });

  group('la vuelta de un camion', () {
    const patio = PuntoGeo(4.4000, -72.9000);
    const acopio = PuntoGeo(4.4500, -72.9400);
    final t0 = DateTime.utc(2026, 11, 18, 15);

    Position en(PuntoGeo p, {double precision = 8}) => Position(
      latitude: p.latitud,
      longitude: p.longitud,
      timestamp: t0,
      accuracy: precision,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

    Map<String, Object?> recien() => {
      'vuelta_id': 'v1',
      'destino': [acopio.longitud, acopio.latitud],
      'salida': Movimiento(en: t0, punto: patio, precisionM: 8).aJson(),
    };

    test('avisa al llegar a los vagones y al volver, una vez cada una', () {
      // El conductor va mirando la via: que la pantalla cambie de "1 de 3" a
      // "2 de 3" no le avisa nada.
      final dicho = <String>[];
      final vigia = VigiaDeVueltas(decir: dicho.add);
      var p = recien();

      Map<String, Object?> paso(PuntoGeo donde) {
        final cambios = vigia.alFix(en(donde), p);
        return p = {...p, ...?cambios};
      }

      // Saliendo del patio y a medio camino: nada.
      paso(patio);
      paso(const PuntoGeo(4.4250, -72.9200));
      expect(dicho, isEmpty);

      // Entra al radio de los vagones.
      paso(acopio);
      expect(dicho, [VigiaDeVueltas.alLlegar]);
      // Sigue ahi, enganchando: no lo repite.
      paso(acopio);
      expect(dicho, hasLength(1));

      // Vuelve al patio.
      paso(const PuntoGeo(4.4250, -72.9200));
      paso(patio);
      expect(dicho, [VigiaDeVueltas.alLlegar, VigiaDeVueltas.alVolver]);
      paso(patio);
      expect(dicho, hasLength(2));
    });

    test('un GPS impreciso no anuncia una llegada que no es', () {
      final dicho = <String>[];
      final vigia = VigiaDeVueltas(decir: dicho.add);

      vigia.alFix(en(acopio, precision: 90), recien());

      expect(dicho, isEmpty);
    });

    test('al retomar un viaje cortado no anuncia tarde', () {
      // La app estuvo cerrada mientras el camion pasaba por los vagones: la
      // llegada cuenta, pero decir "llegaste" veinte minutos despues confunde.
      final dicho = <String>[];
      final vigia = VigiaDeVueltas(decir: dicho.add);

      final cambios = vigia.alRetomar([patio, acopio], recien());

      expect(cambios, contains('llegada'));
      expect(dicho, isEmpty);
    });
  });
}
