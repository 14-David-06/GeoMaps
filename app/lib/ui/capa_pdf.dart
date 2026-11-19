import 'dart:io';
// Con prefijo: flutter_map exporta su propio Path<LatLng> y tapa el de dibujo.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/detalle_plano.dart';

/// Un plano de topografia importado, dibujado encima del mapa.
///
/// ## Por que va con las cuatro esquinas y no con un rectangulo
///
/// Un plano de topografia esta dibujado en el sistema de coordenadas del pais
/// -aca MAGNA-SIRGAS- y el mapa esta en Web Mercator. Entre los dos hay un
/// giro de unos grados. Encajarlo en el rectangulo que lo contiene lo estira
/// hasta cuadrarlo, y ahi los linderos dejan de coincidir con el terreno: son
/// decenas de metros, justo del orden de lo que alguien esta tratando de
/// ubicar. `RotatedOverlayImage` toma tres esquinas y respeta el giro.
///
/// ## Donde va en la pila
///
/// Encima de la imagen satelital y **debajo** de los lotes, las vias y el punto
/// propio. El plano es contexto; saber donde estoy no lo puede tapar una hoja
/// escaneada.
///
/// ## Las hojas grandes
///
/// Un plano con detalle ([DetallePlano]) se dibuja de dos maneras segun que
/// tan cerca se lo mire: alejado, su imagen entera, como cualquier otro; de
/// cerca, los cuadros de detalle que caen en la pantalla ([PlanoConDetalle]).
class CapaPdf extends StatelessWidget {
  const CapaPdf({required this.planos, super.key});

  /// Los planos encendidos, del mas abajo al mas arriba.
  final List<PlanoEnMapa> planos;

  @override
  Widget build(BuildContext context) {
    if (planos.isEmpty) return const SizedBox.shrink();

    // Sin ninguna hoja grande es la capa de siempre, tal cual.
    if (planos.every((p) => p.detalle == null)) {
      return OverlayImageLayer(
        overlayImages: [for (final p in planos) imagenDe(p)],
      );
    }

    // Lo mismo que arma `OverlayImageLayer`, pero pudiendo poner, donde va la
    // imagen de un plano, la imagen y sus cuadros.
    return MobileLayerTransformer(
      child: ClipRect(
        child: Stack(
          children: [
            for (final p in planos)
              p.detalle == null
                  ? imagenDe(p)
                  : PlanoConDetalle(key: ValueKey(p.codigo), plano: p),
          ],
        ),
      ),
    );
  }

  /// La imagen entera de un plano, apoyada en sus esquinas.
  static RotatedOverlayImage imagenDe(PlanoEnMapa p) => _apoyada(
    FileImage(File(p.ruta)),
    p.esquinas,
    p.opacidad,
    sinHueco: false,
  );

  static RotatedOverlayImage _apoyada(
    ImageProvider imagen,
    List<LatLng> esquinas,
    double opacidad, {
    required bool sinHueco,
  }) => RotatedOverlayImage(
    imageProvider: imagen,
    topLeftCorner: esquinas[0],
    bottomLeftCorner: esquinas[3],
    bottomRightCorner: esquinas[2],
    opacity: opacidad,
    gaplessPlayback: sinHueco,
    // El plano se ve casi siempre agrandado -se rasterizo una vez y
    // despues alguien se acerca-. Con filtrado bajo, las lineas del
    // lindero se ven dentadas justo cuando se las esta mirando de
    // cerca; `medium` las deja limpias sin el costo de `high`.
    filterQuality: FilterQuality.medium,
    // Sin filtro en la **transformacion**, que no es lo mismo que el
    // de arriba. Con filtro, Flutter dibuja la imagen en una capa
    // aparte y recien despues la gira; esa capa se recorta a lo que
    // entra en la pantalla *antes* de girar, asi que en un plano de
    // hoja acostada -girado 90 grados- lo que se guarda es otro
    // pedazo de la imagen y al acercarse el plano desaparece. Visto
    // en el telefono con un PDF de pagina girada. Sin filtro el giro
    // se aplica al dibujar, y la imagen igual se suaviza con el
    // filtro de arriba.
    transformFilterQuality: null,
  );
}

