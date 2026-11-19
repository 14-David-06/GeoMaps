import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../camiones/seguimiento.dart' show SeguimientoVuelta;
import '../../core/geo.dart';
import '../../core/indicaciones.dart';
import '../../core/ruteo.dart';
import '../../state/grabacion.dart';
import '../../state/proyecto_activo.dart';
import '../../state/sesion.dart';
import '../../state/sincronizador.dart';
import '../../state/voz.dart';
import '../../state/zona_guaicaramo.dart';
import '../capa_ruta.dart' show formatearDistancia;

/// Como se lee un provider. Es `ref.read`, con el nombre de lo que hace: asi
/// la ruta del mapa no necesita una pantalla para andar, y se prueba sin ella.
typedef Leer = T Function<T>(ProviderListenable<T> proveedor);

/// La ruta que el mapa esta mostrando: a donde va, por donde, cuanto falta, y
/// lo que hay que ir diciendo.
///
/// Vive lo que la pantalla del mapa y no en un provider porque no sobrevive a
/// salir de el: una ruta calculada hace media hora, desde donde se estaba
/// antes, no sirve. Se vuelve a marcar el punto y listo.
///
/// No sabe nada de dibujar. Lo que necesita de la pantalla lo recibe por
/// funciones: donde esta la persona, como se le avisa algo, como se le pide un
/// nombre o una calificacion. La pantalla se redibuja escuchandola.
class NavegacionDelMapa extends ChangeNotifier {
  NavegacionDelMapa({
    required this._leer,
    required this.archivoVias,
    required this._posicion,
    required this._avisar,
    required this._alSeguir,
    required this._pedirNombre,
    required this._calificar,
    this._alQuitar,
    this._reloj = DateTime.now,
  });

  final Leer _leer;

  /// El asset de vias del predio. Sin el no hay por donde trazar nada.
  final String? archivoVias;

  final Position? Function() _posicion;
  final void Function(String texto) _avisar;

  /// Poner la camara en modo navegador: con una ruta nueva, lo que se quiere
  /// ver es el camino.
  final VoidCallback _alSeguir;
  final Future<String?> Function(String sugerido) _pedirNombre;

  /// Terminar la ruta iniciada preguntando que tal estuvo.
  final Future<void> Function({required bool llego}) _calificar;

  /// Lo que la pantalla suelta junto con la ruta: el acopio al que iba.
  final VoidCallback? _alQuitar;
  final DateTime Function() _reloj;

  /// El punto que se marco en el mapa, y la ruta por via hasta el.
  LatLng? get destino => _destino;
  LatLng? _destino;

  /// Como se llama el destino, si es un lugar con nombre -un acopio- y no un
  /// punto marcado a mano. Va en la tarjeta de la ruta.
  String? get nombreDestino => _nombreDestino;
  String? _nombreDestino;

  Ruta? get ruta => _ruta;
  Ruta? _ruta;

  ProgresoRuta? get progreso => _progreso;
  ProgresoRuta? _progreso;

  /// Lo que hay que ir diciendo de la ruta actual. Se arma con cada ruta
  /// nueva: los giros son de esa ruta y no de la anterior.
  GuiaRuta? _guia;

  /// Cuando se dijo por ultima vez que se salio de la ruta. Bajo palma el GPS
  /// salta y la ruta se recalcula seguido: decirlo cada vez seria un sermon.
  DateTime? _desvioDicho;

  bool get calculando => _calculando;
  bool _calculando = false;

  /// Si la ruta que se esta siguiendo ya esta guardada: la que se acaba de
  /// guardar, o una que se abrio de la lista. El boton no guarda dos veces.
  bool get guardada => _guardada;
  bool _guardada = false;

  /// Para descartar el resultado de un calculo que quedo viejo: si alguien
  /// marca otro destino mientras se arma el grafo, el primero no puede pisar
  /// al segundo al terminar.
  int _calculo = 0;

  /// Mientras se muestra el dialogo de calificar no se vuelve a abrir: los
  /// fixes siguen llegando y cada uno diria otra vez "llegaste".
  bool _calificando = false;

  /// La pantalla ya se cerro: lo que estuviera a medio calcular se descarta.
  bool _cerrado = false;

  /// Si lo que se esta grabando es una ruta iniciada desde el mapa, y no un
  /// recorrido libre ni el viaje de un camion.
  static bool esNavegacion(EstadoGrabacion g) =>
      g.grabando && g.propiedades['tipo'] == 'navegacion';

  void _cambio() {
    if (!_cerrado) notifyListeners();
  }

  /// Deja puesto un destino sin calcular todavia: falta el primer fix.
  /// [alFix] traza la ruta en cuanto llegue, igual que cuando se marca un
  /// punto sin senal. Es para cuando el mapa se abre ya yendo a un lugar.
  void retomar(LatLng punto, {String? nombre}) {
    _destino = punto;
    _nombreDestino = nombre;
  }

