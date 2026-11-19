import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../camiones/panel_viaje.dart' show PanelViaje;
import '../core/acopios.dart';
import '../core/geo.dart';
import '../core/parcelas.dart';
import '../core/ubicacion.dart';
import '../core/vias.dart';
import '../data/db/app_database.dart';
import '../data/db/enums.dart';
import '../state/afinado.dart';
import '../state/captura.dart';
import '../state/fotos.dart';
import '../state/gps.dart';
import '../state/grabacion.dart';
import '../state/proyecto_activo.dart';
import '../state/sesion.dart';
import '../state/sincronizador.dart';
import '../state/zona_guaicaramo.dart';
import 'boton_voz.dart';
import 'calificar_ruta.dart';
import 'capa_acopios.dart';
import 'capa_parcelas.dart';
import 'capa_pdf.dart';
import 'capa_ruta.dart';
import 'capa_vias.dart';
import 'capas_panel.dart';
import 'importar_mapa_page.dart';
import 'mapa/barra_gps.dart';
import 'mapa/botones.dart';
import 'mapa/capa_base.dart';
import 'mapa/cuenta.dart';
import 'mapa/herramientas.dart';
import 'mapa/medido.dart';
import 'mapa/navegacion.dart';
import 'mapa/punto_propio.dart';
import 'mapa/seguidor.dart';
import 'medicion.dart';
import 'panel_grabacion.dart';
import 'proveedor_teselas.dart';
import 'proyectos_page.dart';
import 'rutas_guardadas.dart';
import 'trazado_page.dart';
import 'waypoint_page.dart';

/// La pantalla principal: el mapa.
///
/// Lo unico que no puede faltar nunca en ella es **donde estoy y que tan
/// confiable es ese punto**. El circulo de precision se dibuja siempre, no como
/// opcion: un punto azul sin su radio hace creer que el GPS sabe mas de lo que
/// sabe.
///
/// Aca queda lo que es de la pantalla entera: que capas se dibujan y en que
/// orden, que se toco, y que tarjeta va abajo. Lo demas vive en `mapa/`, cada
/// cosa en su archivo:
///
/// - `seguidor.dart`: la camara que persigue a la posicion, y la brujula.
/// - `navegacion.dart`: la ruta -calcularla, seguirla, decirla, guardarla-.
/// - `herramientas.dart` y `cuenta.dart`: las hojas que suben desde abajo.
/// - `barra_gps.dart`, `botones.dart`, `punto_propio.dart`: lo que se dibuja
///   encima del mapa.
/// - `capa_base.dart`: satelite o calles.
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

