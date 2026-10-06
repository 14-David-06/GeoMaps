import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import '../core/ubicacion.dart';

/// El unico dueno del GPS en toda la app.
///
/// **Por que uno solo.** `geolocator` en Android tiene un unico flujo nativo
/// por app: el segundo que pide `getPositionStream` recibe el mismo flujo que
/// abrio el primero, con los ajustes del primero, e ignora los suyos. Cuando
/// el home y el mapa abrian cada uno "su" GPS, el mapa heredaba el del home
/// -filtro de 3 m, asi que quieto no llegaba nada- y sus reinicios no
/// reiniciaban nada, porque el home seguia agarrado al flujo viejo. Entrar a un
/// segundo mapa lo dejaba "buscando senal" hasta cerrar la app.
///
/// Aca hay una sola suscripcion nativa, con los ajustes del mapa, y todo el
/// que quiera la posicion escucha [posiciones]. Reiniciar el GPS -por el
/// vigia, al volver a la app, al prender la ubicacion- reinicia ese flujo de
/// verdad, para todos a la vez.
///
/// Prendido mientras alguien escucha; con el ultimo que se va, se apaga.
class Gps {
  Gps._();

  static final instancia = Gps._();

  late final _salida = StreamController<Position>.broadcast(
    onListen: _prender,
    onCancel: _apagar,
  );

  StreamSubscription<Position>? _suscripcion;
  StreamSubscription<ServiceStatus>? _servicio;
  AppLifecycleListener? _ciclo;
  Timer? _vigia;
  Timer? _reintento;

  /// Ver [Ubicacion.flujo]: se alterna si pasa un rato sin ningun fix.
  bool _soloChipGps = false;
  DateTime _inicioFlujo = DateTime.now();
  DateTime? _ultimoFixVivo;

  /// Cada arranque se numera. Volver a la app y prender la ubicacion pueden
  /// pedir un arranque a la vez, y sin esto quedaban dos flujos vivos.
  int _arranque = 0;

  Position? _ultima;
  Object? _error;

  /// La posicion, empezando por la ultima que se tenga. Quien entra a una
  /// pantalla nueva ve de una donde esta, sin esperar al proximo fix.
  ///
  /// Los errores son [PermisoUbicacionDenegado] -con el motivo para mostrar- o
  /// lo que el GPS reporte mientras se reintenta.
  Stream<Position> get posiciones => Stream.multi((c) {
    final ultima = _ultima;
    final error = _error;
    if (error != null) {
      c.addError(error);
    } else if (ultima != null) {
      c.add(ultima);
    }
    final sub = _salida.stream.listen(c.add, onError: c.addError);
    c.onCancel = sub.cancel;
  });

  /// Vuelve a abrir el flujo nativo. Es barato y es lo que antes obligaba a
  /// cerrar y abrir la app.
  ///
  /// Si ya hay un arranque en curso no se pide otro: dos pedidos de permiso a
  /// la vez hacen que `geolocator` tire una excepcion.
  void reiniciar() {
    if (_salida.hasListener && !_arrancando) _arrancar();
  }

  void _prender() {
    _ciclo = AppLifecycleListener(onResume: reiniciar);
    // Si alguien apaga y prende la ubicacion, el flujo muere con el apagado y
    // no vuelve solo.
    try {
      _servicio = Geolocator.getServiceStatusStream().listen((estado) {
        if (estado == ServiceStatus.enabled) reiniciar();
      });
    } catch (_) {}
    _vigia = Timer.periodic(const Duration(seconds: 15), (_) => _vigilar());
    _arrancar();
  }

  void _apagar() {
    _arranque++;
    _arrancando = false;
    _ciclo?.dispose();
    _ciclo = null;
    _servicio?.cancel();
    _servicio = null;
    _vigia?.cancel();
    _reintento?.cancel();
    _suscripcion?.cancel();
    _suscripcion = null;
  }

  bool _arrancando = false;

  Future<void> _arrancar() async {
    _reintento?.cancel();
    final mio = ++_arranque;
    final ResultadoPermiso permiso;
    _arrancando = true;
    try {
      permiso = await Ubicacion.pedirPermisos();
    } catch (_) {
      if (mio == _arranque) _reintentar();
      return;
    } finally {
      if (mio == _arranque) _arrancando = false;
    }
    if (mio != _arranque) return;
    if (!permiso.concedido) {
      await _suscripcion?.cancel();
      _suscripcion = null;
      _emitirError(
        PermisoUbicacionDenegado(permiso.motivo ?? 'Sin permiso de ubicacion'),
      );
      return;
    }
    if (_error is PermisoUbicacionDenegado) _error = null;

    final anterior = _suscripcion;
    _suscripcion = null;
    await anterior?.cancel();
    if (mio != _arranque) return;
    _inicioFlujo = DateTime.now();
    // Distancia minima 0: en el mapa se quiere un fix por segundo aun quieto,
    // para que la precision en pantalla sea la de ahora y para que el vigia
    // sepa distinguir "parado" de "el GPS no entrega".
    _suscripcion = Ubicacion.flujo(distanciaMinimaM: 0, soloChipGps: _soloChipGps)
        .listen(
          _alFix,
          onError: (Object e) {
            if (e is LocationServiceDisabledException) {
              _emitirError(
                const PermisoUbicacionDenegado(
                  'La ubicacion del telefono esta apagada. Activala para ver '
                  'donde estas.',
                ),
              );
              return;
            }
            _reintentar();
          },
          onDone: _reintentar,
        );
  }

  void _reintentar() {
    _reintento?.cancel();
    _reintento = Timer(const Duration(seconds: 3), reiniciar);
  }

  /// Si el proveedor actual lleva un rato sin dar ni un fix, se prueba el otro.
  void _vigilar() {
    if (_error != null) return;
    final ultimo = _ultimoFixVivo;
    final desde = ultimo == null || ultimo.isBefore(_inicioFlujo)
        ? _inicioFlujo
        : ultimo;
    if (DateTime.now().difference(desde) > const Duration(seconds: 40)) {
      _soloChipGps = !_soloChipGps;
      _arrancar();
    }
  }

  void _alFix(Position p) {
    final deCache = Ubicacion.esDeCache(p);
    // Al reabrir el flujo vuelve a llegar la ultima conocida. Si ya hay una
    // posicion mas nueva, esa vieja no la puede pisar.
    final actual = _ultima;
    if (deCache && actual != null && !p.timestamp.isAfter(actual.timestamp)) {
      if (_error != null) {
        _error = null;
        _salida.add(actual);
      }
      return;
    }
    if (!deCache) _ultimoFixVivo = DateTime.now();
    _ultima = p;
    _error = null;
    _salida.add(p);
  }

  void _emitirError(Object e) {
    _error = e;
    _salida.addError(e);
  }
}

class PermisoUbicacionDenegado implements Exception {
  const PermisoUbicacionDenegado(this.motivo);

  final String motivo;

  @override
  String toString() => motivo;
}