  /// Marca un destino y traza la ruta por via hasta el.
  void fijarDestino(LatLng punto, {String? nombre}) {
    _destino = punto;
    _nombreDestino = nombre;
    _ruta = null;
    _progreso = null;
    _guia = null;
    _guardada = false;
    _cambio();
    calcular(porDesvio: false);
  }

  void quitar() {
    _destino = null;
    _nombreDestino = null;
    _ruta = null;
    _progreso = null;
    _guia = null;
    _calculando = false;
    _guardada = false;
    _calculo++;
    _alQuitar?.call();
    _cambio();
  }

  /// La ruta que se esta mostrando salio de la lista de guardadas: no hay que
  /// ofrecer guardarla otra vez.
  void marcarGuardada() {
    _guardada = true;
    _cambio();
  }

  // ------------------------------- Voz -------------------------------

  /// Si la ruta se esta siguiendo de verdad -se inicio, o es la de una vuelta
  /// de camion- y no solo mirando cuanto falta. Solo ahi la app habla:
  /// marcar un punto para ver la distancia no es pedir indicaciones.
  bool get _seSigueLaRuta {
    final g = _leer(grabadorProvider);
    return esNavegacion(g) || (g.grabando && g.esVuelta);
  }

  void _decir(String? frase) {
    if (frase == null || !_seSigueLaRuta) return;
    _leer(locutorProvider).decir(frase);
  }

  void _decirDesvio() {
    final ahora = _reloj();
    final ultimo = _desvioDicho;
    if (ultimo != null && ahora.difference(ultimo).inSeconds < 45) return;
    _desvioDicho = ahora;
    _decir(GuiaRuta.alDesviarse);
  }

  /// Si la llegada a este destino ya la anuncia la vuelta del camion: son los
  /// vagones o el punto de salida, y decirlo dos veces sobra.
  bool _loAnunciaLaVuelta() {
    final g = _leer(grabadorProvider);
    final destino = _destino;
    if (!g.esVuelta || destino == null) return false;
    final seg = SeguimientoVuelta.de(g.propiedades);
    final aca = PuntoGeo(destino.latitude, destino.longitude);
    bool cerca(PuntoGeo? p) => p != null && distanciaM(aca, p) < 60;
    return cerca(seg.punto) || cerca(seg.salida?.punto);
  }

  // ------------------------------ Guardar ------------------------------

  /// Guarda la ruta que se esta mostrando, con el nombre que se elija.
  ///
  /// Se guarda la linea completa tal como se ve, desde donde se pidio. Queda en
  /// el telefono al instante y sube sola en cuanto haya red: guardar no puede
  /// depender de tener senal, que es justo lo que falta en el lote.
  Future<void> guardar() async {
    final ruta = _ruta;
    final usuario = _leer(sesionProvider).sesion?.codigoUsuario;
    if (ruta == null || usuario == null || usuario.isEmpty) return;

    final nombre = await _pedirNombre(
      _nombreDestino ?? 'Ruta de ${formatearDistancia(ruta.metrosTotales)}',
    );
    if (nombre == null || _cerrado) return;

    try {
      await _leer(trazadosRepositoryProvider).guardarRuta(
        usuarioCodigo: usuario,
        nombre: nombre,
        linea: [
          for (final p in ruta.completa) PuntoGeo(p.latitude, p.longitude),
        ],
        metros: ruta.metrosTotales,
      );
    } catch (_) {
      _avisar('No se pudo guardar la ruta en el telefono.');
      return;
    }
    if (_cerrado) return;
    _guardada = true;
    _cambio();
    _avisar('Ruta guardada. Sube a la base cuando haya senal.');
    unawaited(_leer(sincronizadorProvider.notifier).sincronizar());
  }

  // ----------------------------- Calcular -----------------------------

