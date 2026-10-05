import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'vias.dart';

/// Ruteo por las vias del predio, **sin red y sin servidor**.
///
/// Un tecnico marca un punto en el mapa -un lote, una bomba, un tractor
/// varado- y lo que necesita saber no es en que direccion queda: es por donde
/// se llega manejando. En linea recta hay un cano de por medio.
///
/// No se usa OSRM, Mapbox Directions ni Google Directions por la razon de
/// siempre en este proyecto: en Guaicaramo no hay senal. Ademas ninguno de esos
/// servicios conoce las vias internas de la plantacion, que es justo por donde
/// se anda. El grafo se arma con las mismas vias que ya viajan adentro del APK
/// (`assets/zonas/*-vias.json`), asi que el ruteo funciona en modo avion.
///
/// Las vias **proyectadas quedan afuera del grafo**. Son las que todavia no
/// estan construidas: mandar a alguien por una es peor que no darle ruta.
class RedVial {
  RedVial._(this._nodos, this._arcos, this._tramos, this._grilla);

  /// Dos vertices a menos de esto son el mismo cruce.
  ///
  /// El KMZ de topografia no garantiza que dos vias que se cruzan compartan el
  /// vertice exacto: fueron digitalizadas por separado y quedan a centimetros.
  /// Sin unirlas, el grafo se parte en cientos de pedazos y casi ningun destino
  /// es alcanzable. Dos metros es menos que el ancho de cualquier via del
  /// predio, asi que no puede pegar dos vias que en el terreno estan separadas.
  static const toleranciaNodoM = 2.0;

  /// Hasta donde se suelda una punta suelta contra otra via.
  ///
  /// El caso tipico es un cruce en T: una via entronca contra el costado de
  /// otra, en el medio de un tramo, no contra un vertice. Sin esta soldadura la
  /// via que entronca queda aislada aunque se vea pegada en la pantalla.
  static const soldaduraM = 6.0;

  /// Mas lejos que esto de cualquier via, no hay ruta que ofrecer.
  ///
  /// No es una limitacion tecnica: es que a 2 km de la via mas cercana, en el
  /// medio de un lote, la recta que dibujaria la app no es por donde se va a
  /// caminar y da una falsa precision.
  static const maxDesdeLaViaM = 300.0;

  /// Velocidades para estimar cuanto se tarda. Son de vehiculo de campo en
  /// plantacion, no de carretera nacional: nadie hace 80 entre palmas.
  static const _kmhPavimentada = 50.0;
  static const _kmhBalastrada = 25.0;

  /// Los tramos de punta a punta se hacen a pie: del carro al punto marcado.
  static const _kmhAPie = 4.5;

