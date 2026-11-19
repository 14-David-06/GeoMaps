import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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

  /// Cuanto es "un rato": mas largo cada vez que el cambio no sirvio.
  final _paciencia = PacienciaGps();

  /// Si el flujo corre como servicio en primer plano, con su notificacion. Lo
  /// prende quien graba un viaje y lo apaga al terminar.
  bool _enFondo = false;
  DateTime _inicioFlujo = DateTime.now();
  DateTime? _ultimoFixVivo;

  /// Cada arranque se numera. Volver a la app y prender la ubicacion pueden
  /// pedir un arranque a la vez, y sin esto quedaban dos flujos vivos.
  int _arranque = 0;

  Position? _ultima;
  Object? _error;

  /// La ultima posicion que llego, sin suscribirse. Para una cuenta al pasar,
  /// como la distancia de cada vuelta en la lista; nula si el GPS no esta
  /// prendido o todavia no dio nada.
  Position? get ultima => _ultima;

  /// Olvida la ultima posicion y el ultimo error, como recien abierta la app.
  ///
  /// Es para las pruebas: el GPS es uno solo para toda la app, y sin esto cada
  /// prueba arrancaria parada donde quedo la anterior.
  @visibleForTesting
  void olvidar() {
    _ultima = null;
    _error = null;
    _ultimoFixVivo = null;
  }

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

  /// Reabre el flujo **solo si se quedo mudo**: venia dando posiciones y dejo
  /// de darlas, o termino en error. Es lo que pide quien entra al mapa.
  ///
  /// Si todavia no dio ninguna posicion no lo toca. Sin internet el primer
  /// fix tarda minutos -el telefono tiene que bajar del satelite lo que con
  /// red le llega en un segundo- y esa escucha tiene que ser seguida: reabrir
  /// el flujo la corta y la hace empezar de nuevo. Antes se reabria en cada
  /// entrada al mapa, que es justo lo que hace quien esta esperando el GPS.
  void despertar() {
    final ultimo = _ultimoFixVivo;
    final mudo =
        ultimo != null &&
        DateTime.now().difference(ultimo) > const Duration(seconds: 20);
    if (_error != null || mudo) reiniciar();
  }

  /// Mantiene la ubicacion viva con la pantalla apagada mientras [activo].
  ///
  /// Es un ajuste del unico flujo y no un flujo aparte por la misma razon de
  /// arriba: un segundo `getPositionStream` heredaria el primero y su
  /// notificacion nunca se prenderia. Cambiarlo reabre el flujo para todos;
  /// el mapa ni se entera, porque sigue escuchando [posiciones].
  void grabarEnFondo(bool activo) {
    if (_enFondo == activo) return;
    _enFondo = activo;
    // Si nadie escucha todavia, el ajuste se toma en el proximo arranque.
    if (_salida.hasListener) _arrancar();
  }

  void _prender() {
    _ciclo = AppLifecycleListener(onResume: reiniciar);
    // Si alguien apaga y prende la ubicacion, el flujo muere con el apagado y
    // no vuelve solo.
    // En el navegador no existe: el vigia de abajo lo cubre.
    if (!kIsWeb) {
      try {
        _servicio = Geolocator.getServiceStatusStream().listen((estado) {
          if (estado == ServiceStatus.enabled) reiniciar();
        });
      } catch (_) {}
    }
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
    _suscripcion =
        Ubicacion.flujo(
          distanciaMinimaM: 0,
          soloChipGps: _soloChipGps,
          enFondo: _enFondo,
        ).listen(
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
    if (_paciencia.seAgoto(DateTime.now(), desde)) {
      _paciencia.alCambiar();
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
    if (!deCache) {
      _ultimoFixVivo = DateTime.now();
      _paciencia.alFix();
    }
    _ultima = p;
    _error = null;
    _salida.add(p);
  }

  void _emitirError(Object e) {
    _error = e;
    _salida.addError(e);
  }
}

/// Cuanto se espera sin un fix antes de reabrir el GPS con el otro proveedor.
///
/// El primer cambio es a los 40 segundos, como siempre: es lo que rescata al
/// telefono raro donde el proveedor de Google no entrega nada. Pero si el
/// cambio no sirvio, el problema no es el proveedor, es que no hay senal de
/// GPS todavia -bajo la palma, o sin internet, donde el primer fix tarda
/// minutos-, y ahi reabrir cada 40 segundos es contraproducente: cada vez que
/// se reabre, el telefono deja de escuchar los satelites y vuelve a empezar.
/// Por eso cada espera es el doble de la anterior, hasta cinco minutos, y
/// vuelve a ser corta en cuanto llega un fix.
class PacienciaGps {
  PacienciaGps({
    this.primera = const Duration(seconds: 40),
    this.tope = const Duration(minutes: 5),
  });

  final Duration primera;
  final Duration tope;

  int _cambios = 0;

  /// Lo que se espera ahora antes de cambiar de proveedor.
  Duration get espera {
    final doblada = primera * (1 << (_cambios > 8 ? 8 : _cambios));
    return doblada > tope ? tope : doblada;
  }

  /// Si paso demasiado sin un fix, contando desde [desde].
  bool seAgoto(DateTime ahora, DateTime desde) =>
      ahora.difference(desde) > espera;

  /// Se cambio de proveedor y hay que ver si sirve: la proxima espera es mas
  /// larga.
  void alCambiar() => _cambios++;

  /// Llego una posicion: el GPS anda, y la espera vuelve a ser la corta.
  void alFix() => _cambios = 0;
}

class PermisoUbicacionDenegado implements Exception {
  const PermisoUbicacionDenegado(this.motivo);

  final String motivo;

  @override
  String toString() => motivo;
}
