import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/rumbo.dart';

/// Como acompana la camara a la posicion.
enum ModoCamara {
  /// El mapa quieto donde lo dejo la persona.
  libre,

  /// Centrado en la posicion, con el norte arriba.
  centrado,

  /// Como un navegador: centrado, girado para que hacia donde se va quede
  /// arriba, y con la flecha baja en la pantalla para ver mas camino adelante.
  rumbo,
}

/// La camara del mapa persiguiendo a la posicion, y la brujula.
///
/// Es de la pantalla del mapa y vive lo que ella: la pantalla le presta el
/// reloj de los cuadros ([vsync]), le dice donde esta la persona ([posicion])
/// y se redibuja cuando esto le avisa ([alCambiar], que es su `setState`).
class SeguidorDeCamara {
  SeguidorDeCamara({
    required this._vsync,
    required this.mapa,
    required this._posicion,
    required this._altoPantalla,
    required this._alCambiar,
  });

  final MapController mapa;
  final TickerProvider _vsync;
  final Position? Function() _posicion;
  final double Function() _altoPantalla;
  final void Function(VoidCallback cambio) _alCambiar;

  /// Como sigue la camara a la posicion. Arranca en modo navegador: abrir el
  /// mapa tiene que mostrar donde estoy y hacia donde voy sin tocar nada.
  ///
  /// Pasa a libre en cuanto el usuario arrastra: pelear contra un recentrado
  /// automatico mientras se mira un lindero es la forma mas rapida de que
  /// alguien cierre la app.
  ///
  /// Quien lo cambia desde afuera lo hace adentro de su `setState`: de el
  /// depende el dibujo del boton de centrar.
  ModoCamara modo = ModoCamara.rumbo;
  bool get siguiendo => modo != ModoCamara.libre;

  /// Si el mapa ya se dibujo una vez. Antes de eso no tiene camara que mover.
  bool get listo => _listo;
  bool _listo = false;

  /// Hacia donde mira el telefono segun la brujula, en grados desde el norte.
  double? get brujula => _brujula;
  double? _brujula;

  StreamSubscription<CompassEvent>? _brujulaSub;
  bool _cerrado = false;

  /// Mueve la camara de a poco hacia la posicion en cada cuadro, en vez de
  /// saltar con cada fix: los saltos de un segundo marean y no dejan leer.
  ///
  /// Se crea recien cuando hay que mover la camara. Si el mapa se cierra sin
  /// haber tenido nunca una posicion no llega a existir, y no hay que crearlo
  /// al cerrar solo para tener que soltar.
  Ticker? _cuadros;

  /// Hacia donde se va: el rumbo del GPS andando, la brujula quieto.
  ///
  /// Andando manda el GPS porque la brujula, adentro de una camioneta, la
  /// tuercen el motor y la carroceria. Quieto el rumbo del GPS es ruido, y ahi
  /// la brujula es lo unico que sabe hacia donde mira la persona.
  double? get rumbo {
    final p = _posicion();
    if (p == null) return null;
    return rumboConfiable(p) ?? _brujula;
  }

  void arrancarBrujula() {
    final eventos = FlutterCompass.events;
    if (eventos == null) return; // Telefono sin magnetometro.
    _brujulaSub = eventos.listen((e) {
      final h = e.heading;
      if (h == null || h.isNaN || _cerrado) return;
      final grados = (h % 360 + 360) % 360;
      final antes = _brujula;
      // La brujula manda decenas de lecturas por segundo y tiembla un par de
      // grados. Redibujar por cada una gasta bateria sin que se note.
      if (antes != null && diferenciaAngular(antes, grados).abs() < 2) {
        return;
      }
      _alCambiar(() => _brujula = grados);
      if (modo == ModoCamara.rumbo) seguir();
    }, onError: (_) {});
  }

  /// El mapa ya tiene camara: desde aca se la puede mover.
  void mapaListo() {
    _listo = true;
    seguir();
  }

  /// Pone la camara a perseguir la posicion, si se esta siguiendo.
  void seguir() {
    if (_cerrado || !siguiendo || !_listo || _posicion() == null) return;
    final cuadros = _cuadros ??= _vsync.createTicker(_alCuadro);
    if (!cuadros.isActive) cuadros.start();
  }

  void _alCuadro(Duration _) {
    final p = _posicion();
    if (_cerrado || !siguiendo || !_listo || p == null) {
      _cuadros?.stop();
      return;
    }
    final camara = mapa.camera;
    final rumbo = modo == ModoCamara.rumbo ? this.rumbo : null;
    final paso = pasoDeCamara(
      centro: camara.center,
      giro: camara.rotation,
      zoom: camara.zoom,
      posicion: LatLng(p.latitude, p.longitude),
      rumbo: rumbo,
      conRumbo: modo == ModoCamara.rumbo,
      // El alto solo hace falta para adelantar la camara, que es con rumbo.
      altoPantalla: rumbo == null ? 0 : _altoPantalla(),
    );
    mapa.moveAndRotate(paso.centro, camara.zoom, paso.giro);
    if (paso.llego) _cuadros?.stop();
  }

  /// El boton de centrar, como en los navegadores: desde libre va a modo
  /// navegador; despues alterna entre navegador y norte arriba.
  void alternar() {
    _alCambiar(() {
      modo = switch (modo) {
        ModoCamara.libre => ModoCamara.rumbo,
        ModoCamara.rumbo => ModoCamara.centrado,
        ModoCamara.centrado => ModoCamara.rumbo,
      };
    });
    if (_listo && mapa.camera.zoom < 16) {
      mapa.move(mapa.camera.center, 17);
    }
    seguir();
  }

  void dispose() {
    _cerrado = true;
    _brujulaSub?.cancel();
    _cuadros?.dispose();
  }
}