/// Un plano grande: su imagen entera, y de cerca sus cuadros de detalle.
///
/// ## Como se decide que poner
///
/// Mientras la imagen entera alcanza -cada pixel suyo ocupa menos de
/// [aumentoParaDetalle] pixeles de la pantalla- se pone ella sola, igual que
/// en cualquier plano. Mas cerca que eso se ve borrosa, y ahi entran los
/// cuadros que caen en la pantalla.
///
/// ## Por que la imagen entera se recorta
///
/// Los cuadros no se ponen *encima* de la imagen entera: en un plano sin
/// papel, la imagen borrosa asomaria como un halo alrededor de cada linea
/// nitida. Donde ya hay un cuadro dibujado, la imagen entera se recorta; donde
/// todavia no -porque se esta abriendo, o porque ese cuadro no se hizo- queda
/// ella. Asi nunca hay un hueco ni un doble.
class PlanoConDetalle extends StatefulWidget {
  const PlanoConDetalle({required this.plano, super.key});

  final PlanoEnMapa plano;

  /// Cuanto tiene que estar agrandada la imagen entera para pasar a los
  /// cuadros. No es 1: un poco agrandada todavia se lee bien, y cuanto mas
  /// tarde se pasa, menos cuadros hacen falta para cubrir la pantalla.
  static const aumentoParaDetalle = 1.5;

  /// Mas cuadros que estos a la vez no se abren: cada uno son 4 MB en la
  /// memoria. En una pantalla enorme se sigue con la imagen entera hasta
  /// acercarse un poco mas.
  static const maximoALaVez = 16;

  @override
  State<PlanoConDetalle> createState() => _PlanoConDetalleState();
}

class _PlanoConDetalleState extends State<PlanoConDetalle> {
  /// Los cuadros que ya se abrieron y se pueden dibujar en el acto.
  final _abiertos = <int>{};

  /// Los que no se pudieron abrir: ahi queda la imagen entera.
  final _rotos = <int>{};

  /// Las imagenes de los cuadros que estan a la vista, abiertas o abriendose.
  ///
  /// Se las tiene agarradas mientras el cuadro este en la pantalla. Abrirlas
  /// y soltarlas dejaria que el telefono, justo de memoria, las tirara antes
  /// de que el mapa llegue a dibujarlas: ahi quedaria un hueco en el plano,
  /// con la imagen entera ya recortada y el cuadro todavia sin volver.
  final _agarradas = <int, (ImageStream, ImageStreamListener)>{};

  @override
  void didUpdateWidget(PlanoConDetalle anterior) {
    super.didUpdateWidget(anterior);
    // Otra version del plano -con papel o sin el- son otros archivos.
    if (anterior.plano.ruta != widget.plano.ruta) _soltarTodo();
  }

  @override
  void dispose() {
    _soltarTodo();
    super.dispose();
  }

  void _soltarTodo() {
    for (final (flujo, oyente) in _agarradas.values) {
      flujo.removeListener(oyente);
    }
    _agarradas.clear();
    _abiertos.clear();
    _rotos.clear();
  }

  void _soltar(int i) {
    final agarrada = _agarradas.remove(i);
    agarrada?.$1.removeListener(agarrada.$2);
    _abiertos.remove(i);
    _rotos.remove(i);
  }

  ImageProvider _imagenDe(int i) =>
      FileImage(File(widget.plano.detalle!.archivoDe(widget.plano.ruta, i)));