  /// Arma el grafo a partir de las vias de un predio.
  ///
  /// Es O(vertices) con una grilla espacial de por medio. En Guaicaramo son
  /// ~15.000 vertices y tarda decimas de segundo, una sola vez por arranque:
  /// del lado del provider queda cacheado mientras alguien mire el mapa.
  factory RedVial.construir(ViasPredio vias) {
    final construidas = vias.vias.where((v) => v.tipo.construida).toList();

    // 1. Los vertices se agrupan: dos que caen a menos de la tolerancia pasan a
    //    ser un solo nodo del grafo.
    final agrupador = _Agrupador(toleranciaNodoM);
    final lineas = <_Linea>[];
    for (final via in construidas) {
      final ids = <int>[];
      for (final p in via.puntos) {
        final id = agrupador.nodo(p);
        // Vertices repetidos seguidos -los hay en el KMZ- no aportan arco.
        if (ids.isEmpty || ids.last != id) ids.add(id);
      }
      if (ids.length >= 2) lineas.add(_Linea(ids, via.tipo));
    }

    final nodos = agrupador.puntos;

    // 2. Cuantos segmentos toca cada nodo. Un nodo tocado una sola vez es una
    //    punta suelta: o es un camino sin salida real, o es un entronque que no
    //    quedo pegado. El paso 3 decide cual de los dos.
    final usos = List<int>.filled(nodos.length, 0);
    for (final linea in lineas) {
      for (var i = 0; i < linea.ids.length - 1; i++) {
        usos[linea.ids[i]]++;
        usos[linea.ids[i + 1]]++;
      }
    }

    // 3. Se sueldan las puntas sueltas contra el tramo mas cercano de otra via.
    //    El nodo de la punta se inserta adentro de ese tramo, partiendolo.
    final grillaObra = _GrillaSegmentos(_ladoCeldaGrados);
    for (var li = 0; li < lineas.length; li++) {
      final ids = lineas[li].ids;
      for (var i = 0; i < ids.length - 1; i++) {
        grillaObra.agregar(nodos[ids[i]], nodos[ids[i + 1]], li, i);
      }
    }

    final inserciones = <int, List<_Insercion>>{};
    for (var li = 0; li < lineas.length; li++) {
      final ids = lineas[li].ids;
      for (final pos in [0, ids.length - 1]) {
        final nodo = ids[pos];
        if (usos[nodo] != 1) continue;

        final cerca = grillaObra.masCercano(
          nodos[nodo],
          maxM: soldaduraM,
          nodos: nodos,
          lineas: lineas,
          excluirLinea: li,
          excluirNodo: nodo,
        );
        if (cerca == null) continue;

        // Se guarda por tramo (linea, segmento) y con el `t` de donde cae, para
        // poder encadenar varias inserciones en orden sobre el mismo segmento.
        inserciones
            .putIfAbsent(_claveTramo(cerca.linea, cerca.segmento), () => [])
            .add(_Insercion(cerca.t, nodo));
      }
    }

    // 4. Adyacencia. Cada segmento se recorre con sus inserciones intercaladas.
    final arcos = List.generate(nodos.length, (_) => <_Arco>[]);
    final tramos = <_Tramo>[];
    final vistos = <(int, int)>{};

    void conectar(int a, int b, TipoVia tipo) {
      if (a == b) return;
      final clave = a < b ? (a, b) : (b, a);
      if (!vistos.add(clave)) return;
      final metros = distanciaM(
        PuntoGeo(nodos[a].latitude, nodos[a].longitude),
        PuntoGeo(nodos[b].latitude, nodos[b].longitude),
      );
      arcos[a].add(_Arco(b, metros, tipo));
      arcos[b].add(_Arco(a, metros, tipo));
      tramos.add(_Tramo(a, b, tipo));
    }

    for (var li = 0; li < lineas.length; li++) {
      final linea = lineas[li];
      for (var i = 0; i < linea.ids.length - 1; i++) {
        final extra = inserciones[_claveTramo(li, i)];
        if (extra == null) {
          conectar(linea.ids[i], linea.ids[i + 1], linea.tipo);
          continue;
        }
        extra.sort((a, b) => a.t.compareTo(b.t));
        var anterior = linea.ids[i];
        for (final ins in extra) {
          conectar(anterior, ins.nodo, linea.tipo);
          anterior = ins.nodo;
        }
        conectar(anterior, linea.ids[i + 1], linea.tipo);
      }
    }

    // 5. Grilla definitiva, sobre los tramos del grafo: es la que responde
    //    "cual es la via mas cercana a este punto".
    final grilla = _GrillaTramos(_ladoCeldaGrados);
    for (var i = 0; i < tramos.length; i++) {
      grilla.agregar(nodos[tramos[i].a], nodos[tramos[i].b], i);
    }

    return RedVial._(nodos, arcos, tramos, grilla);
  }

  final List<LatLng> _nodos;
  final List<List<_Arco>> _arcos;
  final List<_Tramo> _tramos;
  final _GrillaTramos _grilla;

  /// Cuantos cruces tiene la red. Es diagnostico, para las pruebas.
  int get cuantosNodos => _nodos.length;

  /// Cuantos tramos de via unen esos cruces.
  int get cuantosTramos => _tramos.length;

