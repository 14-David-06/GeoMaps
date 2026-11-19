import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/errores.dart';
import '../core/telefono.dart';
import '../core/version_app.dart';

/// El cuaderno de errores de este telefono. Lo pone `main` al arrancar; sin
/// eso (en pruebas) es null y nada se anota.
final registroErroresProvider = Provider<RegistroErrores?>((ref) => null);

/// Abre el cuaderno y engancha los dos lugares por donde Flutter avisa de un
/// fallo. Corre una vez, al arrancar la app.
///
/// Si algo de esto falla devuelve null y la app arranca igual: anotar errores
/// es un servicio para quien la mantiene, no puede costarle el arranque a
/// quien la usa.
Future<RegistroErrores?> engancharErrores(
  Directory carpeta,
  VersionLocal? version,
) async {
  try {
    final registro = RegistroErrores(
      File('${carpeta.path}${Platform.pathSeparator}errores.json'),
      versionCode: version?.code,
      versionNombre: version?.nombre,
      sistema: await describirTelefono(),
    );

    // Lo que falla adentro de Flutter: dibujar, acomodar, un gesto.
    final previo = FlutterError.onError;
    FlutterError.onError = (detalle) {
      // Primero lo de siempre: que siga saliendo por la consola.
      previo?.call(detalle);
      anotarDeFlutter(registro, detalle);
    };

    // Lo que falla por fuera: un Future que nadie esperaba.
    PlatformDispatcher.instance.onError = (error, traza) {
      registro.anotar(error, traza, donde: 'fuera de una pantalla');
      // Falso: no se da por atendido, y sigue saliendo en el registro de
      // Android como siempre.
      return false;
    };
    return registro;
  } catch (_) {
    return null;
  }
}

/// Anota un fallo de los que reporta Flutter, salvo los que no son de la app.
///
/// Termina cuando el fallo quedo escrito. Quien avisa -Flutter- no lo espera.
Future<void> anotarDeFlutter(
  RegistroErrores registro,
  FlutterErrorDetails detalle,
) {
  // Los que Flutter mismo marca como de poca monta.
  if (detalle.silent) return Future.value();
  // Una imagen que no cargo. Sin senal es cada tesela del mapa.
  if (detalle.library == 'image resource service') return Future.value();

  final contexto = detalle.context?.toDescription();
  return registro.anotar(
    detalle.exception,
    detalle.stack,
    donde: [
      detalle.library,
      contexto,
    ].whereType<String>().where((t) => t.isNotEmpty).join(': '),
  );
}

/// Cuantos informes por llamada. El tope lo fija el backend en
/// `ErroresRequest`.
const _tanda = 20;

/// Sube los informes que esperan, y saca del telefono los que el servidor
/// recibio.
///
/// Callada a proposito. Sin sesion no hay a nombre de quien subir; sin red, o
/// contra un servidor que todavia no tiene donde recibirlos, no pasa nada:
/// quedan en el telefono y se reintenta la proxima vez que vuelva la senal.
Future<void> subirErrores(RegistroErrores? registro, ApiClient api) async {
  if (registro == null || api.token == null) return;
  try {
    final pendientes = await registro.pendientes();
    for (var i = 0; i < pendientes.length; i += _tanda) {
      final parte = pendientes.skip(i).take(_tanda);
      final recibidos = await api.reportarErrores([
        for (final informe in parte) informe.aJson(),
      ]);
      await registro.quitar(recibidos);
    }
  } catch (_) {
    // Subir errores no puede anotar errores: seria un bucle.
  }
}
