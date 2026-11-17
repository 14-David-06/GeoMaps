import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/acopios.dart';
import 'capa_ruta.dart' show formatearDistancia;

/// El color de los acopios. Naranja porque es lo unico de ese color en el
/// mapa: blanco es pavimento, tierra es balastrada, azul es la ruta y el punto
/// propio. Un acopio tiene que encontrarse de un vistazo entre todo eso.
const colorAcopio = Color(0xFFFF6D00);

/// Los acopios del predio dibujados sobre el mapa.
///
/// Son cientos, y como los rotulos de los lotes, lo que se dibuja depende del
/// zoom:
///
/// - **de lejos** (z < [zoomMinimo]): nada. Cientos de puntos sobre un predio
///   que entra entero en la pantalla son una mancha naranja, no informacion.
/// - **de medio** : un punto por acopio.
/// - **de cerca** (z >= [zoomNumero]): el punto y su numero.
///
/// Los puntos se tocan para elegirlos, pero quien resuelve el toque es la
/// pantalla del mapa ([acopioCercano]) y no cada punto: un `GestureDetector`
/// por acopio son cientos de widgets mas, y un punto de 10 px es mas chico que
/// un dedo. Buscando el mas cercano al toque, se acierta aunque el dedo caiga
/// al lado.
class CapaAcopios extends StatefulWidget {
  const CapaAcopios({
    required this.acopios,
    required this.zoom,
    this.seleccionado,
    super.key,
  });

  final AcopiosPredio acopios;
  final double zoom;

  /// El que se toco o se busco. Se resalta para que se vea cual es.
  final Acopio? seleccionado;

  static const zoomMinimo = 13.0;
  static const zoomNumero = 16.0;

  @override
  State<CapaAcopios> createState() => _CapaAcopiosState();
}

class _CapaAcopiosState extends State<CapaAcopios> {
  // Los puntos y los rotulos se arman una vez y se guardan, por lo mismo que
  // las vias y los lotes: la pantalla se reconstruye en cada cuadro de zoom y
  // armar cientos de marcadores cada vez es trabajo tirado.
  late bool _grandes = _sonGrandes(widget.zoom);
  late List<CircleMarker> _puntos = _armarPuntos(widget.acopios, _grandes);
  late final List<Marker> _numeros = _armarNumeros(widget.acopios);

  static bool _sonGrandes(double zoom) => zoom >= 15;

  @override
  void didUpdateWidget(CapaAcopios anterior) {
    super.didUpdateWidget(anterior);
    final grandes = _sonGrandes(widget.zoom);
    if (grandes != _grandes || !identical(anterior.acopios, widget.acopios)) {
      _grandes = grandes;
      _puntos = _armarPuntos(widget.acopios, grandes);
    }
  }

  static List<CircleMarker> _armarPuntos(AcopiosPredio acopios, bool grandes) {
    return [
      for (final a in acopios.acopios)
        CircleMarker(
          point: a.punto,
          radius: grandes ? 6 : 4,
          color: colorAcopio,
          // El borde blanco lo despega de la palma oscura y del suelo.
          borderColor: Colors.white,
          borderStrokeWidth: grandes ? 2 : 1.2,
        ),
    ];
  }

  static List<Marker> _armarNumeros(AcopiosPredio acopios) {
    return [
      for (final a in acopios.acopios)
        if (a.numero.isNotEmpty)
          Marker(
            point: a.punto,
            width: 58,
            height: 24,
            // A la derecha del punto y no encima: encima lo tapa.
            alignment: const Alignment(1.2, 0),
            child: _Numero(texto: a.numero),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.zoom < CapaAcopios.zoomMinimo) {
      // El elegido se sigue viendo aunque se aleje el mapa: se busco para
      // encontrarlo, y alejarse para ver por donde se llega no puede borrarlo.
      final s = widget.seleccionado;
      return s == null ? const SizedBox.shrink() : _Resaltado(acopio: s);
    }

    return Stack(
      children: [
        CircleLayer(circles: _puntos),
        if (widget.zoom >= CapaAcopios.zoomNumero)
          MarkerLayer(markers: _numeros),
        if (widget.seleccionado != null)
          _Resaltado(acopio: widget.seleccionado!),
      ],
    );
  }
}

class _Resaltado extends StatelessWidget {
  const _Resaltado({required this.acopio});

  final Acopio acopio;

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: [
        Marker(
          point: acopio.punto,
          width: 30,
          height: 30,
          child: Container(
            decoration: BoxDecoration(
              color: colorAcopio,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(blurRadius: 6, color: Colors.black54),
              ],
            ),
            child: const Icon(Icons.inventory_2, color: Colors.white, size: 15),
          ),
        ),
      ],
    );
  }
}