  /// La ruta por via desde un punto hasta otro, o `null` si no hay.
  ///
  /// Devuelve `null` cuando alguno de los dos puntos queda a mas de
  /// [maxDesdeLaViaM] de cualquier via, o cuando los dos estan sobre la red
  /// pero en pedazos que no se tocan: hay sectores del predio que no se
  /// comunican por adentro y se va por la ruta nacional, que no esta en el
  /// plano. Decir "no hay ruta" es mejor que inventar una.
  Ruta? ruta({required LatLng desde, required LatLng hasta}) {
    if (_tramos.isEmpty) return null;

    final origen = _proyectar(desde);
    final destino = _proyectar(hasta);
    if (origen == null || destino == null) return null;

    // Los dos puntos caen sobre el mismo tramo: no hay nada que buscar, se va
    // derecho por el. Sin este caso el algoritmo daria la vuelta hasta un cruce
    // y volveria.
    if (origen.tramo == destino.tramo) {
      final tramo = _tramos[origen.tramo];
      final metros = distanciaM(
        PuntoGeo(origen.punto.latitude, origen.punto.longitude),
        PuntoGeo(destino.punto.latitude, destino.punto.longitude),
      );
      return Ruta._(
        origen: desde,
        destino: hasta,
        porLaVia: [origen.punto, destino.punto],
        metros: metros,
        minutosPorLaVia: _minutos(metros, tramo.tipo),
      );
    }

    final camino = _dijkstra(origen, destino);
    if (camino == null) return null;

    return Ruta._(
      origen: desde,
      destino: hasta,
      porLaVia: camino.puntos,
      metros: camino.metros,
      minutosPorLaVia: camino.minutos,
    );
  }

  /// Dijkstra con los dos extremos colgados de la red como nodos virtuales.
  ///
  /// No es A*: la heuristica de la recta ahorra poco en una red de 12.000 nodos
  /// que cabe en 20 km, y el ruteo corre una vez por destino -no por cuadro-,
  /// asi que el codigo simple gana.
  _Camino? _dijkstra(_Proyeccion origen, _Proyeccion destino) {
    final distancias = List<double>.filled(_nodos.length, double.infinity);
    final minutos = List<double>.filled(_nodos.length, 0);
    final previo = List<int>.filled(_nodos.length, -1);
    final cola = _ColaPrioridad();

    // Arranque: desde el punto proyectado se puede ir a cualquiera de las dos
    // puntas del tramo sobre el que cayo, pagando lo que falta de ese tramo.
    final tramoOrigen = _tramos[origen.tramo];
    for (final nodo in [tramoOrigen.a, tramoOrigen.b]) {
      final d = _metros(origen.punto, _nodos[nodo]);
      if (d < distancias[nodo]) {
        distancias[nodo] = d;
        minutos[nodo] = _minutos(d, tramoOrigen.tipo);
        cola.agregar(nodo, d);
      }
    }

    // Llegada: las dos puntas del tramo del destino, con lo que falta hasta el
    // punto proyectado.
    final tramoDestino = _tramos[destino.tramo];
    final salidas = <int, double>{
      tramoDestino.a: _metros(_nodos[tramoDestino.a], destino.punto),
      tramoDestino.b: _metros(_nodos[tramoDestino.b], destino.punto),
    };

    var mejor = double.infinity;
    var mejorNodo = -1;
    final listos = List<bool>.filled(_nodos.length, false);

    while (cola.hayAlguno) {
      final (nodo, costo) = cola.sacar();
      if (listos[nodo]) continue;
      listos[nodo] = true;

      // Todo lo que queda en la cola cuesta al menos `costo`: si el mejor final
      // encontrado ya es mas barato que eso, no hay nada mejor por venir.
      if (costo >= mejor) break;

      final salida = salidas[nodo];
      if (salida != null && costo + salida < mejor) {
        mejor = costo + salida;
        mejorNodo = nodo;
      }

      for (final arco in _arcos[nodo]) {
        final d = costo + arco.metros;
        if (d < distancias[arco.hasta]) {
          distancias[arco.hasta] = d;
          minutos[arco.hasta] =
              minutos[nodo] + _minutos(arco.metros, arco.tipo);
          previo[arco.hasta] = nodo;
          cola.agregar(arco.hasta, d);
        }
      }
    }

    if (mejorNodo < 0) return null;

    final nodos = <int>[];
    for (var n = mejorNodo; n >= 0; n = previo[n]) {
      nodos.add(n);
    }

    final puntos = <LatLng>[
      origen.punto,
      for (final n in nodos.reversed) _nodos[n],
      destino.punto,
    ];

    return _Camino(
      puntos: puntos,
      metros: mejor,
      minutos:
          minutos[mejorNodo] +
          _minutos(salidas[mejorNodo]!, _tramos[destino.tramo].tipo),
    );
  }

