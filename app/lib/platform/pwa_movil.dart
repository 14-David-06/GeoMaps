import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

import 'pwa_tipos.dart';

/// La fachada en Android y en las pruebas: nada de esto existe fuera del
/// navegador, y ningun flujo del telefono cambia por tenerla.
abstract final class Pwa {
  static final estado = ValueNotifier<EstadoPwa>(const EstadoPwa());

  /// Como abrio la base local en el navegador. En el telefono no aplica.
  static String? motorBase;

  static void arrancar() {}

  static Future<void> cargarFuentes() async {}

  static Future<bool> actualizar() async => false;

  static Future<EspacioPwa?> espacio() async => null;

  static Future<String?> versionServiceWorker() async => null;

  static Future<int?> teselasGuardadas() async => null;

  static MapCachingProvider? get cacheTeselas => null;

  static String get navegador => '';

  static Future<void> pantallaEncendida(bool encendida) async {}
}