class _Numero extends StatelessWidget {
  const _Numero({required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        texto,
        maxLines: 1,
        softWrap: false,
        style: const TextStyle(
          color: Colors.white,
          // Grande y bien contorneado: el numero es lo que se viene a leer,
          // y quien maneja lo lee de reojo, a pleno sol.
          fontSize: 15,
          fontWeight: FontWeight.w900,
          shadows: [
            Shadow(blurRadius: 2, color: Colors.black),
            Shadow(blurRadius: 4, color: Colors.black),
            Shadow(blurRadius: 8, color: Colors.black87),
          ],
        ),
      ),
    );
  }
}

/// El acopio mas cercano a un toque en la pantalla, si hay uno a distancia de
/// dedo.
///
/// Se mide en pixeles y no en metros: lo que importa es si el dedo cayo sobre
/// el punto **tal como se ve**, y eso depende del zoom.
Acopio? acopioCercano({
  required AcopiosPredio acopios,
  required MapCamera camara,
  required Offset toque,
  double radioPx = 30,
}) {
  Acopio? mejor;
  var mejorD2 = radioPx * radioPx;
  for (final a in acopios.acopios) {
    final d = camara.latLngToScreenOffset(a.punto) - toque;
    final d2 = d.dx * d.dx + d.dy * d.dy;
    if (d2 < mejorD2) {
      mejorD2 = d2;
      mejor = a;
    }
  }
  return mejor;
}

/// El numero del acopio en un recuadro naranja: es lo que se busca con el ojo,
/// en la lista y en la tarjeta.
class _CajaNumero extends StatelessWidget {
  const _CajaNumero({required this.numero, this.lado = 72});

  final String numero;
  final double lado;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: lado,
      height: lado,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: colorAcopio,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      // El numero se achica solo si no entra ("30A"), en vez de cortarse.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          numero.isEmpty ? '?' : numero,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// La tarjeta del acopio elegido, abajo: cual es y el boton para ir.
///
/// Elegir un acopio no traza la ruta de una: un toque de mas sobre el mapa,
/// con una ruta ya en curso, no puede cambiar a donde va alguien que esta
/// manejando. Se elige, se confirma con "Como llegar", y recien ahi se rutea.
///
/// Todo va en letra grande, y el bloque y la parcela escritos enteros: quien
/// la lee la mayoria de las veces tiene mas de cincuenta anos y la esta
/// mirando al sol.
class FichaAcopio extends StatelessWidget {
  const FichaAcopio({
    required this.acopio,
    required this.desde,
    required this.onIr,
    required this.onCerrar,
    super.key,
  });

  final Acopio acopio;

  /// La posicion propia, para decir a cuanto queda en linea recta.
  final LatLng? desde;

