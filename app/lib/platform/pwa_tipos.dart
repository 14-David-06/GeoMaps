import 'package:flutter/foundation.dart';

/// Como esta la app web en este telefono. Lo arma `web/geomaps_pwa.js` y se
/// vuelve a leer cada vez que algo cambia.
@immutable
class EstadoPwa {
  const EstadoPwa({
    this.instalada = false,
    this.esIphone = false,
    this.listaSinSenal = false,
    this.guardando = false,
    this.hechos = 0,
    this.total = 0,
    this.actualizacion = false,
    this.error,
    this.guardadaEl,
  });

  /// Abierta desde el icono de la pantalla de inicio, no desde Safari. Importa
  /// porque Safari y la app instalada guardan en almacenes distintos: lo que
  /// se guarde en la pestana no aparece en la app.
  final bool instalada;

  final bool esIphone;

  /// Todo lo que la app necesita para arrancar ya esta en el telefono.
  final bool listaSinSenal;

  /// Bajando la app al telefono para que abra sin senal.
  final bool guardando;
  final int hechos;
  final int total;

  /// Hay una version nueva lista; se aplica solo cuando la persona acepta.
  final bool actualizacion;

  /// Por que no se pudo guardar la app, en palabras.
  final String? error;

  /// Cuando quedo guardada la version que esta corriendo.
  final DateTime? guardadaEl;

  double get progreso => total == 0 ? 0 : hechos / total;
}

/// Cuanto ocupa la app en el telefono y cuanto le deja usar el navegador.
@immutable
class EspacioPwa {
  const EspacioPwa({required this.usado, required this.cuota});

  final int usado;
  final int cuota;
}