  /// El punto de la red mas cercano a uno dado.
  _Proyeccion? _proyectar(LatLng punto) {
    final cerca = _grilla.masCercano(
      punto,
      maxM: maxDesdeLaViaM,
      resolver: (i) {
        final t = _tramos[i];
        return (_nodos[t.a], _nodos[t.b]);
      },
    );
    if (cerca == null) return null;

    final t = _tramos[cerca.indice];
    return _Proyeccion(
      tramo: cerca.indice,
      punto: _interpolar(_nodos[t.a], _nodos[t.b], cerca.t),
      metrosDesdeElPunto: cerca.metros,
    );
  }

  static double _minutos(double metros, TipoVia tipo) {
    final kmh = switch (tipo) {
      TipoVia.pavimentada || TipoVia.ruta => _kmhPavimentada,
      TipoVia.balastrada => _kmhBalastrada,
      // No entra al grafo, pero el switch tiene que ser total.
      TipoVia.proyectada => _kmhBalastrada,
    };
    return metros / 1000 / kmh * 60;
  }

  /// Lado de celda de las grillas espaciales, en grados.
  ///
  /// ~200 m: bastante grande para que un tramo entre en pocas celdas y bastante
  /// chico para que una consulta no barra media plantacion.
  static const _ladoCeldaGrados = 0.0018;
}

/// Una ruta calculada: por donde se va y cuanto cuesta.
class Ruta {
  const Ruta._({
    required this.origen,
    required this.destino,
    required this.porLaVia,
    required this.metros,
    required this.minutosPorLaVia,
  });

  /// De donde salio el calculo: la posicion del GPS cuando se pidio.
  final LatLng origen;

  /// El punto que se marco en el mapa.
  final LatLng destino;

  /// La linea sobre las vias, de donde se entra a donde se sale.
  final List<LatLng> porLaVia;

  /// Metros de via. No incluye los dos tramos a campo traviesa.
  final double metros;

  final double minutosPorLaVia;

  /// Donde se entra a la via saliendo de la posicion actual.
  LatLng get entrada => porLaVia.first;

  /// Donde se deja la via para llegar al punto marcado.
  LatLng get salida => porLaVia.last;

  /// Lo que hay que caminar desde donde se esta hasta subirse a la via.
  double get metrosHastaLaVia => _metros(origen, entrada);

  /// Lo que hay que caminar de la via al punto marcado.
  double get metrosDesdeLaVia => _metros(salida, destino);

  /// Total de punta a punta, incluidos los dos tramos a pie.
  double get metrosTotales => metrosHastaLaVia + metros + metrosDesdeLaVia;

  /// Estimado de cuanto toma, en minutos. Los extremos van a paso de persona.
  double get minutos =>
      minutosPorLaVia +
      (metrosHastaLaVia + metrosDesdeLaVia) / 1000 / RedVial._kmhAPie * 60;

  /// La linea completa, incluidos los dos tramos a campo traviesa. Es sobre
  /// esta que se mide si alguien se salio de la ruta.
  List<LatLng> get completa => [origen, ...porLaVia, destino];

