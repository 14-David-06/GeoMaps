import 'dart:async';
import 'dart:math' as math;
// Con prefijo: flutter_map exporta su propio Path<LatLng> y tapa el de dibujo.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../camiones/panel_viaje.dart' show PanelViaje;
import '../core/acopios.dart';
import '../core/geo.dart';
import '../core/parcelas.dart';
import '../core/ruteo.dart';
import '../core/ubicacion.dart';
import '../core/vias.dart';
import '../data/db/app_database.dart';
import '../data/db/enums.dart';
import '../state/captura.dart';
import '../state/gps.dart';
import '../state/grabacion.dart';
import '../state/providers.dart';
import '../state/sesion.dart';
import '../state/sincronizador.dart';
import '../state/zona_guaicaramo.dart';
import 'capa_acopios.dart';
import 'capa_parcelas.dart';
import 'capa_pdf.dart';
import 'capa_ruta.dart';
import 'capa_vias.dart';
import 'capas_panel.dart';
import 'calificar_ruta.dart';
import 'importar_mapa_page.dart';
import 'medicion.dart';
import 'panel_grabacion.dart';
import 'proveedor_teselas.dart';
import 'rutas_guardadas.dart';
import 'theme.dart';
import 'trazado_page.dart';
import 'waypoint_page.dart';

/// La pantalla principal: el mapa.
///
/// Lo unico que no puede faltar nunca en ella es **donde estoy y que tan
/// confiable es ese punto**. El circulo de precision se dibuja siempre, no como
/// opcion: un punto azul sin su radio hace creer que el GPS sabe mas de lo que
/// sabe.
///
/// Esta es la primera version real. Todavia no lee MBTiles del usuario ni
/// graba recorridos (si guarda las rutas calculadas); sirve para responder en el telefono las dos preguntas que
/// deciden todo el proyecto: si `flutter_map` rinde con imagen satelital, y si
/// el GPS entrega precision util bajo condiciones de campo.
class MapaPage extends ConsumerStatefulWidget {
  const MapaPage({
    this.archivoVias,
    this.archivoParcelas,
    this.archivoAcopios,
    this.destinoInicial,
    this.nombreDestinoInicial,
    this.panelSuperior,
    super.key,
  });

  /// El mapa de Guaicaramo, con sus vias, lotes y acopios. Un solo lugar
  /// nombra los archivos del predio para que todos los que lo abren -la
  /// tarjeta del inicio, el modulo de camiones- abran el mismo.
  const MapaPage.guaicaramo({
    this.destinoInicial,
    this.nombreDestinoInicial,
    this.panelSuperior,
    super.key,
  }) : archivoVias = 'guaicaramo-vias.json',
       archivoParcelas = 'guaicaramo-parcelas.json',
       archivoAcopios = 'guaicaramo-acopios.json';

  /// El asset de vias del predio que se esta abriendo, si es que abre uno.
  /// Nulo es el mapa a secas: satelite o calles y la posicion propia.
  final String? archivoVias;

  /// El asset de lotes del predio (bloques y parcelas), si los tiene.
  final String? archivoParcelas;

  /// El asset de acopios del predio, si los tiene.
  final String? archivoAcopios;

  /// Abrir el mapa ya yendo hacia un punto: la vuelta que un conductor acaba
  /// de tomar. La ruta se traza sola con el primer fix.
  final LatLng? destinoInicial;
  final String? nombreDestinoInicial;

  /// Algo que va arriba, debajo de la barra del GPS. Lo pone quien abre el
  /// mapa para una tarea -el viaje que se esta grabando- sin que el mapa tenga
  /// que saber de que se trata.
  final Widget? panelSuperior;

  /// Cambia el destino del mapa que contiene a [context] y traza la ruta
  /// hasta el. Es para lo que va en [panelSuperior]: el viaje de un camion
  /// tiene dos tramos -ir por los vagones, dejar el vacio- y pasar del uno al
  /// otro no puede obligar a salir del mapa.
  static void irA(BuildContext context, LatLng punto, {String? nombre}) {
    context.findAncestorStateOfType<_MapaPageState>()?._fijarDestino(
      punto,
      nombre: nombre,
    );
  }

  @override
  ConsumerState<MapaPage> createState() => _MapaPageState();
}

/// Como acompana la camara a la posicion.
enum _Seguimiento {
  /// El mapa quieto donde lo dejo la persona.
  libre,

  /// Centrado en la posicion, con el norte arriba.
  centrado,

  /// Como un navegador: centrado, girado para que hacia donde se va quede
  /// arriba, y con la flecha baja en la pantalla para ver mas camino adelante.
  rumbo,
}