  /// Empieza a abrir el cuadro [i]. Se llama mientras se arma la pantalla.
  void _abrir(int i) {
    final flujo = _imagenDe(i).resolve(createLocalImageConfiguration(context));

    void anotar(Set<int> donde, {required bool enElActo}) {
      // Puede haberse soltado mientras se abria: salio de la pantalla.
      if (!mounted || _agarradas[i]?.$1 != flujo) return;
      // Si ya estaba abierta contesta en el acto, en medio del armado de la
      // pantalla: ahi no se puede pedir otro armado, ni hace falta.
      if (enElActo) {
        donde.add(i);
      } else {
        setState(() => donde.add(i));
      }
    }

    // Lo que conteste mientras se lo esta agregando, contesta en el acto.
    var agregando = true;
    final oyente = ImageStreamListener((imagen, _) {
      // Aca no se usan los pixeles: lo que la mantiene es seguir escuchando.
      imagen.dispose();
      anotar(_abiertos, enElActo: agregando);
    }, onError: (_, _) => anotar(_rotos, enElActo: agregando));
    _agarradas[i] = (flujo, oyente);
    flujo.addListener(oyente);
    agregando = false;
  }

  @override
  Widget build(BuildContext context) {
    final plano = widget.plano;
    final detalle = plano.detalle!;
    final camara = MapCamera.of(context);
    final entera = CapaPdf.imagenDe(plano);

    Offset enCapa(LatLng p) => camara.projectAtZoom(p) - camara.pixelOrigin;

    // La imagen entera en la pantalla: una esquina y dos lados.
    final arriba = enCapa(plano.esquinas[0]);
    final abajo = enCapa(plano.esquinas[3]);
    final ancho = enCapa(plano.esquinas[2]) - abajo;
    final alto = abajo - arriba;

    final aLaVista = cuadrosALaVista(
      detalle,
      arriba: arriba,
      ancho: ancho,
      alto: alto,
      pantalla: camara.size,
      puntosPorPixel: MediaQuery.devicePixelRatioOf(context),
    );

    // Lo que salio de la pantalla se suelta: cuando vuelva se abre de nuevo,
    // y mientras tanto no ocupa memoria.
    for (final i in _agarradas.keys.toList()) {
      if (!aLaVista.contains(i)) _soltar(i);
    }
    for (final i in aLaVista) {
      if (!_agarradas.containsKey(i)) _abrir(i);
    }
    final dibujados = [
      for (final i in aLaVista)
        if (_abiertos.contains(i)) i,
    ];

    if (dibujados.isEmpty) {
      return Positioned.fill(child: Stack(children: [entera]));
    }

    return Positioned.fill(
      child: Stack(
        children: [
          ClipPath(
            clipper: _SinLoDibujado([
              for (final i in dibujados)
                _hueco(detalle, i, arriba: arriba, ancho: ancho, alto: alto),
            ]),
            child: Stack(children: [entera]),
          ),
          for (final i in dibujados)
            CapaPdf._apoyada(
              _imagenDe(i),
              _esquinasDe(detalle, i),
              plano.opacidad,
              sinHueco: true,
            ),
        ],
      ),
    );
  }

  List<LatLng> _esquinasDe(DetallePlano detalle, int i) {
    final p = detalle.parte(i);
    return esquinasDeParte(
      widget.plano.esquinas,
      x0: p.x0,
      y0: p.y0,
      x1: p.x1,
      y1: p.y1,
    );
  }

  /// Donde se recorta la imagen entera para dejarle lugar al cuadro [i].
  ///
  /// Medio pixel mas adentro que el cuadro: asi la imagen entera llega hasta
  /// debajo de su borde y no queda una raya por donde se vea el mapa.
  static List<Offset> _hueco(
    DetallePlano detalle,
    int i, {
    required Offset arriba,
    required Offset ancho,
    required Offset alto,
  }) {
    final p = detalle.parte(i, montado: false);
    Offset en(double s, double t) => arriba + ancho * s + alto * t;
    final esquinas = [
      en(p.x0, p.y0),
      en(p.x1, p.y0),
      en(p.x1, p.y1),
      en(p.x0, p.y1),
    ];
    final centro = (esquinas[0] + esquinas[2]) / 2;
    return [
      for (final e in esquinas)
        if ((e - centro).distance <= 1)
          centro
        else
          e - (e - centro) / (e - centro).distance * 0.5,
    ];
  }
}

