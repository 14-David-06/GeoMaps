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

import '../core/ruteo.dart';
import '../core/ubicacion.dart';
import '../state/providers.dart';
import '../state/sesion.dart';
import '../state/zona_guaicaramo.dart';
import 'capa_parcelas.dart';
import 'capa_pdf.dart';
import 'capa_ruta.dart';
import 'capa_vias.dart';
import 'importar_mapa_page.dart';

/// La pantalla principal: el mapa.
///
/// Lo unico que no puede faltar nunca en ella es **donde estoy y que tan
/// confiable es ese punto**. El circulo de precision se dibuja siempre, no como
/// opcion: un punto azul sin su radio hace creer que el GPS sabe mas de lo que
/// sabe.
///
/// Esta es la primera version real. Todavia no lee MBTiles del usuario ni
/// guarda trazados; sirve para responder en el telefono las dos preguntas que
/// deciden todo el proyecto: si `flutter_map` rinde con imagen satelital, y si
/// el GPS entrega precision util bajo condiciones de campo.
class MapaPage extends ConsumerStatefulWidget {
  const MapaPage({this.archivoVias, this.archivoParcelas, super.key});

  /// El asset de vias del predio que se esta abriendo, si es que abre uno.
  /// Nulo es el mapa a secas: satelite o calles y la posicion propia.
  final String? archivoVias;

  /// El asset de lotes del predio (bloques y parcelas), si los tiene.
  final String? archivoParcelas;

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _mapa = MapController();

  StreamSubscription<Position>? _suscripcion;
  StreamSubscription<ServiceStatus>? _servicio;
  StreamSubscription<CompassEvent>? _brujulaSub;
  Position? _posicion;
  String? _error;

  /// Hacia donde mira el telefono segun la brujula, en grados desde el norte.
  double? _brujula;

  /// Que proveedor del GPS se esta usando; ver [Ubicacion.flujo]. Se alterna
  /// si pasa un rato sin ningun fix, en vez de pedirle a la persona que
  /// reinicie la app.
  bool _soloChipGps = false;
  DateTime _inicioFlujo = DateTime.now();
  DateTime? _ultimoFixVivo;
  Timer? _vigia;
  Timer? _reintento;

  /// Cada arranque del GPS se numera. Volver a la app y prender la ubicacion
  /// pueden pedir un arranque a la vez, y sin esto quedaban dos flujos vivos.
  int _arranque = 0;

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

  /// Las vias del predio se pueden apagar. Sobre un lote recien sembrado, las
  /// lineas tapan justo lo que se fue a mirar.
  bool _verVias = true;

  /// Los linderos de los lotes, igual: se apagan para mirar el cultivo limpio.
  bool _verParcelas = true;

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
  Ruta? _ruta;
  ProgresoRuta? _progreso;
  bool _calculando = false;

  /// Para descartar el resultado de un calculo que quedo viejo: si alguien
  /// marca otro destino mientras se arma el grafo, el primero no puede pisar
  /// al segundo al terminar.
  int _calculo = 0;

  /// La pista de "manten pulsado" se muestra hasta que se usa una vez.
  bool _pistaVista = false;

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
    WidgetsBinding.instance.addObserver(this);
    _arrancarGps();
    _arrancarBrujula();

    // Si alguien apaga y prende la ubicacion con el mapa abierto, el flujo
    // muere con el apagado y no vuelve solo.
    try {
      _servicio = Geolocator.getServiceStatusStream().listen((estado) {
        if (estado == ServiceStatus.enabled) _arrancarGps();
      });
    } catch (_) {}