class _MapaPageState extends ConsumerState<MapaPage>
    with SingleTickerProviderStateMixin {
  final _mapa = MapController();

  /// La posicion sale del [Gps] compartido, que es quien reintenta, alterna de
  /// proveedor y rearranca al volver a la app.
  StreamSubscription<Position>? _suscripcion;
  StreamSubscription<CompassEvent>? _brujulaSub;
  Position? _posicion;
  String? _error;

  /// Hacia donde mira el telefono segun la brujula, en grados desde el norte.
  double? _brujula;

  /// Como sigue la camara a la posicion. Arranca en modo navegador: abrir el
  /// mapa tiene que mostrar donde estoy y hacia donde voy sin tocar nada.
  ///
  /// Pasa a libre en cuanto el usuario arrastra: pelear contra un recentrado
  /// automatico mientras se mira un lindero es la forma mas rapida de que
  /// alguien cierre la app.
  _Seguimiento _modo = _Seguimiento.rumbo;
  bool get _siguiendo => _modo != _Seguimiento.libre;

  /// Mueve la camara de a poco hacia la posicion en cada cuadro, en vez de
  /// saltar con cada fix: los saltos de un segundo marean y no dejan leer.
  late final Ticker _camara = createTicker(_alCuadro);
  bool _mapaListo = false;

  CapaBase _capa = CapaBase.satelite;

  /// Las capas del predio que se estan dibujando. Todas se pueden apagar:
  /// sobre un lote recien sembrado, las lineas tapan justo lo que se fue a
  /// mirar. Se encienden y apagan desde el panel de capas.
  final Set<CapaPredio> _visibles = {...CapaPredio.values};

  /// Los planos importados se apagan todos juntos desde el mapa. Encender cada
  /// uno por separado es cosa de la pantalla de capas; aca lo que se necesita
  /// es poder ver el terreno limpio de un manotazo.
  bool _verPlanos = true;

  /// El punto que se marco en el mapa, y la ruta por via hasta el.
  ///
  /// Viven en la pantalla y no en un provider porque no sobreviven a salir del
  /// mapa: una ruta calculada hace media hora, desde donde estaba antes, no
  /// sirve. Se vuelve a marcar el punto y listo.
  LatLng? _destino;

  /// Como se llama el destino, si es un lugar con nombre -un acopio- y no un
  /// punto marcado a mano. Va en la tarjeta de la ruta.
  String? _nombreDestino;

  /// El acopio que se toco o se busco, antes de pedir la ruta hasta el.
  Acopio? _acopio;

  Ruta? _ruta;
  ProgresoRuta? _progreso;
  bool _calculando = false;

  /// Si la ruta que se esta siguiendo ya esta guardada: la que se acaba de
  /// guardar, o una que se abrio de la lista. El boton no guarda dos veces.
  bool _rutaGuardada = false;

  /// Para descartar el resultado de un calculo que quedo viejo: si alguien
  /// marca otro destino mientras se arma el grafo, el primero no puede pisar
  /// al segundo al terminar.
  int _calculo = 0;

  /// La pista de "manten pulsado" se muestra hasta que se usa una vez.
  bool _pistaVista = false;

  /// Midiendo: cada toque en el mapa suma un punto a [_medida] en vez de
  /// elegir lo que haya debajo del dedo.
  bool _midiendo = false;
  final List<LatLng> _medida = [];

  /// El punto marcado que se toco, con su tarjeta abajo.
  Waypoint? _punto;

  /// El recorrido o el area guardados que se estan mirando, y sus vertices ya
  /// convertidos: decodificar el GeoJSON en cada cuadro seria tirar trabajo.
  Trazado? _visto;
  List<LatLng> _vistoVertices = const [];

  /// El zoom manda sobre que rotulos se dibujan. Se guarda aca porque el mapa
  /// lo reporta por callback, no se puede leer en el build antes del primer
  /// cuadro.
  ///
  /// El area visible **no** se guarda: las capas no la necesitan -flutter_map
  /// ya descarta solo lo que queda fuera de pantalla- y guardarla obligaba a
  /// reconstruir la pantalla en cada cuadro del arrastre.
  double _zoom = 15;

  @override
  void initState() {
    super.initState();
    final destino = widget.destinoInicial;
    if (destino != null) {
      // Sin calcular todavia: falta el primer fix. `_revisarRuta` lo traza en
      // cuanto llegue, igual que cuando se marca un punto sin senal.
      _destino = destino;
      _nombreDestino = widget.nombreDestinoInicial;
      _pistaVista = true;
    } else {
      // Se salio del mapa con una ruta iniciada y se volvio: el recorrido
      // siguio grabando, asi que el mapa retoma hacia donde iba.
      final g = ref.read(grabadorProvider);
      final iba = g.destino;
      if (_esNavegacion(g) && iba != null) {
        _destino = LatLng(iba.latitud, iba.longitud);
        _nombreDestino = g.destinoNombre;
        _pistaVista = true;
      }
    }
    _suscripcion = Gps.instancia.posiciones.listen(
      _alFix,
      onError: (Object e) {
        if (!mounted || e is! PermisoUbicacionDenegado) return;
        setState(() => _error = e.motivo);
      },
    );
    // Entrar al mapa es la senal mas clara de que se quiere un fix ya: si el
    // flujo quedo mudo, no se espera al vigia.
    Gps.instancia.reiniciar();
    _arrancarBrujula();
  }

  @override
  void dispose() {
    _suscripcion?.cancel();
    _brujulaSub?.cancel();
    _camara.dispose();
    super.dispose();
  }

  void _alFix(Position p) {
    if (!mounted) return;
    setState(() {
      _posicion = p;
      _error = null;
    });
    _seguir();
    _revisarRuta(p);
  }

  void _arrancarBrujula() {
    final eventos = FlutterCompass.events;
    if (eventos == null) return; // Telefono sin magnetometro.
    _brujulaSub = eventos.listen((e) {
      final h = e.heading;
      if (h == null || h.isNaN || !mounted) return;
      final grados = (h % 360 + 360) % 360;
      final antes = _brujula;
      // La brujula manda decenas de lecturas por segundo y tiembla un par de
      // grados. Redibujar por cada una gasta bateria sin que se note.
      if (antes != null && _diferenciaAngular(antes, grados).abs() < 2) {
        return;
      }
      setState(() => _brujula = grados);
      if (_modo == _Seguimiento.rumbo) _seguir();
    }, onError: (_) {});
  }

  /// Hacia donde se va: el rumbo del GPS andando, la brujula quieto.
  ///
  /// Andando manda el GPS porque la brujula, adentro de una camioneta, la
  /// tuercen el motor y la carroceria. Quieto el rumbo del GPS es ruido, y ahi
  /// la brujula es lo unico que sabe hacia donde mira la persona.
  double? get _rumbo {
    final p = _posicion;
    if (p == null) return null;
    return _rumboConfiable(p) ?? _brujula;
  }

  /// Pone la camara a perseguir la posicion, si se esta siguiendo.
  void _seguir() {
    if (!_siguiendo || !_mapaListo || _posicion == null) return;
    if (!_camara.isActive) _camara.start();
  }

  /// Un cuadro de la camara: se acerca una fraccion de lo que falta. Asi el
  /// movimiento es suave y llega sin pasarse, sea un fix nuevo o la brujula.
  void _alCuadro(Duration _) {
    final p = _posicion;
    if (!mounted || !_siguiendo || !_mapaListo || p == null) {
      _camara.stop();
      return;
    }
    final camara = _mapa.camera;
    final rumbo = _modo == _Seguimiento.rumbo ? _rumbo : null;
    // En modo navegador sin rumbo -quieto y sin brujula- se deja el giro que
    // tenia: volver al norte con cada fix y girar de nuevo al arrancar marea.
    final giroObjetivo = rumbo != null
        ? -rumbo
        : (_modo == _Seguimiento.rumbo ? camara.rotation : 0.0);

    var objetivo = LatLng(p.latitude, p.longitude);
    if (rumbo != null) {
      // La flecha va en el tercio de abajo: lo que importa es lo que viene.
      final alto = MediaQuery.sizeOf(context).height;
      final metrosPorPixel =
          156543.03392 *
          math.cos(p.latitude * math.pi / 180) /
          math.pow(2, camara.zoom);
      objetivo = _adelantar(objetivo, rumbo, alto * 0.22 * metrosPorPixel);
    }

    const fraccion = 0.18;
    final dLat = objetivo.latitude - camara.center.latitude;
    final dLon = objetivo.longitude - camara.center.longitude;
    final dGiro = _diferenciaAngular(camara.rotation, giroObjetivo);

    final cerca = dLat.abs() < 1e-7 && dLon.abs() < 1e-7 && dGiro.abs() < 0.2;
    // Lejos -abrir el mapa, o volver de mirar otra zona- se va de una: una
    // animacion de varios kilometros es un viaje en avion que nadie pidio.
    final lejos = dLat.abs() > 0.02 || dLon.abs() > 0.02;
    final f = cerca || lejos ? 1.0 : fraccion;

    _mapa.moveAndRotate(
      LatLng(
        camara.center.latitude + dLat * f,
        camara.center.longitude + dLon * f,
      ),
      camara.zoom,
      camara.rotation + dGiro * f,
    );
    if (cerca) _camara.stop();
  }

  /// El boton de centrar, como en los navegadores: desde libre va a modo
  /// navegador; despues alterna entre navegador y norte arriba.
  void _alternarSeguimiento() {
    setState(() {
      _modo = switch (_modo) {
        _Seguimiento.libre => _Seguimiento.rumbo,
        _Seguimiento.rumbo => _Seguimiento.centrado,
        _Seguimiento.centrado => _Seguimiento.rumbo,
      };
    });
    if (_mapaListo && _mapa.camera.zoom < 16) {
      _mapa.move(_mapa.camera.center, 17);
    }
    _seguir();
  }

  /// Marca un destino en el mapa y traza la ruta por via hasta el.
  ///
  /// El gesto es mantener pulsado y no un toque simple: sobre un mapa, el toque
  /// simple es lo que uno hace sin querer mientras arrastra, y poner un destino
  /// cada vez que alguien roza la pantalla vuelve el mapa inusable.
  void _fijarDestino(LatLng punto, {String? nombre}) {
    setState(() {
      _destino = punto;
      _nombreDestino = nombre;
      // Un punto marcado a mano deja de lado el acopio elegido: la ruta ya
      // no va a el.
      if (nombre == null) _acopio = null;
      _ruta = null;
      _progreso = null;
      _rutaGuardada = false;
      _pistaVista = true;
    });
    _calcularRuta(porDesvio: false);
  }

  void _quitarRuta() {
    setState(() {
      _destino = null;
      _nombreDestino = null;
      _acopio = null;
      _ruta = null;
      _progreso = null;
      _calculando = false;
      _rutaGuardada = false;
      _calculo++;
    });
  }

  /// Guarda la ruta que se esta mostrando, con el nombre que se elija.
  ///
  /// Se guarda la linea completa tal como se ve, desde donde se pidio. Queda en
  /// el telefono al instante y sube sola en cuanto haya red: guardar no puede
  /// depender de tener senal, que es justo lo que falta en el lote.
  Future<void> _guardarRuta() async {
    final ruta = _ruta;
    final usuario = ref.read(sesionProvider).sesion?.codigoUsuario;
    if (ruta == null || usuario == null || usuario.isEmpty) return;

    final nombre = await pedirNombreRuta(
      context,
      _nombreDestino ?? 'Ruta de ${formatearDistancia(ruta.metrosTotales)}',
    );
    if (nombre == null || !mounted) return;

    try {
      await ref
          .read(trazadosRepositoryProvider)
          .guardarRuta(
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
    if (!mounted) return;
    setState(() => _rutaGuardada = true);
    _avisar('Ruta guardada. Sube a la base cuando haya senal.');
    unawaited(ref.read(sincronizadorProvider.notifier).sincronizar());
  }

  /// Abre la lista de rutas guardadas y va hacia la que se elija.
  ///
  /// La ruta se vuelve a calcular desde donde se esta ahora: la guardada salio
  /// de otro lugar, y seguirla obligaria a ir primero hasta donde arrancaba.
  Future<void> _abrirRutasGuardadas() async {
    final elegida = await elegirRutaGuardada(context);
    if (elegida == null || !mounted) return;
    if (_destino != null) _quitarRuta();
    _fijarDestino(
      LatLng(elegida.destino.latitud, elegida.destino.longitud),
      nombre: elegida.nombre,
    );
    setState(() => _rutaGuardada = true);
  }

  /// Calcula -o recalcula- la ruta desde donde se esta parado ahora.
  ///
  /// Siempre desde la posicion actual y no desde donde se marco el destino: eso
  /// es lo que hace que recalcular sirva de algo cuando alguien agarro otro
  /// camino.
  Future<void> _calcularRuta({
    required bool porDesvio,
    bool avisar = true,
  }) async {
    final archivo = widget.archivoVias;
    final destino = _destino;
    if (archivo == null || destino == null) return;

    if (_posicion == null) {
      if (avisar) {
        _avisar(
          'Sin senal de GPS todavia no hay desde donde trazar la ruta. '
          'Sali a cielo abierto y volve a marcar el punto.',
        );
      }
      return;
    }

    final mio = ++_calculo;
    setState(() => _calculando = true);

    try {
      // La primera vez esto arma el grafo de las vias, que cuesta unas decimas
      // de segundo. De ahi en mas ya esta en memoria y vuelve al instante.
      final red = await ref.read(redVialProvider(archivo).future);
      if (!mounted || mio != _calculo) return;

      // La posicion se vuelve a leer despues del await: mientras se armaba el
      // grafo pudo entrar otro fix, y rutear desde el anterior deja la ruta
      // naciendo unos metros atras.
      final p = _posicion;
      if (p == null) return;
      final desde = LatLng(p.latitude, p.longitude);

      final ruta = red.ruta(desde: desde, hasta: destino);
      if (!mounted || mio != _calculo) return;

      setState(() {
        _ruta = ruta;
        _progreso = ruta?.progreso(desde);
        _calculando = false;
        // Con una ruta nueva se pasa a modo navegador, como al tocar "iniciar"
        // en cualquier navegador: lo que se quiere ver ahora es el camino.
        if (ruta != null && !porDesvio) _modo = _Seguimiento.rumbo;
      });
      if (ruta != null && !porDesvio) _seguir();

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
      if (!mounted || mio != _calculo) return;
      setState(() => _calculando = false);
      // Sin las vias del predio no hay ruteo posible; el mapa sigue andando.
      if (avisar) {
        _avisar('No se pudieron leer las vias del predio para trazar la ruta.');
      }
    }
  }

  /// Con cada fix: cuanto falta, si llego, y si hay que recalcular.
  void _revisarRuta(Position p) {
    final ruta = _ruta;
    if (ruta == null) {
      // Hay un destino marcado pero no se pudo trazar ruta desde donde se
      // estaba: lejos de toda via, o sin fix todavia. Se reintenta callado con
      // cada posicion nueva -doscientos metros pueden ser justo lo que
      // faltaba-, en vez de obligar a marcar el punto de nuevo.
      if (_destino != null && !_calculando) {
        _calcularRuta(porDesvio: false, avisar: false);
      }
      return;
    }

    final progreso = ruta.progreso(LatLng(p.latitude, p.longitude));
    setState(() => _progreso = progreso);

    if (progreso.llego) {
      // Una ruta iniciada termina sola al llegar, y ahi se califica.
      if (_esNavegacion(ref.read(grabadorProvider))) {
        unawaited(_terminarRuta(llego: true));
        return;
      }
      final nombre = _nombreDestino;
      _quitarRuta();
      _avisar(
        nombre == null ? 'Llegaste al punto marcado.' : 'Llegaste: $nombre.',
      );
      return;
    }

    // El umbral se compara contra la precision del fix adentro de
    // `hayQueRecalcular`: con el GPS saltando bajo palma, un desvio aparente no
    // puede cambiar la ruta que alguien esta siguiendo.
    if (!_calculando && progreso.hayQueRecalcular(p.accuracy)) {
      _calcularRuta(porDesvio: true);
    }
  }

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(texto), duration: const Duration(seconds: 5)),
    );
  }

  /// Un toque simple: elige el acopio que quede debajo del dedo, o suelta el
  /// que estaba elegido si se toco en otro lado.
  void _alTocar(LatLng punto, AcopiosPredio? acopios) {
    // Midiendo, el toque es un vertice y nada mas.
    if (_midiendo) {
      setState(() => _medida.add(punto));
      return;
    }

    // Con un destino marcado, tocar el mapa no cambia nada: la tarjeta de la
    // ruta manda. Un roce mientras se maneja no puede mover el resaltado a otro
    // acopio que no es a donde lleva la ruta. Se cierra la ruta y se elige.
    if (_destino != null) return;

    // Un punto marcado gana sobre el acopio de al lado: lo puso la persona, y
    // si lo toca es porque lo esta buscando.
    final marcado = puntoCercano(
      puntos: ref.read(puntosProvider).valueOrNull ?? const [],
      camara: _mapa.camera,
      toque: _mapa.camera.latLngToScreenOffset(punto),
    );
    if (marcado != null) {
      setState(() {
        _punto = marcado;
        _acopio = null;
      });
      return;
    }
    if (_punto != null) setState(() => _punto = null);
    if (acopios == null) return;

    final visibles =
        _visibles.contains(CapaPredio.acopios) &&
        _zoom >= CapaAcopios.zoomMinimo;
    final tocado = visibles
        ? acopioCercano(
            acopios: acopios,
            camara: _mapa.camera,
            // Se pasa por la camara y no se usa la posicion del evento: asi
            // el toque y los acopios se miden en la misma pantalla.
            toque: _mapa.camera.latLngToScreenOffset(punto),
          )
        : null;

    if (tocado == _acopio) return;
    setState(() => _acopio = tocado);
  }

  /// Muestra un acopio elegido desde el buscador: lo centra y lo deja elegido,
  /// con su tarjeta abajo para pedir la ruta.
  void _mostrarAcopio(Acopio a) {
    setState(() {
      _acopio = a;
      // Para ver el acopio hay que soltar la posicion: si no, el seguimiento
      // devuelve la camara a la flecha en el cuadro siguiente.
      _modo = _Seguimiento.libre;
    });
    if (_mapaListo) {
      _mapa.move(a.punto, math.max(_mapa.camera.zoom, 16));
    }
  }

  void _irAlAcopio(Acopio a) {
    _fijarDestino(a.punto, nombre: a.etiquetaLarga);
  }

  Future<void> _buscarAcopio(AcopiosPredio acopios) async {
    final p = _posicion;
    final elegido = await buscarAcopio(
      context,
      acopios,
      // Con la posicion, la lista pone primero el que queda mas cerca.
      desde: p == null ? null : LatLng(p.latitude, p.longitude),
    );
    if (elegido == null || !mounted) return;
    // Buscar es pedir ir a otro lado: la ruta anterior se suelta para que la
    // tarjeta del acopio nuevo, con su "Como llegar", quede a la vista.
    if (_destino != null) _quitarRuta();
    // Si se busco, es para verlo: se encienden los acopios si estaban
    // apagados, porque si no el resaltado aparece solo, sin sus vecinos.
    _visibles.add(CapaPredio.acopios);
    _mostrarAcopio(elegido);
  }

  // ------------------------- Iniciar y calificar -------------------------

  /// Si lo que se esta grabando es una ruta iniciada desde el mapa, y no un
  /// recorrido libre ni el viaje de un camion.
  static bool _esNavegacion(EstadoGrabacion g) =>
      g.grabando && g.propiedades['tipo'] == 'navegacion';

  /// Mientras se muestra el dialogo de calificar no se vuelve a abrir: los
  /// fixes siguen llegando y cada uno diria otra vez "llegaste".
  bool _calificando = false;

  /// Inicia la ruta que se esta mostrando: desde aca se graba por donde se va
  /// de verdad, y al llegar -o al terminarla antes- se pregunta que tal
  /// estuvo. Lo que se califica es ese recorrido, no la linea azul.
  Future<void> _iniciarRuta() async {
    final ruta = _ruta;
    final destino = _destino;
    if (ruta == null || destino == null) return;

    await ref
        .read(grabadorProvider.notifier)
        .iniciar(
          nombre: 'Ruta a ${_nombreDestino ?? 'punto marcado'}',
          destino: PuntoGeo(destino.latitude, destino.longitude),
          destinoNombre: _nombreDestino,
          propiedades: {
            'tipo': 'navegacion',
            // Lo que la app prometio, para comparar con lo que se hizo.
            'ruta_sugerida_m': ruta.metrosTotales.round(),
            'ruta_sugerida_min': ruta.minutos.round(),
          },
        );
    if (!mounted) return;
    if (!ref.read(grabadorProvider).grabando) {
      _avisar('No se pudo iniciar la ruta.');
      return;
    }
    setState(() => _modo = _Seguimiento.rumbo);
    _seguir();
    _avisar('Ruta iniciada. Al llegar te pregunto que tal estuvo.');
  }

  /// Termina la ruta iniciada y pide la calificacion.
  Future<void> _terminarRuta({required bool llego}) async {
    if (_calificando) return;
    _calificando = true;
    try {
      _quitarRuta();
      await terminarRutaCalificando(context, ref, llego: llego);
    } finally {
      _calificando = false;
    }
  }

  // ------------------------------ Medir ------------------------------

  void _empezarAMedir() {
    setState(() {
      _midiendo = true;
      _medida.clear();
      _acopio = null;
      _punto = null;
      _pistaVista = true;
      // Medir es mirar un lugar, no seguirse a uno mismo: si la camara sigue
      // a la flecha, el lote que se esta marcando se va de la pantalla.
      _modo = _Seguimiento.libre;
    });
  }

  void _dejarDeMedir() {
    setState(() {
      _midiendo = false;
      _medida.clear();
    });
  }

  /// Guarda lo medido como un area, con el nombre que se elija. Queda en "Lo
  /// que levante" y sube sola cuando haya senal.
  Future<void> _guardarArea() async {
    final usuario = ref.read(sesionProvider).sesion?.codigoUsuario;
    if (usuario == null || usuario.isEmpty || _medida.length < 3) return;
    final medida = Medicion(List.of(_medida));

    final nombre = await pedirNombreRuta(
      context,
      'Area de ${medida.areaTexto}',
      titulo: 'Guardar area',
    );
    if (nombre == null || !mounted) return;

    final Trazado guardado;
    try {
      guardado = await ref
          .read(trazadosRepositoryProvider)
          .guardarPoligono(
            usuarioCodigo: usuario,
            nombre: nombre,
            vertices: [
              for (final p in medida.puntos) PuntoGeo(p.latitude, p.longitude),
            ],
          );
    } catch (_) {
      _avisar('No se pudo guardar el area en el telefono.');
      return;
    }
    if (!mounted) return;
    _dejarDeMedir();
    _verTrazado(guardado, encuadrar: false);
    _avisar('Area guardada. Sube a la base cuando haya senal.');
    unawaited(ref.read(sincronizadorProvider.notifier).sincronizar());
  }

  // ------------------------- Puntos y recorridos -------------------------

  /// Marca un punto donde se esta parado, con la precision que da el GPS en
  /// ese momento. Si se esta grabando un recorrido, el punto queda atado a el
  /// y sale en el mismo archivo al compartirlo.
  Future<void> _marcarAqui() async {
    final p = _posicion;
    if (p == null || Ubicacion.esDeCache(p)) {
      _avisar(
        'Todavia no hay senal de GPS para marcar donde estas. Sali a cielo '
        'abierto, o manten pulsado el mapa para marcar un punto a mano.',
      );
      return;
    }
    final guardado = await marcarPunto(
      context,
      ref,
      punto: LatLng(p.latitude, p.longitude),
      precisionM: p.accuracy,
      altitudM: p.altitude == 0 ? null : p.altitude,
      trazadoCodigo: ref.read(grabadorProvider).codigo,
    );
    if (guardado != null) _avisar('Punto "${guardado.nombre}" guardado.');
  }

  /// Marca un punto elegido con el dedo. Queda dicho que no tiene GPS.
  Future<void> _marcarEn(LatLng punto) async {
    final guardado = await marcarPunto(context, ref, punto: punto);
    if (guardado == null || !mounted) return;
    setState(() => _punto = guardado);
  }

  Future<void> _borrarPunto(Waypoint w) async {
    await ref.read(waypointsRepositoryProvider).borrar(w.codigo);
    if (mounted) setState(() => _punto = null);
  }

  /// Muestra un recorrido o un area guardados, y encuadra el mapa en el.
  void _verTrazado(Trazado t, {bool encuadrar = true}) {
    final vertices = verticesDe(t);
    setState(() {
      _visto = t;
      _vistoVertices = vertices;
      _punto = null;
      _acopio = null;
      _modo = _Seguimiento.libre;
    });
    if (!encuadrar || !_mapaListo || vertices.isEmpty) return;
    _mapa.fitCamera(
      CameraFit.coordinates(
        coordinates: vertices,
        maxZoom: 18,
        // Arriba la barra del GPS y abajo la tarjeta: el trazado tiene que
        // quedar en lo que se ve, no debajo de ellas.
        padding: const EdgeInsets.fromLTRB(48, 150, 48, 190),
      ),
    );
  }

  /// La pantalla de planos. Vuelve con las esquinas del plano que se acaba de
  /// importar, o del que se pidio ver, y el mapa se encuadra sobre el.
  ///
  /// Sin esto, importar el mapa vial de otro municipio parece no hacer nada:
  /// la capa queda cargada, pero a kilometros de lo que se esta mirando.
  Future<void> _abrirPlanos() async {
    final esquinas = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(builder: (_) => const ImportarMapaPage()),
    );
    if (esquinas == null || esquinas.isEmpty || !mounted) return;
    setState(() {
      _verPlanos = true;
      _modo = _Seguimiento.libre;
    });
    if (!_mapaListo) return;
    _mapa.fitCamera(
      CameraFit.coordinates(
        coordinates: esquinas,
        maxZoom: 18,
        padding: const EdgeInsets.fromLTRB(32, 120, 32, 120),
      ),
    );
  }

  /// La lista de lo levantado: se elige algo y se lo ve en el mapa.
  Future<void> _abrirLevantados() async {
    final elegido = await elegirLevantado(context);
    if (elegido == null || !mounted) return;
    if (_destino != null) _quitarRuta();
    final trazado = elegido.trazado;
    final punto = elegido.punto;
    if (trazado != null) {
      _verTrazado(trazado);
    } else if (punto != null) {
      setState(() {
        _punto = punto;
        _acopio = null;
        _modo = _Seguimiento.libre;
      });
      if (_mapaListo) {
        _mapa.move(
          LatLng(punto.latitud, punto.longitud),
          math.max(_mapa.camera.zoom, 17),
        );
      }
    }
  }

  /// El menu de herramientas. Un solo boton para todas: con uno por
  /// herramienta la columna de botones tapaba medio costado del mapa.
  void _abrirHerramientas() {
    final g = ref.read(grabadorProvider);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (hoja) {
        void hacer(VoidCallback accion) {
          Navigator.pop(hoja);
          accion();
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Con la vuelta de un camion en curso la grabacion es de la
                // vuelta: se finaliza desde su franja, no desde aca.
                if (g.codigo == null)
                  ListTile(
                    leading: const Icon(
                      Icons.fiber_manual_record,
                      color: Colors.red,
                    ),
                    title: const Text('Grabar recorrido'),
                    subtitle: const Text(
                      'Por donde camines o manejes, tambien con la pantalla '
                      'apagada',
                    ),
                    onTap: () => hacer(() => iniciarRecorrido(context, ref)),
                  )
                else if (!g.esVuelta)
                  ListTile(
                    leading: const Icon(Icons.stop_circle_outlined),
                    title: const Text('Terminar el recorrido'),
                    subtitle: Text(g.nombre ?? ''),
                    onTap: () => hacer(() => terminarRecorrido(context, ref)),
                  ),
                ListTile(
                  leading: const Icon(Icons.add_location_alt_outlined),
                  title: const Text('Marcar un punto aqui'),
                  subtitle: const Text(
                    'Donde estas parado, con la precision del GPS',
                  ),
                  onTap: () => hacer(_marcarAqui),
                ),
                ListTile(
                  leading: const Icon(Icons.straighten),
                  title: const Text('Medir distancia o area'),
                  subtitle: const Text('Tocando puntos sobre el mapa'),
                  onTap: () => hacer(_empezarAMedir),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_special_outlined),
                  title: const Text('Lo que levante'),
                  subtitle: const Text(
                    'Recorridos, areas y puntos. Para verlos y compartirlos',
                  ),
                  onTap: () => hacer(_abrirLevantados),
                ),
                if (widget.archivoVias != null)
                  ListTile(
                    leading: const Icon(Icons.bookmarks_outlined),
                    title: const Text('Rutas guardadas'),
                    onTap: () => hacer(_abrirRutasGuardadas),
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: const Text('Mi cuenta'),
                  onTap: () => hacer(() => _mostrarCuenta(context)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// El panel de capas, que sube desde abajo sobre el mapa.
  void _abrirCapas({
    required int planos,
    required ParcelasPredio? parcelas,
    required ViasPredio? vias,
    required AcopiosPredio? acopios,
  }) {
    final capas = [
      if (parcelas != null) CapaPredio.lotes,
      if (vias != null) CapaPredio.vias,
      if (acopios != null) CapaPredio.acopios,
    ];
    final cuantos = {
      if (parcelas != null) CapaPredio.lotes: parcelas.parcelas.length,
      if (vias != null) CapaPredio.vias: vias.cuantas,
      if (acopios != null) CapaPredio.acopios: acopios.acopios.length,
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // Transparente arriba: lo que se apaga se tiene que ver apagarse.
      barrierColor: Colors.black12,
      builder: (hoja) => StatefulBuilder(
        // El estado vive en el mapa; la hoja solo se redibuja con el.
        builder: (hoja, redibujar) {
          void cambiar(VoidCallback c) {
            setState(c);
            redibujar(() {});
          }

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(hoja).height * 0.8,
            ),
            child: PanelCapas(
              base: _capa,
              onBase: (c) => cambiar(() => _capa = c),
              capas: capas,
              visibles: _visibles,
              cuantos: cuantos,
              onCapa: (capa, ver) => cambiar(() {
                ver ? _visibles.add(capa) : _visibles.remove(capa);
                if (capa == CapaPredio.acopios && !ver && _destino == null) {
                  _acopio = null;
                }
              }),
              planos: planos,
              verPlanos: _verPlanos,
              onPlanos: (v) => cambiar(() => _verPlanos = v),
              onAdministrarPlanos: () {
                Navigator.pop(hoja);
                _abrirPlanos();
              },
              onBuscarAcopio: acopios == null
                  ? null
                  : () {
                      Navigator.pop(hoja);
                      _buscarAcopio(acopios);
                    },
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aqui = _posicion == null
        ? null
        : LatLng(_posicion!.latitude, _posicion!.longitude);

    // Las vias del predio, si esta pantalla abrio uno. Se leen del asset una
    // sola vez por arranque y quedan en memoria.
    final vias = widget.archivoVias == null
        ? null
        : ref.watch(viasPredioProvider(widget.archivoVias!)).valueOrNull;

    // Los planos que el usuario importo y dejo encendidos. Vienen de la base,
    // asi que siguen ahi despues de cerrar la app.
    final planos = ref.watch(capasVisiblesProvider).valueOrNull ?? const [];

    final parcelas = widget.archivoParcelas == null
        ? null
        : ref
              .watch(parcelasPredioProvider(widget.archivoParcelas!))
              .valueOrNull;

    final acopios = widget.archivoAcopios == null
        ? null
        : ref.watch(acopiosPredioProvider(widget.archivoAcopios!)).valueOrNull;

    final verParcelas =
        parcelas != null && _visibles.contains(CapaPredio.lotes);
    final verVias = vias != null && _visibles.contains(CapaPredio.vias);
    final verAcopios =
        acopios != null && _visibles.contains(CapaPredio.acopios);

    // Lo que se levanto: la grabacion en curso y los puntos marcados.
    final grabacion = ref.watch(grabadorProvider);
    final puntos = ref.watch(puntosProvider).valueOrNull ?? const <Waypoint>[];

    // Una sola tarjeta abajo a la vez, en este orden de quien manda: medir es
    // un modo y tapa todo; despues la ruta; despues lo que se haya tocado.
    final hayRuta = !_midiendo && (_ruta != null || _calculando);

    // La tarjeta del acopio elegido se muestra mientras no haya ruta: en
    // cuanto se pide la ruta, la tarjeta de la ruta toma su lugar.
    final fichaAcopio = !_midiendo && _acopio != null && _destino == null;
    final fichaPunto = !_midiendo && !hayRuta && !fichaAcopio && _punto != null;
    final fichaTrazado =
        !_midiendo && !hayRuta && !fichaAcopio && !fichaPunto && _visto != null;

    // Cuando hay una tarjeta abajo ocupa lugar: los botones suben para no
    // quedar debajo de ella.
    // Si la ruta que se sigue ya se inicio. Y si se puede iniciar: con otro
    // recorrido grabandose -el viaje de un camion- la ruta es parte de el.
    final enRuta = _esNavegacion(grabacion);
    final conBoton = _ruta != null && (enRuta || grabacion.codigo == null);

    final abajo = _midiendo || fichaPunto
        ? 156.0
        : hayRuta
        ? (conBoton ? 200.0 : 140.0)
        : fichaAcopio
        ? 188.0
        : (fichaTrazado ? 116.0 : 32.0);

    return PopScope(
      // Atras, midiendo, deja de medir: no saca del mapa con media area hecha.
      canPop: !_midiendo,
      onPopInvokedWithResult: (salio, _) {
        if (!salio) _dejarDeMedir();
      },
      child: Scaffold(
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapa,
              options: MapOptions(
                // Guaicaramo, mientras no haya un fix. Abrir en el Atlantico
                // (0,0) haria creer que el GPS fallo.
                initialCenter: aqui ?? const LatLng(4.28, -72.89),
                initialZoom: 17,
                onMapReady: () {
                  _mapaListo = true;
                  _seguir();
                },
                // Mantener pulsado, donde hay vias, traza la ruta hasta ahi: sin
                // el plano del predio no hay por donde trazar nada, y ahi el
                // mismo gesto marca un punto a mano.
                onLongPress: _midiendo
                    ? null
                    : (_, punto) => widget.archivoVias == null
                          ? _marcarEn(punto)
                          : _fijarDestino(punto),
                onTap: (_, punto) => _alTocar(punto, acopios),
                onPositionChanged: (camara, porGesto) {
                  // Esto llega en cada cuadro mientras alguien mueve el mapa.
                  // Arrastrar no cambia nada de lo que se dibuja -el zoom es lo
                  // que decide los rotulos-, asi que reconstruir la pantalla por
                  // cada cuadro de arrastre era trabajo puro sin resultado.
                  final soltoElSeguimiento = porGesto && _siguiendo;
                  if (!soltoElSeguimiento &&
                      (camara.zoom - _zoom).abs() < 0.01) {
                    return;
                  }
                  setState(() {
                    _zoom = camara.zoom;
                    if (soltoElSeguimiento) _modo = _Seguimiento.libre;
                  });
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: _capa.url,
                  userAgentPackageName: _capa.paquete,
                  maxNativeZoom: _capa.zoomMax,
                  // Donde el servidor no tiene imagen del nivel pedido -o no
                  // hay senal y no esta guardada-, muestra la del nivel de
                  // arriba ampliada en vez del cartel o el hueco.
                  tileProvider: proveedorDe(
                    plantilla: _capa.url,
                    paquete: _capa.paquete,
                  ),
                  // Pide tambien el anillo de teselas alrededor de lo que se ve:
                  // con red, eso queda en la cache y el borde del mapa no sale
                  // en blanco despues al moverse sin senal.
                  panBuffer: 1,
                ),

                // Orden de abajo hacia arriba: imagen, lotes, vias, posicion.
                // Los linderos van primero porque son areas; una via encima de
                // un lindero se ve, un lindero encima de una via lo borra.
                // Los planos importados van sobre el satelital y **debajo** de
                // los lotes y las vias: el plano es contexto, y los linderos
                // que la app conoce de verdad no los puede tapar una hoja.
                if (_verPlanos && planos.isNotEmpty) CapaPdf(planos: planos),

                if (verParcelas) CapaParcelas(parcelas: parcelas, zoom: _zoom),

                // Las vias van sobre la imagen y debajo del punto propio: saber
                // donde estoy no lo puede tapar una linea.
                if (verVias) CapaVias(vias: vias),

                if (verParcelas) RotulosBloque(parcelas: parcelas, zoom: _zoom),

                // El recorrido o el area que se esta mirando: debajo de la ruta
                // y de lo que se graba ahora, que son lo vivo.
                if (_visto != null)
                  CapaTrazadoVisto(
                    vertices: _vistoVertices,
                    esArea: _visto!.tipo == TipoTrazado.poligono.name,
                  ),

                // La ruta va sobre las vias y debajo del punto propio.
                if (_ruta != null) CapaRuta(ruta: _ruta!, progreso: _progreso),

                // Por donde se vino, mientras se graba.
                if (grabacion.codigo != null)
                  CapaRecorrido(linea: grabacion.linea),

                // Los acopios van sobre la ruta: la ruta termina en uno, y el
                // acopio tiene que seguir viendose debajo del alfiler.
                if (verAcopios)
                  CapaAcopios(
                    acopios: acopios,
                    zoom: _zoom,
                    seleccionado: _acopio,
                  ),
                if (_destino != null) MarcadorDestino(destino: _destino!),

                if (puntos.isNotEmpty)
                  CapaPuntos(puntos: puntos, seleccionado: _punto),
                if (_midiendo) CapaMedicion(puntos: List.of(_medida)),

                if (aqui != null) ...[
                  // El circulo de precision va SIEMPRE, debajo del punto.
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: aqui,
                        radius: _posicion!.accuracy,
                        useRadiusInMeter: true,
                        color: Colors.blue.withValues(alpha: 0.15),
                        borderColor: Colors.blue.withValues(alpha: 0.4),
                        borderStrokeWidth: 1,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: aqui,
                        // Mas grande que el circulo viejo: la flecha necesita
                        // largo para que la punta se lea como punta.
                        width: 34,
                        height: 34,
                        child: _PuntoPropio(rumbo: _rumbo),
                      ),
                    ],
                  ),
                ],

                // La escala: sobre una imagen satelital no hay nada que diga si
                // ese lote mide cien metros o un kilometro.
                Scalebar(
                  alignment: Alignment.bottomLeft,
                  padding: EdgeInsets.only(left: 14, bottom: abajo + 22),
                  lineColor: Colors.white,
                  strokeWidth: 2.5,
                  textStyle: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                  ),
                ),
              ],
            ),
            _BarraEstado(posicion: _posicion, error: _error),

            // De quien es la imagen. Lo piden los dos servidores para usarla.
            Positioned(
              left: 14,
              bottom: abajo + 2,
              child: IgnorePointer(
                child: Text(
                  _capa.atribucion,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    shadows: [Shadow(blurRadius: 3, color: Colors.black)],
                  ),
                ),
              ),
            ),

            // Lo que va arriba: el viaje del camion si lo abrio el modulo de
            // camiones, y si no, la grabacion en curso.
            Positioned(
              top: MediaQuery.of(context).padding.top + 64,
              left: 12,
              right: 12,
              // Con una ruta iniciada la tarjeta de abajo ya dice que se
              // graba y desde ella se termina: dos franjas dirian lo mismo.
              //
              // La vuelta de un camion lleva siempre su franja, se haya
              // abierto el mapa desde donde se haya abierto: es la unica
              // que sabe si ya se puede finalizar.
              child: grabacion.esVuelta
                  ? const PanelViaje()
                  : widget.panelSuperior ??
                        (enRuta
                            ? const SizedBox.shrink()
                            : const PanelGrabacion()),
            ),

            // La pista de como se pide una ruta, arriba y no abajo: abajo pelea
            // con la leyenda y los botones, y ahi nadie la lee.
            if (widget.archivoVias != null &&
                !_pistaVista &&
                grabacion.codigo == null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 70,
                left: 0,
                right: 0,
                child: Center(child: PistaRuta(conAcopios: acopios != null)),
              ),

            Positioned(
              right: 16,
              bottom: abajo,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'herramientas',
                    onPressed: _abrirHerramientas,
                    tooltip: 'Herramientas',
                    child: const Icon(Icons.construction),
                  ),
                  if (acopios != null) ...[
                    const SizedBox(height: 12),
                    FloatingActionButton.small(
                      heroTag: 'buscar',
                      onPressed: () => _buscarAcopio(acopios),
                      tooltip: 'Buscar un acopio',
                      child: const Icon(Icons.search),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Un solo boton para todas las capas. Un boton por capa ya
                  // eran cinco y tapaban el costado del mapa; con cada capa
                  // nueva iba a ser uno mas.
                  FloatingActionButton.small(
                    heroTag: 'capas',
                    onPressed: () => _abrirCapas(
                      planos: planos.length,
                      parcelas: parcelas,
                      vias: vias,
                      acopios: acopios,
                    ),
                    tooltip: 'Capas',
                    child: const Icon(Icons.layers_outlined),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton(
                    heroTag: 'centrar',
                    onPressed: aqui == null ? null : _alternarSeguimiento,
                    tooltip: switch (_modo) {
                      _Seguimiento.libre => 'Seguir mi posicion',
                      _Seguimiento.rumbo => 'Norte arriba',
                      _Seguimiento.centrado => 'Girar hacia donde voy',
                    },
                    child: Icon(switch (_modo) {
                      _Seguimiento.libre => Icons.location_searching,
                      _Seguimiento.rumbo => Icons.navigation,
                      _Seguimiento.centrado => Icons.my_location,
                    }),
                  ),
                ],
              ),
            ),
            if (_midiendo)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: PanelMedicion(
                    puntos: List.of(_medida),
                    onDeshacer: () => setState(_medida.removeLast),
                    onCerrar: _dejarDeMedir,
                    onGuardar: _guardarArea,
                  ),
                ),
              )
            else if (_ruta != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: PanelRuta(
                    ruta: _ruta!,
                    progreso: _progreso,
                    calculando: _calculando,
                    nombreDestino: _nombreDestino,
                    // Cerrar una ruta iniciada es terminarla: lo grabado no
                    // se tira, y se pregunta por ella igual.
                    onCerrar: enRuta
                        ? () => _terminarRuta(llego: false)
                        : _quitarRuta,
                    onGuardar: _calculando ? null : _guardarRuta,
                    guardada: _rutaGuardada,
                    enRuta: enRuta,
                    onIniciar: grabacion.codigo == null ? _iniciarRuta : null,
                    onTerminar: () => _terminarRuta(llego: false),
                  ),
                ),
              )
            else if (_calculando)
              const Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(child: _CalculandoRuta()),
              )
            else if (fichaAcopio)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: FichaAcopio(
                    acopio: _acopio!,
                    desde: aqui,
                    onIr: () => _irAlAcopio(_acopio!),
                    onCerrar: () => setState(() => _acopio = null),
                  ),
                ),
              )
            else if (fichaPunto)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: FichaPunto(
                    punto: _punto!,
                    desde: aqui,
                    onCerrar: () => setState(() => _punto = null),
                    onBorrar: () => _borrarPunto(_punto!),
                    onIr: widget.archivoVias == null
                        ? null
                        : () => _fijarDestino(
                            LatLng(_punto!.latitud, _punto!.longitud),
                            nombre: _punto!.nombre,
                          ),
                  ),
                ),
              )
            else if (fichaTrazado)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: FichaTrazado(
                    trazado: _visto!,
                    onCerrar: () => setState(() {
                      _visto = null;
                      _vistoVertices = const [];
                    }),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Quien esta conectado y cuanto le queda de sesion.
  ///
  /// Los dias restantes se muestran porque son el dato que decide si alguien
  /// puede salir tranquilo a una semana de campo. Enterarse de que la sesion
  /// vencio estando en el lote es justo lo que hay que evitar.
  void _mostrarCuenta(BuildContext context) {
    final sesion = ref.read(sesionProvider).sesion;
    if (sesion == null) return;

    showModalBottomSheet<void>(
      context: context,
      builder: (hoja) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: sesion.foto != null
                  ? CircleAvatar(backgroundImage: NetworkImage(sesion.foto!))
                  : const CircleAvatar(child: Icon(Icons.person)),
              title: Text(sesion.nombre),
              subtitle: Text(sesion.correo),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text('Sesion valida ${sesion.diasRestantes} dias mas'),
              subtitle: const Text(
                'Podes trabajar sin senal durante ese plazo.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesion'),
              onTap: () {
                Navigator.pop(hoja);
                ref.read(sesionProvider.notifier).salir();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Las dos formas de mirar el terreno.
///
/// No sobra ninguna: el satelite muestra el cultivo, la ronda del cano y donde
/// termina el potrero, lo que un mapa de calles nunca va a mostrar, pero se
/// pierde para ubicarse porque no tiene nombres. Las calles tienen la via y el
/// caserio y no tienen ni un arbol. En campo se alterna entre las dos.
///
/// Ninguna pide llave ni cuenta.
enum CapaBase {
  satelite(
    'Satelite',
    Icons.satellite_alt,
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    // Esri no sirve teselas nativas mas alla de z19 en zona rural. Sin este
    // tope, acercarse mas deja la pantalla en gris en vez de escalar la ultima.
    19,
    'Esri, Maxar, Earthstar Geographics',
  ),
  calles(
    'Calles',
    Icons.map_outlined,
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    19,
    '(c) OpenStreetMap',
  );

  const CapaBase(
    this.titulo,
    this.icono,
    this.url,
    this.zoomMax,
    this.atribucion,
  );

  final String titulo;
  final IconData icono;
  final String url;
  final int zoomMax;

  /// De quien es la imagen. Los dos servidores piden mostrarlo para usarla.
  final String atribucion;

  CapaBase get otra => this == satelite ? calles : satelite;

  /// La regla de uso del servidor publico de OSM pide identificar la app en el
  /// user agent.
  String get paquete => 'com.siriusregenerative.geomaps';
}

/// Donde estoy y, si se sabe, hacia donde voy.
///
/// Dos dibujos y no uno: **flecha** cuando el rumbo es confiable, **circulo**
/// cuando no. El circulo solo dice "estoy aca", y sobre un lote todo igual eso
/// deja a cualquiera sin saber para donde arrancar; la flecha lo resuelve. Pero
/// una flecha apuntando a donde no es, es peor que ninguna: manda a caminar al
/// contrario. Por eso, cuando no se sabe el rumbo, se vuelve al circulo en vez
/// de inventar una direccion.
class _PuntoPropio extends StatelessWidget {
  const _PuntoPropio({this.rumbo});

  /// Grados desde el norte, en sentido horario. Nulo si no es confiable.
  final double? rumbo;

  @override
  Widget build(BuildContext context) {
    if (rumbo == null) {
      return Center(
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
          ),
        ),
      );
    }

    return Transform.rotate(
      angle: rumbo! * math.pi / 180,
      child: CustomPaint(painter: _FlechaPropia()),
    );
  }
}

/// La flecha del punto propio, apuntando al norte del widget; quien la rota es
/// el Transform de arriba.
///
/// No es un triangulo pelado: la base va con una muesca hacia adentro, que es
/// lo que hace que a simple vista se distinga la punta de la cola. Un triangulo
/// isosceles chico, sobre imagen satelital y en movimiento, se lee igual por
/// los dos lados.
class _FlechaPropia extends CustomPainter {
  @override
  void paint(Canvas lienzo, Size tamano) {
    final ancho = tamano.width;
    final alto = tamano.height;

    final figura = ui.Path()
      ..moveTo(ancho / 2, 0)
      ..lineTo(ancho * 0.92, alto)
      ..lineTo(ancho / 2, alto * 0.76)
      ..lineTo(ancho * 0.08, alto)
      ..close();

    // La sombra va primero y aparte: es lo que despega la flecha de una imagen
    // satelital oscura, donde el azul solo se hunde.
    lienzo.drawShadow(figura, Colors.black54, 3, false);
    lienzo.drawPath(figura, Paint()..color = Colors.blue);
    lienzo.drawPath(
      figura,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_FlechaPropia oldDelegate) => false;
}

/// El rumbo del fix, o nulo si no hay que creerle.
///
/// El `heading` del GPS no es una brujula: es la direccion entre los ultimos
/// dos puntos. Quieto, esos dos puntos son ruido, y el valor gira solo. Por eso
/// se exige ir caminando de verdad -1,2 m/s es paso largo- antes de dibujar una
/// direccion. Debajo de eso se devuelve nulo y se pinta el circulo.
double? _rumboConfiable(Position p) {
  if (p.speed < 1.2) return null;
  final rumbo = p.heading;
  if (rumbo.isNaN || rumbo < 0 || rumbo > 360) return null;
  return rumbo;
}

/// Diferencia de b menos a en grados, por el lado corto: de 350 a 10 son 20,
/// no -340. Sin esto el mapa da la vuelta entera al cruzar el norte.
double _diferenciaAngular(double a, double b) {
  final d = (b - a) % 360;
  return d > 180 ? d - 360 : d;
}

/// El punto a [metros] de [desde] en direccion [rumbo]. Plano local: son unos
/// cientos de metros y no hace falta mas.
LatLng _adelantar(LatLng desde, double rumbo, double metros) {
  final r = rumbo * math.pi / 180;
  final dLat = metros * math.cos(r) / 110540.0;
  final dLon =
      metros *
      math.sin(r) /
      (111320.0 * math.cos(desde.latitude * math.pi / 180));
  return LatLng(desde.latitude + dLat, desde.longitude + dLon);
}

/// La barra de arriba. Dice la precision en metros, que es el dato que decide
/// si lo que se esta levantando sirve para un lindero o solo para ubicarse.
class _BarraEstado extends StatelessWidget {
  const _BarraEstado({required this.posicion, required this.error});

  final Position? posicion;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final String texto;
    final Color color;

    if (error != null) {
      texto = error!;
      color = ColoresEstado.mal;
    } else if (posicion == null) {
      // Sin internet no hay GPS asistido y el primer fix tarda: decirlo evita
      // que alguien crea que la app se colgo y la cierre justo antes del fix.
      texto =
          'Buscando senal GPS... Sin internet puede tardar unos minutos; '
          'a cielo abierto es mas rapido.';
      color = ColoresEstado.aviso;
    } else if (Ubicacion.esDeCache(posicion!)) {
      texto =
          'Ultima posicion conocida (${Ubicacion.hace(posicion!)}). '
          'Buscando senal GPS...';
      color = ColoresEstado.aviso;
    } else {
      final p = posicion!;
      texto =
          '${p.latitude.toStringAsFixed(6)}, '
          '${p.longitude.toStringAsFixed(6)}   '
          '+/- ${p.accuracy.toStringAsFixed(0)} m';
      // El umbral no es cosmetico: por encima de 10 m el punto no sirve para
      // marcar un vertice de lindero, y quien lo marca tiene que verlo en el
      // momento, no descubrirlo despues en la oficina.
      color = p.accuracy <= 10 ? ColoresEstado.bien : ColoresEstado.aviso;
    }

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          // Fondo solido y no translucido: la app se usa a pleno sol y un
          // control semitransparente sobre imagen satelital no se ve.
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.gps_fixed, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                texto,
                style: const TextStyle(
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mientras se arma el grafo y se busca el camino.
///
/// La primera ruta de cada sesion tarda unas decimas de segundo -hay que armar
/// el grafo de las vias- y sin este cartel esa demora se lee como que el mapa
/// ignoro el gesto.
class _CalculandoRuta extends StatelessWidget {
  const _CalculandoRuta();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      elevation: 6,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            // Expandido: con la letra agrandada el renglon no entra en una
            // sola linea y sin esto se salia de la tarjeta.
            Expanded(
              child: Text('Trazando la ruta por las vias del predio...'),
            ),
          ],
        ),
      ),
    );
  }
}