/// Los cuadros de detalle que hay que poner para lo que se esta viendo, o
/// ninguno si con la imagen entera alcanza.
///
/// [arriba] es donde cae en la pantalla la esquina de arriba-izquierda de la
/// imagen entera, y [ancho] y [alto] sus dos lados. [pantalla] es el tamano de
/// lo que se ve y [puntosPorPixel] cuantos pixeles de verdad tiene cada punto
/// de la pantalla.
@visibleForTesting
List<int> cuadrosALaVista(
  DetallePlano detalle, {
  required Offset arriba,
  required Offset ancho,
  required Offset alto,
  required Size pantalla,
  required double puntosPorPixel,
}) {
  // Cuantos pixeles de la pantalla ocupa cada pixel de la imagen entera.
  final aumento = ancho.distance * puntosPorPixel / detalle.anchoVista;
  if (aumento < PlanoConDetalle.aumentoParaDetalle) return const [];

  // Las esquinas de la pantalla, llevadas a partes de la hoja.
  final area = ancho.dx * alto.dy - ancho.dy * alto.dx;
  if (area.abs() < 1e-9) return const [];
  var x0 = double.infinity;
  var y0 = double.infinity;
  var x1 = double.negativeInfinity;
  var y1 = double.negativeInfinity;
  for (final esquina in [
    Offset.zero,
    Offset(pantalla.width, 0),
    Offset(pantalla.width, pantalla.height),
    Offset(0, pantalla.height),
  ]) {
    final d = esquina - arriba;
    final s = (d.dx * alto.dy - d.dy * alto.dx) / area;
    final t = (ancho.dx * d.dy - ancho.dy * d.dx) / area;
    if (s < x0) x0 = s;
    if (s > x1) x1 = s;
    if (t < y0) y0 = t;
    if (t > y1) y1 = t;
  }

  final cuadros = [
    for (final i in detalle.cuadrosEn(x0: x0, y0: y0, x1: x1, y1: y1))
      if (detalle.listos.contains(i)) i,
  ];
  return cuadros.length > PlanoConDetalle.maximoALaVez ? const [] : cuadros;
}

/// Recorta todo menos los cuadros que ya estan dibujados.
class _SinLoDibujado extends CustomClipper<ui.Path> {
  const _SinLoDibujado(this.huecos);

  final List<List<Offset>> huecos;

  @override
  ui.Path getClip(Size size) {
    final camino = ui.Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    for (final hueco in huecos) {
      camino.addPolygon(hueco, true);
    }
    return camino;
  }

  // Los huecos cambian con cada movimiento del mapa.
  @override
  bool shouldReclip(_SinLoDibujado anterior) => true;
}

/// Lo que la capa necesita saber de un plano para dibujarlo.
///
/// Es una vista de la fila de `Mapas`, no la fila entera: la capa no tiene por
/// que saber de llaves de S3 ni de estados de descarga.
class PlanoEnMapa {
  const PlanoEnMapa({
    required this.codigo,
    required this.nombre,
    required this.ruta,
    required this.esquinas,
    required this.opacidad,
    this.detalle,
  });

  final String codigo;
  final String nombre;

  /// El PNG en el telefono.
  final String ruta;

  /// Noroeste, noreste, sureste, suroeste.
  final List<LatLng> esquinas;

  final double opacidad;

  /// Los cuadros de detalle, si es una hoja grande. Nulo en un plano comun.
  final DetallePlano? detalle;

  LatLng get noroeste => esquinas[0];
  LatLng get sureste => esquinas[2];
  LatLng get suroeste => esquinas[3];

  PlanoEnMapa conDetalle(DetallePlano? nuevo) => PlanoEnMapa(
    codigo: codigo,
    nombre: nombre,
    ruta: ruta,
    esquinas: esquinas,
    opacidad: opacidad,
    detalle: nuevo,
  );
}