class _MapaPageState extends ConsumerState<MapaPage>
    with SingleTickerProviderStateMixin {
  final _mapa = MapController();

  /// La posicion sale del [Gps] compartido, que es quien reintenta, alterna de
  /// proveedor y rearranca al volver a la app.
  StreamSubscription<Position>? _suscripcion;
  Position? _posicion;
  String? _error;

  /// La camara que persigue a la posicion, y la brujula.
  late final SeguidorDeCamara _camara = SeguidorDeCamara(
    vsync: this,
    mapa: _mapa,
    posicion: () => _posicion,
    altoPantalla: () => MediaQuery.sizeOf(context).height,
    alCambiar: (cambio) {
      if (mounted) setState(cambio);
    },
  );

  /// La ruta que se esta mostrando: a donde va, cuanto falta, lo que se dice.
  /// La pantalla se redibuja cada vez que cambia.
  late final NavegacionDelMapa _nav = NavegacionDelMapa(
    leer: ref.read,
    archivoVias: widget.archivoVias,
    posicion: () => _posicion,
    avisar: _avisar,
    alSeguir: () {
      _camara.modo = ModoCamara.rumbo;
      _camara.seguir();
    },
    // Sin la ruta, el acopio al que iba deja de estar elegido.
    alQuitar: () => _acopio = null,
    pedirNombre: (sugerido) => pedirNombreRuta(context, sugerido),
    calificar: ({required llego}) =>
        terminarRutaCalificando(context, ref, llego: llego),
  );

  CapaBase _capa = CapaBase.satelite;

  /// Las capas del predio que se estan dibujando. Todas se pueden apagar:
  /// sobre un lote recien sembrado, las lineas tapan justo lo que se fue a
  /// mirar. Se encienden y apagan desde el panel de capas.
  final Set<CapaPredio> _visibles = {...CapaPredio.values};

  /// Los planos importados se apagan todos juntos desde el mapa. Encender cada
  /// uno por separado es cosa de la pantalla de capas; aca lo que se necesita
  /// es poder ver el terreno limpio de un manotazo.
  bool _verPlanos = true;

  /// El acopio que se toco o se busco, antes de pedir la ruta hasta el.
  Acopio? _acopio;

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

  /// Cuanto ocupa de alto la tarjeta de abajo, la que sea, medida en pantalla.
  /// Los botones, la escala y el credito de la imagen se apoyan arriba de
  /// ella, y su alto depende de la letra del telefono: no se puede adivinar.
  double _altoTarjeta = 0;

  @override
  void initState() {
    super.initState();
    final destino = widget.destinoInicial;
    if (destino != null) {
      // Sin calcular todavia: falta el primer fix. La ruta se traza en cuanto
      // llegue, igual que cuando se marca un punto sin senal.
      _nav.retomar(destino, nombre: widget.nombreDestinoInicial);
      _pistaVista = true;
    } else {
      // Se salio del mapa con una ruta iniciada y se volvio: el recorrido
      // siguio grabando, asi que el mapa retoma hacia donde iba.
      final g = ref.read(grabadorProvider);
      final iba = g.destino;
      if (NavegacionDelMapa.esNavegacion(g) && iba != null) {
        _nav.retomar(
          LatLng(iba.latitud, iba.longitud),
          nombre: g.destinoNombre,
        );
        _pistaVista = true;
      }
    }
    _nav.addListener(_alCambiarLaRuta);
    _suscripcion = Gps.instancia.posiciones.listen(
      _alFix,
      onError: (Object e) {
        if (!mounted || e is! PermisoUbicacionDenegado) return;
        setState(() => _error = e.motivo);
      },
    );
    // Entrar al mapa es la senal mas clara de que se quiere un fix ya: si el
    // flujo quedo mudo, no se espera al vigia. Si todavia esta buscando su
    // primer fix no se lo toca: reabrirlo le hace empezar la busqueda de
    // nuevo, y sin internet esa busqueda son minutos.
    Gps.instancia.despertar();
    _camara.arrancarBrujula();
  }

  @override
  void dispose() {
    _suscripcion?.cancel();
    _nav.dispose();
    _camara.dispose();
    super.dispose();
  }

  void _alCambiarLaRuta() {
    if (mounted) setState(() {});
  }

  /// Una tarjeta de las de abajo, que avisa cuanto mide para que lo demas se
  /// acomode arriba de ella.
  Widget _tarjeta(Widget tarjeta) => Align(
    alignment: Alignment.bottomCenter,
    child: Medido(
      alMedir: (medida) {
        if (!mounted || (medida.height - _altoTarjeta).abs() < 0.5) return;
        setState(() => _altoTarjeta = medida.height);
      },
      child: SafeArea(child: tarjeta),
    ),
  );

  void _alFix(Position p) {
    if (!mounted) return;
    setState(() {
      _posicion = p;
      _error = null;
    });
    _camara.seguir();
    _nav.alFix(p);
  }

  /// Marca un destino en el mapa y traza la ruta por via hasta el.
  ///
  /// El gesto es mantener pulsado y no un toque simple: sobre un mapa, el toque
  /// simple es lo que uno hace sin querer mientras arrastra, y poner un destino
  /// cada vez que alguien roza la pantalla vuelve el mapa inusable.
  void _fijarDestino(LatLng punto, {String? nombre}) {
    // Un punto marcado a mano deja de lado el acopio elegido: la ruta ya no
    // va a el.
    if (nombre == null) _acopio = null;
    _pistaVista = true;
    _nav.fijarDestino(punto, nombre: nombre);
  }

  /// Abre la lista de rutas guardadas y va hacia la que se elija.
  ///
  /// La ruta se vuelve a calcular desde donde se esta ahora: la guardada salio
  /// de otro lugar, y seguirla obligaria a ir primero hasta donde arrancaba.
  Future<void> _abrirRutasGuardadas() async {
    final elegida = await elegirRutaGuardada(context);
    if (elegida == null || !mounted) return;
    if (_nav.destino != null) _nav.quitar();
    _fijarDestino(
      LatLng(elegida.destino.latitud, elegida.destino.longitud),
      nombre: elegida.nombre,
    );
    _nav.marcarGuardada();
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
    if (_nav.destino != null) return;

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
      _camara.modo = ModoCamara.libre;
    });
    if (_camara.listo) {
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
    if (_nav.destino != null) _nav.quitar();
    // Si se busco, es para verlo: se encienden los acopios si estaban
    // apagados, porque si no el resaltado aparece solo, sin sus vecinos.
    _visibles.add(CapaPredio.acopios);
    _mostrarAcopio(elegido);
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
      _camara.modo = ModoCamara.libre;
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
            proyectoCodigo: await ref.read(proyectoParaGuardarProvider.future),
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
    await ref.read(fotosProvider).borrarPunto(w.codigo);
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
      _camara.modo = ModoCamara.libre;
    });
    if (!encuadrar || !_camara.listo || vertices.isEmpty) return;
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
      _camara.modo = ModoCamara.libre;
    });
    if (!_camara.listo) return;
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
    if (_nav.destino != null) _nav.quitar();
    final trazado = elegido.trazado;
    final punto = elegido.punto;
    if (trazado != null) {
      _verTrazado(trazado);
    } else if (punto != null) {
      setState(() {
        _punto = punto;
        _acopio = null;
        _camara.modo = ModoCamara.libre;
      });
      if (_camara.listo) {
        _mapa.move(
          LatLng(punto.latitud, punto.longitud),
          math.max(_mapa.camera.zoom, 17),
        );
      }
    }
  }

  /// El menu de herramientas: la hoja dice que se eligio, y aca se hace.
  Future<void> _abrirHerramientas() async {
    final elegida = await elegirHerramienta(
      context,
      grabacion: ref.read(grabadorProvider),
      proyecto: ref.read(proyectoActivoProvider).valueOrNull,
      conRutasGuardadas: widget.archivoVias != null,
    );
    if (elegida == null || !mounted) return;
    switch (elegida) {
      case HerramientaMapa.proyecto:
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProyectosPage()),
          ),
        );
      case HerramientaMapa.grabarRecorrido:
        unawaited(iniciarRecorrido(context, ref));
      case HerramientaMapa.terminarRecorrido:
        unawaited(terminarRecorrido(context, ref));
      case HerramientaMapa.marcarAqui:
        unawaited(_marcarAqui());
      case HerramientaMapa.medir:
        _empezarAMedir();
      case HerramientaMapa.levantados:
        unawaited(_abrirLevantados());
      case HerramientaMapa.rutasGuardadas:
        unawaited(_abrirRutasGuardadas());
      case HerramientaMapa.cuenta:
        mostrarCuentaDelMapa(context, ref);
    }
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
                if (capa == CapaPredio.acopios &&
                    !ver &&
                    _nav.destino == null) {
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
    final planos = ref.watch(planosEnMapaProvider);

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
    final hayRuta = !_midiendo && (_nav.ruta != null || _nav.calculando);

    // La tarjeta del acopio elegido se muestra mientras no haya ruta: en
    // cuanto se pide la ruta, la tarjeta de la ruta toma su lugar.
    final fichaAcopio = !_midiendo && _acopio != null && _nav.destino == null;
    final fichaPunto = !_midiendo && !hayRuta && !fichaAcopio && _punto != null;
    final fichaTrazado =
        !_midiendo && !hayRuta && !fichaAcopio && !fichaPunto && _visto != null;

    // Cuando hay una tarjeta abajo ocupa lugar: los botones suben para no
    // quedar debajo de ella.
    // Si la ruta que se sigue ya se inicio. Y si se puede iniciar: con otro
    // recorrido grabandose -el viaje de un camion- la ruta es parte de el.
    final enRuta = NavegacionDelMapa.esNavegacion(grabacion);
    final conBoton = _nav.ruta != null && (enRuta || grabacion.codigo == null);

    final hayTarjeta =
        _midiendo || hayRuta || fichaAcopio || fichaPunto || fichaTrazado;
    // Lo que mide cada tarjeta con la letra normal. Es con lo que se dibuja
    // el primer cuadro, antes de saber cuanto mide de verdad.
    final estimado = _midiendo || fichaPunto
        ? 156.0
        : hayRuta
        ? (conBoton ? 200.0 : 140.0)
        : fichaAcopio
        ? 188.0
        : (fichaTrazado ? 116.0 : 32.0);
    // Sin tarjeta no hay medida que valga: la proxima arranca de cero.
    if (!hayTarjeta) _altoTarjeta = 0;
    // Con la letra del telefono agrandada la tarjeta mide bastante mas que el
    // estimado, y los botones quedaban tapados por ella. Manda lo que mide.
    final abajo = hayTarjeta ? math.max(estimado, _altoTarjeta + 8) : estimado;

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
                onMapReady: _camara.mapaListo,
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
                  final soltoElSeguimiento = porGesto && _camara.siguiendo;
                  if (!soltoElSeguimiento &&
                      (camara.zoom - _zoom).abs() < 0.01) {
                    return;
                  }
                  setState(() {
                    _zoom = camara.zoom;
                    if (soltoElSeguimiento) _camara.modo = ModoCamara.libre;
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
                  // Cada imagen puede llegar dos veces -la guardada y la de
                  // la red-: el cambio va sin fundido, o parpadea el mapa.
                  tileDisplay: apareceTesela,
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
                if (_nav.ruta != null)
                  CapaRuta(ruta: _nav.ruta!, progreso: _nav.progreso),

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
                if (_nav.destino != null)
                  MarcadorDestino(destino: _nav.destino!),

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
                        child: PuntoPropio(rumbo: _camara.rumbo),
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
            BarraGps(posicion: _posicion, error: _error),

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
              child: BotonesDelMapa(
                modo: _camara.modo,
                alAbrirHerramientas: _abrirHerramientas,
                alBuscarAcopio: acopios == null
                    ? null
                    : () => _buscarAcopio(acopios),
                alAbrirCapas: () => _abrirCapas(
                  planos: planos.length,
                  parcelas: parcelas,
                  vias: vias,
                  acopios: acopios,
                ),
                alCentrar: aqui == null ? null : _camara.alternar,
              ),
            ),
            if (_midiendo)
              _tarjeta(
                PanelMedicion(
                  puntos: List.of(_medida),
                  onDeshacer: () => setState(_medida.removeLast),
                  onCerrar: _dejarDeMedir,
                  onGuardar: _guardarArea,
                ),
              )
            else if (_nav.ruta != null)
              _tarjeta(
                PanelRuta(
                  ruta: _nav.ruta!,
                  progreso: _nav.progreso,
                  calculando: _nav.calculando,
                  nombreDestino: _nav.nombreDestino,
                  // Cerrar una ruta iniciada es terminarla: lo grabado no
                  // se tira, y se pregunta por ella igual.
                  onCerrar: enRuta
                      ? () => _nav.terminar(llego: false)
                      : _nav.quitar,
                  onGuardar: _nav.calculando ? null : _nav.guardar,
                  guardada: _nav.guardada,
                  enRuta: enRuta,
                  onIniciar: grabacion.codigo == null ? _nav.iniciar : null,
                  onTerminar: () => _nav.terminar(llego: false),
                  botonVoz: const BotonVoz(),
                ),
              )
            else if (_nav.calculando)
              _tarjeta(const CalculandoRuta())
            else if (fichaAcopio)
              _tarjeta(
                FichaAcopio(
                  acopio: _acopio!,
                  desde: aqui,
                  onIr: () => _irAlAcopio(_acopio!),
                  onCerrar: () => setState(() => _acopio = null),
                ),
              )
            else if (fichaPunto)
              _tarjeta(
                FichaPunto(
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
              )
            else if (fichaTrazado)
              _tarjeta(
                FichaTrazado(
                  trazado: _visto!,
                  onCerrar: () => setState(() {
                    _visto = null;
                    _vistoVertices = const [];
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