  final VoidCallback onIr;
  final VoidCallback onCerrar;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final d = desde;
    final lejos = d == null
        ? null
        : const Distance().as(LengthUnit.Meter, d, acopio.punto);
    final lugar = acopio.lugar;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      color: colores.surface,
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _CajaNumero(numero: acopio.numero, lado: 64),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        lugar.isEmpty ? acopio.nombre : lugar,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                      if (lejos != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'A ${formatearDistancia(lejos)} en linea recta',
                          style: TextStyle(
                            fontSize: 16,
                            color: colores.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onCerrar,
                  iconSize: 28,
                  icon: const Icon(Icons.close),
                  tooltip: 'Cerrar',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: onIr,
                  icon: const Icon(Icons.directions, size: 24),
                  label: const Text(
                    'Como llegar',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Buscar un acopio por su numero y elegir de que bloque.
///
/// Un numero solo no identifica a un acopio: hay un 38 en seis lotes. Por eso
/// buscar son dos pasos, y los dos se ven a la vez:
///
/// 1. se escribe el **numero** -con el teclado de numeros, que tiene las
///    teclas grandes-, y
/// 2. se elige el **bloque** entre los que tienen ese numero, tocando un
///    boton o directamente la fila.
///
/// Las filas van ordenadas por cercania cuando se sabe donde esta la persona:
/// entre seis acopios 38, el que se busca casi siempre es el de al lado.
///
/// [desde] es la posicion propia, si se conoce.
Future<Acopio?> buscarAcopio(
  BuildContext context,
  AcopiosPredio acopios, {
  LatLng? desde,
}) {
  return showModalBottomSheet<Acopio>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _Buscador(acopios: acopios, desde: desde),
  );
}

class _Buscador extends StatefulWidget {
  const _Buscador({required this.acopios, required this.desde});

  final AcopiosPredio acopios;
  final LatLng? desde;

  @override
  State<_Buscador> createState() => _BuscadorState();
}

class _BuscadorState extends State<_Buscador> {
  final _campo = TextEditingController();
  final _foco = FocusNode();
  String _texto = '';

  /// El bloque elegido para acotar, o nulo para verlos todos.
  String? _bloque;

  /// El teclado de numeros es el de teclas grandes y alcanza casi siempre.
  /// Se pasa al de letras para un acopio "30A" o para buscar por lote.
  bool _letras = false;

  /// Mas que esto no lo recorre nadie con el dedo, y armar cientos de filas en
  /// cada tecla se nota en un telefono de campo.
  static const _maximo = 40;

  /// Sin escribir nada se ofrecen los que estan cerca: muchas veces el acopio
  /// que se busca es uno de esos y no hace falta ni escribir.
  static const _cercanos = 8;

  @override
  void dispose() {
    _campo.dispose();
    _foco.dispose();
    super.dispose();
  }

  void _cambiarTeclado() {
    setState(() => _letras = !_letras);
    // El teclado no cambia de tipo con el campo enfocado: hay que soltarlo y
    // volver a tomarlo.
    _foco.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _foco.requestFocus();
    });
  }

  void _borrar() {
    _campo.clear();
    setState(() {
      _texto = '';
      _bloque = null;
    });
    _foco.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final desde = widget.desde;
    final buscando = _texto.trim().isNotEmpty;
    final numero = AcopiosPredio.numeroBuscado(_texto);

    // Sin texto: los mas cercanos. Con texto: lo que coincide.
    var encontrados = buscando
        ? widget.acopios.buscar(_texto)
        : (desde == null
              ? const <Acopio>[]
              : porCercania(
                  widget.acopios.acopios,
                  desde,
                ).take(_cercanos).toList());

    // Los bloques que tienen lo que se busca, para elegir con un toque.
    final bloques = buscando
        ? ({
            for (final a in encontrados)
              if (a.bloque != null) a.bloque!,
          }.toList()..sort(compararNumerico))
        : const <String>[];
    final bloque = bloques.contains(_bloque) ? _bloque : null;
    if (bloque != null) {
      encontrados = [
        for (final a in encontrados)
          if (a.bloque == bloque) a,
      ];
    }

    // Primero los del numero exacto -el 38 antes que el 38A- y, adentro de
    // cada grupo, el mas cercano arriba.
    if (buscando) {
      final exactos = [
        for (final a in encontrados)
          if (numero == null || a.numero.toLowerCase() == numero) a,
      ];
      final parecidos = [
        for (final a in encontrados)
          if (numero != null && a.numero.toLowerCase() != numero) a,
      ];
      encontrados = [
        ..._ordenar(exactos, desde),
        ..._ordenar(parecidos, desde),
      ];
    }
    final mostrados = encontrados.take(_maximo).toList();

    final String aviso;
    if (!buscando) {
      aviso = desde == null
          ? 'Escribe el numero del acopio.'
          : 'Escribe el numero del acopio, o elige uno de los que tienes '
                'cerca:';
    } else if (encontrados.isEmpty) {
      aviso = 'No hay ningun acopio con ese numero. Revisa lo que escribiste.';
    } else if (bloque == null && bloques.length > 1) {
      aviso = 'Hay ${encontrados.length} acopios. Elige el bloque:';
    } else if (encontrados.length == 1) {
      aviso = 'Es este:';
    } else {
      aviso = '${encontrados.length} acopios';
    }

    return Padding(
      // Que el teclado no tape la lista.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.9,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 6, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Buscar acopio',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    iconSize: 30,
                    icon: const Icon(Icons.close),
                    tooltip: 'Cerrar',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _campo,
                focusNode: _foco,
                autofocus: true,
                keyboardType: _letras
                    ? TextInputType.text
                    : TextInputType.number,
                textInputAction: TextInputAction.search,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
                decoration: InputDecoration(
                  hintText: _letras ? 'Numero o lote' : 'Numero',
                  hintStyle: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w500,
                    color: colores.outline,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  border: const OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colores.outline, width: 2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colores.primary, width: 3),
                  ),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (buscando)
                        IconButton(
                          onPressed: _borrar,
                          iconSize: 30,
                          icon: const Icon(Icons.backspace_outlined),
                          tooltip: 'Borrar',
                        ),
                      IconButton(
                        onPressed: _cambiarTeclado,
                        iconSize: 30,
                        icon: Icon(_letras ? Icons.pin : Icons.abc),
                        tooltip: _letras
                            ? 'Teclado de numeros'
                            : 'Teclado de letras',
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                onChanged: (t) => setState(() {
                  _texto = t;
                  // Otro numero es otra busqueda: el bloque elegido para el
                  // anterior ya no dice nada.
                  _bloque = null;
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
              child: Text(
                aviso,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: buscando && encontrados.isEmpty
                      ? colores.error
                      : colores.onSurface,
                ),
              ),
            ),
            if (bloques.length > 1)
              SizedBox(
                height: 58,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    _BotonBloque(
                      texto: 'Todos',
                      elegido: bloque == null,
                      alTocar: () => setState(() => _bloque = null),
                    ),
                    for (final b in bloques)
                      _BotonBloque(
                        texto: 'Bloque $b',
                        elegido: bloque == b,
                        alTocar: () => setState(() => _bloque = b),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                // Arrastrar la lista esconde el teclado: con el abierto
                // quedan a la vista dos filas, y lo que sigue es elegir.
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: mostrados.length,
                itemBuilder: (context, i) {
                  final a = mostrados[i];
                  return _FilaAcopio(
                    acopio: a,
                    desde: desde,
                    // Solo se dice cual es el mas cercano cuando hay entre
                    // cuales elegir y se sabe donde esta la persona.
                    masCercano:
                        i == 0 &&
                        desde != null &&
                        buscando &&
                        mostrados.length > 1 &&
                        (numero == null || a.numero.toLowerCase() == numero),
                    alTocar: () => Navigator.of(context).pop(a),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// El mas cercano primero si se sabe donde esta la persona; si no, por
  /// bloque y parcela, que es como estan en la planilla.
  static List<Acopio> _ordenar(List<Acopio> acopios, LatLng? desde) {
    if (desde != null) return porCercania(acopios, desde);
    return [...acopios]..sort((a, b) {
      final porBloque = compararNumerico(
        a.bloque ?? a.lote,
        b.bloque ?? b.lote,
      );
      if (porBloque != 0) return porBloque;
      return compararNumerico(a.parcela ?? '', b.parcela ?? '');
    });
  }
}

/// Un boton de bloque: grande, de alto contraste, y que se nota cual esta
/// elegido sin depender del color.
class _BotonBloque extends StatelessWidget {
  const _BotonBloque({
    required this.texto,
    required this.elegido,
    required this.alTocar,
  });

  final String texto;
  final bool elegido;
  final VoidCallback alTocar;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: elegido ? colores.primary : colores.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: elegido ? colores.primary : colores.outline,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: alTocar,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (elegido) ...[
                  Icon(Icons.check, size: 22, color: colores.onPrimary),
                  const SizedBox(width: 6),
                ],
                Text(
                  texto,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: elegido ? colores.onPrimary : colores.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Un acopio en la lista: el numero en grande a la izquierda, y al lado el
/// **bloque** y la **parcela** escritos enteros, que es lo que lo distingue de
/// los otros con el mismo numero.
class _FilaAcopio extends StatelessWidget {
  const _FilaAcopio({
    required this.acopio,
    required this.desde,
    required this.masCercano,
    required this.alTocar,
  });

  final Acopio acopio;
  final LatLng? desde;
  final bool masCercano;
  final VoidCallback alTocar;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final a = acopio;
    final d = desde;
    final lejos = d == null
        ? null
        : const Distance().as(LengthUnit.Meter, d, a.punto);
    final bloque = a.bloque;
    final parcela = a.parcela;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: masCercano ? colores.primaryContainer : colores.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: masCercano ? colores.primary : colores.outlineVariant,
            width: masCercano ? 2.5 : 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: alTocar,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              children: [
                _CajaNumero(numero: a.numero),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (masCercano)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            'EL MAS CERCANO',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.4,
                              color: colores.primary,
                            ),
                          ),
                        ),
                      Text(
                        bloque != null
                            ? 'Bloque $bloque'
                            : (a.lote.isEmpty ? 'Fuera de los lotes' : a.lote),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                          height: 1.1,
                        ),
                      ),
                      if (parcela != null)
                        Text(
                          'Parcela $parcela',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w600,
                            color: colores.onSurface,
                          ),
                        ),
                      // Debajo y no al costado: al costado le quitaba ancho
                      // al bloque, que con la letra del telefono agrandada
                      // -como la usa quien no ve bien- ya no entraba.
                      if (lejos != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'A ${formatearDistancia(lejos)}',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: colores.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 30, color: colores.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