  /// Calcula -o recalcula- la ruta desde donde se esta parado ahora.
  ///
  /// Siempre desde la posicion actual y no desde donde se marco el destino: eso
  /// es lo que hace que recalcular sirva de algo cuando alguien agarro otro
  /// camino.
  Future<void> calcular({required bool porDesvio, bool avisar = true}) async {
    final archivo = archivoVias;
    final destino = _destino;
    if (archivo == null || destino == null) return;

    if (_posicion() == null) {
      if (avisar) {
        _avisar(
          'Sin senal de GPS todavia no hay desde donde trazar la ruta. '
          'Sali a cielo abierto y volve a marcar el punto.',
        );
      }
      return;
    }

    final mio = ++_calculo;
    _calculando = true;
    _cambio();
    if (porDesvio) _decirDesvio();

    try {
      // La primera vez esto arma el grafo de las vias, que cuesta unas decimas
      // de segundo. De ahi en mas ya esta en memoria y vuelve al instante.
      final red = await _leer(redVialProvider(archivo).future);
      if (_cerrado || mio != _calculo) return;

      // La posicion se vuelve a leer despues del await: mientras se armaba el
      // grafo pudo entrar otro fix, y rutear desde el anterior deja la ruta
      // naciendo unos metros atras.
      final p = _posicion();
      if (p == null) return;
      final desde = LatLng(p.latitude, p.longitude);

      final ruta = red.ruta(desde: desde, hasta: destino);
      if (_cerrado || mio != _calculo) return;

      _ruta = ruta;
      _progreso = ruta?.progreso(desde);
      _guia = ruta == null ? null : GuiaRuta(ruta, destino: _nombreDestino);
      _calculando = false;
      // Con una ruta nueva se pasa a modo navegador, como al tocar "iniciar"
      // en cualquier navegador: lo que se quiere ver ahora es el camino.
      if (ruta != null && !porDesvio) _alSeguir();
      _cambio();
      // La ruta de una vuelta no tiene boton de iniciar: se sigue desde que
      // aparece, asi que se anuncia aca.
      if (ruta != null && !porDesvio && _leer(grabadorProvider).esVuelta) {
        _decir(_guia?.alEmpezar());
      }

      if (ruta == null && avisar) {
        _avisar(
          porDesvio
              ? 'Desde aca no hay ruta por las vias del predio hasta el punto '
                    'marcado.'
              : 'No hay ruta por via hasta ese punto: o queda lejos de toda '
                    'via del predio, o esta en un sector que no se comunica '
                    'por adentro.',
        );
      }
    } catch (_) {
      if (_cerrado || mio != _calculo) return;
      _calculando = false;
      _cambio();
      // Sin las vias del predio no hay ruteo posible; el mapa sigue andando.
      if (avisar) {
        _avisar('No se pudieron leer las vias del predio para trazar la ruta.');
      }
    }
  }

  /// Con cada fix: cuanto falta, si llego, y si hay que recalcular.
  void alFix(Position p) {
    final ruta = _ruta;
    if (ruta == null) {
      // Hay un destino marcado pero no se pudo trazar ruta desde donde se
      // estaba: lejos de toda via, o sin fix todavia. Se reintenta callado con
      // cada posicion nueva -doscientos metros pueden ser justo lo que
      // faltaba-, en vez de obligar a marcar el punto de nuevo.
      if (_destino != null && !_calculando) {
        calcular(porDesvio: false, avisar: false);
      }
      return;
    }

    final progreso = ruta.progreso(LatLng(p.latitude, p.longitude));
    _progreso = progreso;
    _cambio();

    if (progreso.llego) {
      // Una ruta iniciada termina sola al llegar, y ahi se califica.
      if (esNavegacion(_leer(grabadorProvider))) {
        _decir(_guia?.alLlegar());
        unawaited(terminar(llego: true));
        return;
      }
      final nombre = _nombreDestino;
      if (!_loAnunciaLaVuelta()) _decir(_guia?.alLlegar());
      quitar();
      _avisar(
        nombre == null ? 'Llegaste al punto marcado.' : 'Llegaste: $nombre.',
      );
      return;
    }

    // El umbral se compara contra la precision del fix adentro de
    // `hayQueRecalcular`: con el GPS saltando bajo palma, un desvio aparente no
    // puede cambiar la ruta que alguien esta siguiendo.
    if (!_calculando && progreso.hayQueRecalcular(p.accuracy)) {
      calcular(porDesvio: true);
      return;
    }

    // El giro que viene, o cuanto falta. Casi siempre no hay nada que decir.
    _decir(_guia?.alAvanzar(progreso));
  }

  // ------------------------- Iniciar y calificar -------------------------

  /// Inicia la ruta que se esta mostrando: desde aca se graba por donde se va
  /// de verdad, y al llegar -o al terminarla antes- se pregunta que tal
  /// estuvo. Lo que se califica es ese recorrido, no la linea azul.
  Future<void> iniciar() async {
    final ruta = _ruta;
    final destino = _destino;
    if (ruta == null || destino == null) return;

    await _leer(grabadorProvider.notifier).iniciar(
      nombre: 'Ruta a ${_nombreDestino ?? 'punto marcado'}',
      destino: PuntoGeo(destino.latitude, destino.longitude),
      destinoNombre: _nombreDestino,
      propiedades: {
        'tipo': 'navegacion',
        // Lo que la app prometio, para comparar con lo que se hizo.
        'ruta_sugerida_m': ruta.metrosTotales.round(),
        'ruta_sugerida_min': ruta.minutos.round(),
      },
      proyectoCodigo: await _leer(proyectoParaGuardarProvider.future),
    );
    if (_cerrado) return;
    if (!_leer(grabadorProvider).grabando) {
      _avisar('No se pudo iniciar la ruta.');
      return;
    }
    _alSeguir();
    _cambio();
    _avisar('Ruta iniciada. Al llegar te pregunto que tal estuvo.');
    _decir(_guia?.alEmpezar());
  }

  /// Termina la ruta iniciada y pide la calificacion.
  Future<void> terminar({required bool llego}) async {
    if (_calificando) return;
    _calificando = true;
    try {
      quitar();
      await _calificar(llego: llego);
    } finally {
      _calificando = false;
    }
  }

  @override
  void dispose() {
    _cerrado = true;
    super.dispose();
  }
}