  /// Donde esta alguien respecto de esta ruta.
  ProgresoRuta progreso(LatLng posicion) {
    final linea = completa;
    var desvio = double.infinity;
    var segmento = 0;
    var t = 0.0;

    for (var i = 0; i < linea.length - 1; i++) {
      final p = _proyectarEnSegmento(posicion, linea[i], linea[i + 1]);
      if (p.metros < desvio) {
        desvio = p.metros;
        segmento = i;
        t = p.t;
      }
    }

    // Lo que falta: el resto del segmento en el que se esta, mas todos los que
    // siguen. Se mide contra el punto proyectado y no contra la posicion, para
    // que un desvio lateral no descuente ni sume camino.
    final pie = _interpolar(linea[segmento], linea[segmento + 1], t);
    var restante = _metros(pie, linea[segmento + 1]);
    for (var i = segmento + 1; i < linea.length - 1; i++) {
      restante += _metros(linea[i], linea[i + 1]);
    }

    return ProgresoRuta(
      desvioM: desvio,
      metrosRestantes: restante,
      segmento: segmento,
      pie: pie,
    );
  }
}

/// Como va alguien respecto de la ruta que se le calculo.
class ProgresoRuta {
  const ProgresoRuta({
    required this.desvioM,
    required this.metrosRestantes,
    required this.segmento,
    required this.pie,
  });

  /// A que distancia esta de la linea de la ruta.
  final double desvioM;

  /// Cuanto falta siguiendo la ruta desde donde esta.
  final double metrosRestantes;

  /// En que tramo de [Ruta.completa] va: 0 es el tramo a pie hasta la via, el
  /// ultimo es el tramo a pie desde la via hasta el punto marcado.
  final int segmento;

  /// La posicion llevada sobre la linea de la ruta. Es donde se corta lo ya
  /// recorrido de lo que falta, para que la linea en pantalla nazca debajo de
  /// la flecha y no unos metros al costado.
  final LatLng pie;

  /// Metros de desvio a partir de los cuales se vuelve a calcular.
  ///
  /// No puede ser chico. El GPS bajo palma entrega 10-20 m de error con el
  /// telefono quieto, y una via de 4 m de ancho se recorre por cualquiera de
  /// sus dos huellas: con un umbral de 15 m la app estaria recalculando sola,
  /// parada, y cambiando la ruta en la pantalla mientras alguien maneja.
  static const umbralM = 45.0;

  /// A esto se considera llegado, y la ruta se borra sola.
  static const llegadaM = 25.0;

  /// Si conviene recalcular. La precision del fix entra en la cuenta: con 30 m
  /// de error, 50 m de desvio pueden ser el mismo lugar.
  bool hayQueRecalcular(double precisionM) =>
      desvioM > umbralM + math.max(0, precisionM - 10);

  bool get llego => metrosRestantes <= llegadaM;
}

// --- Interno -----------------------------------------------------------

class _Linea {
  const _Linea(this.ids, this.tipo);
  final List<int> ids;
  final TipoVia tipo;
}

class _Arco {
  const _Arco(this.hasta, this.metros, this.tipo);
  final int hasta;
  final double metros;
  final TipoVia tipo;
}

class _Tramo {
  const _Tramo(this.a, this.b, this.tipo);
  final int a;
  final int b;
  final TipoVia tipo;
}

class _Insercion {
  const _Insercion(this.t, this.nodo);
  final double t;
  final int nodo;
}

class _Proyeccion {
  const _Proyeccion({
    required this.tramo,
    required this.punto,
    required this.metrosDesdeElPunto,
  });
  final int tramo;
  final LatLng punto;
  final double metrosDesdeElPunto;
}

class _Camino {
  const _Camino({
    required this.puntos,
    required this.metros,
    required this.minutos,
  });
  final List<LatLng> puntos;
  final double metros;
  final double minutos;
}

/// Agrupa vertices que caen a menos de una tolerancia en un solo nodo.
class _Agrupador {
  _Agrupador(this.toleranciaM);

  final double toleranciaM;
  final puntos = <LatLng>[];
  final _celdas = <(int, int), List<int>>{};