    _vigia = Timer.periodic(const Duration(seconds: 15), (_) => _vigilar());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _suscripcion?.cancel();
    _servicio?.cancel();
    _brujulaSub?.cancel();
    _vigia?.cancel();
    _reintento?.cancel();
    _camara.dispose();
    super.dispose();
  }

  /// Al volver a la app -de otra app, o con la pantalla apagada- el flujo
  /// puede haber quedado sin entregar nada. Se vuelve a pedir: es barato y es
  /// lo que antes obligaba a cerrar y abrir la app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado == AppLifecycleState.resumed) _arrancarGps();
  }

  Future<void> _arrancarGps() async {
    _reintento?.cancel();
    final mio = ++_arranque;
    final permiso = await Ubicacion.pedirPermisos();
    if (!mounted || mio != _arranque) return;
    if (!permiso.concedido) {
      await _suscripcion?.cancel();
      _suscripcion = null;
      if (mounted) setState(() => _error = permiso.motivo);
      return;
    }
    if (_error != null) setState(() => _error = null);

    final anterior = _suscripcion;
    _suscripcion = null;
    await anterior?.cancel();
    if (!mounted || mio != _arranque) return;
    _inicioFlujo = DateTime.now();
    // Distancia minima 0: en el mapa se quiere un fix por segundo aun quieto,
    // para que la precision en pantalla sea la de ahora y para que el vigia
    // sepa distinguir "parado" de "el GPS no entrega".
    _suscripcion =
        Ubicacion.flujo(distanciaMinimaM: 0, soloChipGps: _soloChipGps).listen(
          _alFix,
          onError: (Object e) {
            if (!mounted) return;
            if (e is LocationServiceDisabledException) {
              setState(
                () => _error =
                    'La ubicacion del telefono esta apagada. Activala para ver '
                    'donde estas.',
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
    _reintento = Timer(const Duration(seconds: 3), () {
      if (mounted) _arrancarGps();
    });
  }

  /// Si el proveedor actual lleva un rato sin dar ni un fix, se prueba el otro.
  void _vigilar() {
    if (!mounted || _error != null) return;
    final ultimo = _ultimoFixVivo;
    final desde = ultimo == null || ultimo.isBefore(_inicioFlujo)
        ? _inicioFlujo
        : ultimo;
    if (DateTime.now().difference(desde) > const Duration(seconds: 40)) {
      _soloChipGps = !_soloChipGps;
      _arrancarGps();
    }
  }

  void _alFix(Position p) {
    if (!mounted) return;
    final deCache = Ubicacion.esDeCache(p);
    // Al reabrir el flujo vuelve a llegar la ultima conocida. Si ya hay una
    // posicion mas nueva, esa vieja no la puede pisar.
    final actual = _posicion;
    if (deCache && actual != null && !p.timestamp.isAfter(actual.timestamp)) {
      return;
    }
    if (!deCache) _ultimoFixVivo = DateTime.now();
    setState(() => _posicion = p);
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
  void _fijarDestino(LatLng punto) {
    setState(() {
      _destino = punto;
      _ruta = null;
      _progreso = null;
      _pistaVista = true;
    });
    _calcularRuta(porDesvio: false);
  }

  void _quitarRuta() {
    setState(() {
      _destino = null;
      _ruta = null;
      _progreso = null;
      _calculando = false;
      _calculo++;
    });
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
      _quitarRuta();
      _avisar('Llegaste al punto marcado.');
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

    // Cuando hay ruta, la tarjeta de abajo ocupa lugar: la leyenda y los
    // botones suben para no quedar debajo de ella.
    final hayPanel = _ruta != null || _calculando;
    final abajo = hayPanel ? 116.0 : 32.0;

    return Scaffold(
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
              // El ruteo solo existe donde hay vias cargadas: sin el plano
              // del predio no hay por donde trazar nada.
              onLongPress: widget.archivoVias == null
                  ? null
                  : (_, punto) => _fijarDestino(punto),
              onPositionChanged: (camara, porGesto) {
                // Esto llega en cada cuadro mientras alguien mueve el mapa.
                // Arrastrar no cambia nada de lo que se dibuja -el zoom es lo
                // que decide los rotulos-, asi que reconstruir la pantalla por
                // cada cuadro de arrastre era trabajo puro sin resultado.
                final soltoElSeguimiento = porGesto && _siguiendo;
                if (!soltoElSeguimiento && (camara.zoom - _zoom).abs() < 0.01) {
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

              if (parcelas != null && _verParcelas)
                CapaParcelas(parcelas: parcelas, zoom: _zoom),

              // Las vias van sobre la imagen y debajo del punto propio: saber
              // donde estoy no lo puede tapar una linea.
              if (vias != null && _verVias) CapaVias(vias: vias),

              if (parcelas != null && _verParcelas)
                RotulosBloque(parcelas: parcelas, zoom: _zoom),

              // La ruta va sobre las vias y debajo del punto propio.
              if (_ruta != null) CapaRuta(ruta: _ruta!, progreso: _progreso),
              if (_destino != null) MarcadorDestino(destino: _destino!),

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
            ],
          ),
          _BarraEstado(posicion: _posicion, error: _error),
          if (vias != null && _verVias)
            Positioned(left: 16, bottom: abajo, child: const LeyendaVias()),

          // La pista de como se pide una ruta, arriba y no abajo: abajo pelea
          // con la leyenda y los botones, y ahi nadie la lee.
          if (widget.archivoVias != null && !_pistaVista)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 0,
              right: 0,
              child: const Center(child: PistaRuta()),
            ),

          Positioned(
            right: 16,
            bottom: abajo,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'cuenta',
                  onPressed: () => _mostrarCuenta(context),
                  tooltip: 'Mi cuenta',
                  child: const Icon(Icons.account_circle_outlined),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.small(
                  heroTag: 'capas',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ImportarMapaPage(),
                    ),
                  ),
                  tooltip: 'Capas y planos',
                  child: const Icon(Icons.layers_outlined),
                ),
                if (planos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  FloatingActionButton.small(
                    heroTag: 'planos',
                    onPressed: () => setState(() => _verPlanos = !_verPlanos),
                    tooltip: _verPlanos
                        ? 'Ocultar los planos'
                        : 'Ver los planos (${planos.length})',
                    child: Icon(_verPlanos ? Icons.map : Icons.map_outlined),
                  ),
                ],
                if (parcelas != null) ...[
                  const SizedBox(height: 12),
                  FloatingActionButton.small(
                    heroTag: 'parcelas',
                    onPressed: () =>
                        setState(() => _verParcelas = !_verParcelas),
                    tooltip: _verParcelas
                        ? 'Ocultar los lotes'
                        : 'Ver los lotes (${parcelas.parcelas.length})',
                    child: Icon(_verParcelas ? Icons.grid_on : Icons.grid_off),
                  ),
                ],
                if (vias != null) ...[
                  const SizedBox(height: 12),
                  FloatingActionButton.small(
                    heroTag: 'vias',
                    onPressed: () => setState(() => _verVias = !_verVias),
                    tooltip: _verVias
                        ? 'Ocultar las vias del predio'
                        : 'Ver las vias del predio (${vias.cuantas})',
                    child: Icon(_verVias ? Icons.route : Icons.route_outlined),
                  ),
                ],
                const SizedBox(height: 12),
                FloatingActionButton.small(
                  heroTag: 'capa',
                  onPressed: () => setState(() => _capa = _capa.otra),
                  tooltip: _capa.otra.titulo,
                  child: Icon(_capa.otra.icono),
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
          if (_ruta != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: PanelRuta(
                  ruta: _ruta!,
                  progreso: _progreso,
                  calculando: _calculando,
                  onCerrar: _quitarRuta,
                ),
              ),
            )
          else if (_calculando)
            const Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(child: _CalculandoRuta()),
            ),
        ],
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
  ),
  calles(
    'Calles',
    Icons.map_outlined,
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    19,
  );

  const CapaBase(this.titulo, this.icono, this.url, this.zoomMax);

  final String titulo;
  final IconData icono;
  final String url;
  final int zoomMax;

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
      color = Colors.red.shade700;
    } else if (posicion == null) {
      // Sin internet no hay GPS asistido y el primer fix tarda: decirlo evita
      // que alguien crea que la app se colgo y la cierre justo antes del fix.
      texto =
          'Buscando senal GPS... Sin internet puede tardar unos minutos; '
          'a cielo abierto es mas rapido.';
      color = Colors.orange.shade800;
    } else if (Ubicacion.esDeCache(posicion!)) {
      texto =
          'Ultima posicion conocida (${Ubicacion.hace(posicion!)}). '
          'Buscando senal GPS...';
      color = Colors.orange.shade800;
    } else {
      final p = posicion!;
      texto =
          '${p.latitude.toStringAsFixed(6)}, '
          '${p.longitude.toStringAsFixed(6)}   '
          '+/- ${p.accuracy.toStringAsFixed(0)} m';
      // El umbral no es cosmetico: por encima de 10 m el punto no sirve para
      // marcar un vertice de lindero, y quien lo marca tiene que verlo en el
      // momento, no descubrirlo despues en la oficina.
      color = p.accuracy <= 10 ? Colors.green.shade800 : Colors.orange.shade800;
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
            const Icon(Icons.gps_fixed, color: Colors.white, size: 18),
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
            Text('Trazando la ruta por las vias del predio...'),
          ],
        ),
      ),
    );
  }
}
