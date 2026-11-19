import 'dart:io';

import 'package:flutter/services.dart';

/// Que telefono es: `OPPO CPH2637 · Android 14`.
///
/// Va con cada informe de error (`core/errores.dart`): un fallo que solo pasa
/// en un modelo no se encuentra sin saber cual. Lo contesta el lado nativo
/// (`MainActivity.kt`) porque Dart no conoce la marca ni el modelo, y traer un
/// paquete entero para tres cadenas no se justifica.
///
/// Nunca lanza: si el canal no esta -otra plataforma, una prueba- devuelve lo
/// que Dart sabe por su cuenta.
Future<String> describirTelefono() async {
  try {
    final nativo = await const MethodChannel('geomaps/telefono')
        .invokeMethod<String>('descripcion');
    if (nativo != null && nativo.trim().isNotEmpty) return nativo.trim();
  } catch (_) {
    // Sin canal: sigue abajo.
  }
  return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
}