  // La celda mide una tolerancia de lado: asi dos puntos a menos de la
  // tolerancia siempre caen en la misma celda o en una vecina.
  double get _lado => toleranciaM / 111320.0 / math.cos(4.5 * math.pi / 180);

  int nodo(LatLng p) {
    final cx = (p.longitude / _lado).floor();
    final cy = (p.latitude / _lado).floor();

    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final i in _celdas[(cx + dx, cy + dy)] ?? const <int>[]) {
          if (_metros(p, puntos[i]) < toleranciaM) return i;
        }
      }
    }

    final id = puntos.length;
    puntos.add(p);
    _celdas.putIfAbsent((cx, cy), () => []).add(id);
    return id;
  }
}

/// Grilla de segmentos por indice generico, para preguntar cual cae mas cerca.
class _GrillaTramos {
  _GrillaTramos(this.lado);

  final double lado;
  final _celdas = <(int, int), List<int>>{};

  void agregar(LatLng a, LatLng b, int indice) {
    for (final celda in _celdasDe(a, b, lado)) {
      _celdas.putIfAbsent(celda, () => []).add(indice);
    }
  }

  _Cercano? masCercano(
    LatLng p, {
    required double maxM,
    required (LatLng, LatLng) Function(int) resolver,
  }) {
    final cx = (p.longitude / lado).floor();
    final cy = (p.latitude / lado).floor();
    // Cuantos anillos de celdas hay que mirar para cubrir `maxM`.
    final anillos = (maxM / (lado * 111320.0 * math.cos(4.5 * math.pi / 180)))
        .ceil();

    _Cercano? mejor;
    final vistos = <int>{};
    for (var r = 0; r <= anillos; r++) {
      for (var dx = -r; dx <= r; dx++) {
        for (var dy = -r; dy <= r; dy++) {
          // Solo el borde del anillo: lo de adentro ya se miro.
          if (r > 0 && dx.abs() != r && dy.abs() != r) continue;
          for (final i in _celdas[(cx + dx, cy + dy)] ?? const <int>[]) {
            if (!vistos.add(i)) continue;
            final (a, b) = resolver(i);
            final proy = _proyectarEnSegmento(p, a, b);
            if (proy.metros <= maxM &&
                (mejor == null || proy.metros < mejor.metros)) {
              mejor = _Cercano(i, proy.metros, proy.t);
            }
          }
        }
      }
    }

    return mejor;
  }
}

/// La grilla que se usa mientras se arma el grafo, cuando los tramos todavia
/// se direccionan por (linea, segmento) y no por indice.
class _GrillaSegmentos {
  _GrillaSegmentos(this.lado);

  final double lado;
  final _celdas = <(int, int), List<(int, int)>>{};

  void agregar(LatLng a, LatLng b, int linea, int segmento) {
    for (final celda in _celdasDe(a, b, lado)) {
      _celdas.putIfAbsent(celda, () => []).add((linea, segmento));
    }
  }

  _Entronque? masCercano(
    LatLng p, {
    required double maxM,
    required List<LatLng> nodos,
    required List<_Linea> lineas,
    required int excluirLinea,
    required int excluirNodo,
  }) {
    final cx = (p.longitude / lado).floor();
    final cy = (p.latitude / lado).floor();

    _Entronque? mejor;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final (li, si)
            in _celdas[(cx + dx, cy + dy)] ?? const <(int, int)>[]) {
          // Una via no se suelda contra si misma: su propia punta esta a cero
          // de su propio primer segmento.
          if (li == excluirLinea) continue;
          final a = lineas[li].ids[si];
          final b = lineas[li].ids[si + 1];
          if (a == excluirNodo || b == excluirNodo) continue;

          final proy = _proyectarEnSegmento(p, nodos[a], nodos[b]);
          if (proy.metros <= maxM &&
              (mejor == null || proy.metros < mejor.metros)) {
            mejor = _Entronque(li, si, proy.t, proy.metros);
          }
        }
      }
    }
    return mejor;
  }
}

class _Cercano {
  const _Cercano(this.indice, this.metros, this.t);
  final int indice;
  final double metros;
  final double t;
}

class _Entronque {
  const _Entronque(this.linea, this.segmento, this.t, this.metros);
  final int linea;
  final int segmento;
  final double t;
  final double metros;
}

/// Monticulo binario. Se escribe a mano para no depender de `collection`, que
/// en este proyecto solo llega como dependencia transitiva de Flutter.
class _ColaPrioridad {
  final _nodos = <int>[];
  final _costos = <double>[];

  bool get hayAlguno => _nodos.isNotEmpty;

  void agregar(int nodo, double costo) {
    _nodos.add(nodo);
    _costos.add(costo);
    var i = _nodos.length - 1;
    while (i > 0) {
      final padre = (i - 1) ~/ 2;
      if (_costos[padre] <= _costos[i]) break;
      _intercambiar(i, padre);
      i = padre;
    }
  }

  (int, double) sacar() {
    final nodo = _nodos.first;
    final costo = _costos.first;
    final ultimo = _nodos.length - 1;
    _intercambiar(0, ultimo);
    _nodos.removeLast();
    _costos.removeLast();

    var i = 0;
    while (true) {
      final izq = 2 * i + 1;
      final der = izq + 1;
      var menor = i;
      if (izq < _nodos.length && _costos[izq] < _costos[menor]) menor = izq;
      if (der < _nodos.length && _costos[der] < _costos[menor]) menor = der;
      if (menor == i) break;
      _intercambiar(i, menor);
      i = menor;
    }

    return (nodo, costo);
  }

  void _intercambiar(int a, int b) {
    final n = _nodos[a];
    _nodos[a] = _nodos[b];
    _nodos[b] = n;
    final c = _costos[a];
    _costos[a] = _costos[b];
    _costos[b] = c;
  }
}

/// Las celdas que toca el rectangulo de un segmento.
Iterable<(int, int)> _celdasDe(LatLng a, LatLng b, double lado) sync* {
  final x1 = (math.min(a.longitude, b.longitude) / lado).floor();
  final x2 = (math.max(a.longitude, b.longitude) / lado).floor();
  final y1 = (math.min(a.latitude, b.latitude) / lado).floor();
  final y2 = (math.max(a.latitude, b.latitude) / lado).floor();
  for (var x = x1; x <= x2; x++) {
    for (var y = y1; y <= y2; y++) {
      yield (x, y);
    }
  }
}

int _claveTramo(int linea, int segmento) => linea * 100000 + segmento;

double _metros(LatLng a, LatLng b) => distanciaM(
  PuntoGeo(a.latitude, a.longitude),
  PuntoGeo(b.latitude, b.longitude),
);

LatLng _interpolar(LatLng a, LatLng b, double t) => LatLng(
  a.latitude + (b.latitude - a.latitude) * t,
  a.longitude + (b.longitude - a.longitude) * t,
);

/// Proyeccion de un punto sobre un segmento, en plano local.
///
/// Los grados se pasan a metros con el factor de la latitud del punto, igual
/// que en `zona.dart`. Sobre tramos de decenas de metros es indistinguible de
/// hacerlo sobre el elipsoide.
({double metros, double t}) _proyectarEnSegmento(LatLng p, LatLng a, LatLng b) {
  final mPorLon = 111320.0 * math.cos(p.latitude * math.pi / 180);
  const mPorLat = 110540.0;

  final ax = (a.longitude - p.longitude) * mPorLon;
  final ay = (a.latitude - p.latitude) * mPorLat;
  final bx = (b.longitude - p.longitude) * mPorLon;
  final by = (b.latitude - p.latitude) * mPorLat;

  final dx = bx - ax;
  final dy = by - ay;
  final largo2 = dx * dx + dy * dy;
  if (largo2 == 0) return (metros: math.sqrt(ax * ax + ay * ay), t: 0);

  var t = (-ax * dx - ay * dy) / largo2;
  t = t.clamp(0.0, 1.0);
  final px = ax + t * dx;
  final py = ay + t * dy;
  return (metros: math.sqrt(px * px + py * py), t: t);
}
