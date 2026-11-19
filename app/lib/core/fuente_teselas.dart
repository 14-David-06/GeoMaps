import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart'
    show CachedMapTile, CachedMapTileMetadata, MapCachingProvider;
import 'package:http/http.dart' as http;

import 'teselas.dart';

/// Lo que se consiguio para una tesela: los bytes de una imagen, y de que
/// tesela son.
class TeselaCargada {
  const TeselaCargada(this.bytes, this.origen, {this.provisional = false});

  final Uint8List bytes;

  /// La tesela de la que salio la imagen. Si no es la pedida, es una de mas
  /// arriba: hay que recortar el pedazo que corresponde y estirarlo.
  final Tesela origen;

  /// No es la respuesta definitiva: vale la pena preguntarle a la red. Pasa
  /// cuando se muestra una de mas arriba porque **no se pudo preguntar** por
  /// la pedida (sin red), no porque no exista; y en lo que entrega
  /// [FuenteTeselas.guardada], tambien cuando la copia del telefono vencio.
  final bool provisional;
}

/// No hay imagen para esa zona ni varios niveles mas arriba.
class SinTesela implements Exception {
  const SinTesela(this.tesela);

  final Tesela tesela;

  @override
  String toString() => 'Sin imagen para la tesela $tesela';
}

/// De donde salen las imagenes del mapa base: la cache del telefono, la red,
/// y cuando ninguna de las dos tiene la que se pidio, **la del nivel de
/// arriba**.
///
/// Existe por dos huecos que el mapa mostraba y que en campo son lo mismo, no
/// ver el terreno:
///
/// - **"Map data not yet available".** El satelite no tiene imagen de una
///   plantacion mas alla de cierto nivel (el 18 en Guaicaramo), y en vez de
///   decir que no, manda un cartel. Aca se lo reconoce ([esRellenoEsri]) y se
///   muestra la imagen del ultimo nivel que si existe, estirada.
/// - **El gris sin senal.** Sin red, una zona que se guardo con menos detalle
///   del que se esta mirando quedaba en blanco. Ahora se ve con lo que haya.
///
/// ## Lo guardado primero, la red despues
///
/// El mapa se usa donde la senal es poca o ninguna, y con senal poca un
/// pedido no falla: se queda colgado hasta que vence. Por eso son dos pasos y
/// no uno:
///
/// 1. [guardada] contesta en el acto con lo que haya en el telefono, **sin
///    tocar la red**: la tesela pedida aunque este vencida, o la de mas arriba.
/// 2. [cargar] sale a buscar la de verdad, por detras, y el mapa la cambia
///    cuando llega.
///
/// Antes era un solo paso y la red iba primero: con una raya de senal cada
/// imagen esperaba quince segundos a un servidor que no iba a contestar, antes
/// de mostrar la copia que ya estaba guardada.
///
/// Y la red se cuida, porque la paga quien esta en el lote:
///
/// - Pocos pedidos a la vez ([enParalelo]). Cuarenta conexiones sobre una red
///   que apenas da para una no bajan cuarenta imagenes: no baja ninguna.
/// - Si un pedido falla se deja de pedir por un rato, cada vez mas largo
///   mientras siga fallando. Vencido el rato sale **uno solo** a probar, y los
///   demas hacen lo que le pase a ese.
/// - Una copia vencida no se vuelve a bajar entera: se pregunta si cambio
///   (`If-None-Match`), y si no cambio son doscientos bytes en vez de veinte
///   mil.
///
/// No dibuja nada: entrega bytes. Quien los recorta y los pinta es
/// `ui/proveedor_teselas.dart`.
class FuenteTeselas {
  FuenteTeselas({
    required this.plantilla,
    required this.paquete,
    required this.almacen,
    http.Client? cliente,
    DateTime Function()? reloj,
  }) : _cliente = cliente ?? http.Client(),
       _reloj = reloj ?? DateTime.now;

  /// La direccion de las teselas (`.../{z}/{y}/{x}`). La misma que usa la
  /// descarga de zonas: la cache guarda cada imagen bajo su direccion.
  final String plantilla;

  /// Va en el `User-Agent`, como lo piden los servidores publicos.
  final String paquete;

  /// Se pide cada vez y no se guarda: la cache se crea al arrancar la app, y
  /// en las pruebas no hay.
  final MapCachingProvider? Function() almacen;
  final http.Client _cliente;
  final DateTime Function() _reloj;

  /// Cuantos niveles se sube a buscar una imagen. Cinco niveles es estirar la
  /// imagen 32 veces: mas alla ya no se distingue nada y es mejor el hueco.
  static const maxSaltos = 5;

  /// Despues de un pedido que fallo por la red no se vuelve a intentar por un
  /// rato: sin senal, cada intento es una espera, y son decenas por pantalla.
  /// Es el primer rato; si al volver a probar sigue sin red, se duplica.
  static const pausaSinRed = Duration(seconds: 20);

  /// Hasta donde crece la pausa. Mas que esto y quien llega a una zona con
  /// senal se queda mirando imagenes borrosas con la red ya andando.
  static const pausaMaxima = Duration(minutes: 2);

  /// Cuanto se espera a un pedido. Largo, porque ya no frena lo que se ve:
  /// corre por detras, y en una red lenta la imagen llega a los diez segundos.
  static const espera = Duration(seconds: 15);

  /// Pedidos a la vez. Es un servidor publico y gratuito, y en red rural mas
  /// pedidos en paralelo no bajan mas rapido: se pisan.
  static const enParalelo = 6;

  /// Con tantas teselas sin imagen en una misma zona y nivel, y ninguna con
  /// imagen, se da por hecho que el nivel entero falta ahi y no se pregunta
  /// mas: cada pregunta es un pedido que vuelve con el cartel.
  static const _faltasParaGeneralizar = 4;

  /// Cuantas copias leidas del telefono se tienen a mano. Las cuatro hijas de
  /// una tesela piden la misma madre: leerla una vez del disco y no cuatro.
  static const _enMemoria = 96;

  final _noHay = <Tesela>{};
  final _faltanEnBloque = <Tesela, int>{};
  final _hayEnBloque = <Tesela>{};
  final _provisionales = <Tesela>{};
  final _enCurso = <Tesela, Future<_Intento>>{};
  final _memoria = <Tesela, CachedMapTile>{};
  final _esperanRed = <Tesela, void Function()>{};

  // El corte de la red: hasta cuando no se pide, cuantas veces seguidas
  // fallo, y el pedido que salio a probar si ya volvio.
  DateTime? _sinRedHasta;
  int _fallos = 0;
  Completer<bool>? _sonda;

  // Los turnos para salir a la red.
  int _enVuelo = 0;
  final _cola = <Completer<bool>>[];

  /// Lo que el telefono ya tiene para [pedida], **sin tocar la red**: su
  /// imagen guardada, o la del nivel mas cercano hacia arriba. Nulo si no hay
  /// nada guardado de esa zona.
  ///
  /// Contesta en milisegundos, haya senal o no. Si lo que entrega es
  /// `provisional` -una de mas arriba cuando no se sabe si la pedida existe, o
  /// una copia vencida- conviene pedir despues la de verdad con [cargar].
  Future<TeselaCargada?> guardada(Tesela pedida) async {
    var sinSaber = false;
    for (var s = 0; s <= maxSaltos && s <= pedida.z; s++) {
      final t = pedida.ancestro(s);
      if (_seSabeQueFalta(t)) continue;

      final copia = await _leer(t);
      if (copia == null) {
        // No esta guardada y no se sabe si existe: eso lo dice la red.
        sinSaber = true;
        continue;
      }
      if (esRellenoEsri(copia.bytes, etag: copia.metadata.etag)) {
        _anotarFalta(t);
        continue;
      }
      _anotarHay(t);
      return TeselaCargada(
        copia.bytes,
        t,
        provisional: sinSaber || copia.metadata.isStale,
      );
    }
    return null;
  }

  /// Consigue una imagen para [pedida]: la suya, o la del nivel mas cercano
  /// hacia arriba que exista. Lanza [SinTesela] si no hay nada.
  ///
  /// Sale a la red si hace falta, asi que puede tardar lo que tarde la red.
  /// Lo que se ve mientras tanto lo da [guardada].
  Future<TeselaCargada> cargar(Tesela pedida) async {
    var sinSaber = false;
    for (var s = 0; s <= maxSaltos && s <= pedida.z; s++) {
      final t = pedida.ancestro(s);
      final intento = await _una(t);
      final bytes = intento.bytes;
      if (bytes != null) {
        _anotarProvisional(pedida, sinSaber);
        return TeselaCargada(bytes, t, provisional: sinSaber);
      }
      if (intento.sinTurno) {
        // Se quedo sin turno para salir a la red: no va a ir a buscar por la
        // red a sus mayores, que seria colarse adelante de lo que si se esta
        // mirando. Se conforma con lo que haya guardado.
        _anotarProvisional(pedida, true);
        final local = await guardada(pedida);
        if (local == null) throw SinTesela(pedida);
        return TeselaCargada(local.bytes, local.origen, provisional: true);
      }
      if (intento.sinSaber) sinSaber = true;
    }
    _anotarProvisional(pedida, sinSaber);
    throw SinTesela(pedida);
  }

  /// Si conviene volver a pedir [t]: la ultima vez se resolvio a medias por
  /// falta de red, y ahora hay con que preguntar. Se contesta que si una sola
  /// vez: quien pregunta se compromete a reintentarla.
  ///
  /// Con la red cortada contesta que no, y la tesela sigue anotada: volver a
  /// pedirla seria leer, decodificar y recortar otra vez la misma imagen
  /// borrosa que ya se esta viendo.
  bool fueProvisional(Tesela t) {
    if (!_provisionales.contains(t) || _redCortada) return false;
    _provisionales.remove(t);
    return true;
  }

  /// Si [t] quedo sin resolver por falta de red, y no porque no exista. No
  /// la da por reintentada, como [fueProvisional]: solo mira.
  bool quedoPendiente(Tesela t) => _provisionales.contains(t);

  /// La red volvio: lo dice el telefono. Se levanta el corte sin esperar a
  /// que venza la pausa, para que lo borroso se aclare en cuanto hay senal.
  void reanudar() {
    _sinRedHasta = null;
    _fallos = 0;
    _avisarQueVolvio();
  }

  /// Pide que se avise cuando la red vuelva, para volver a buscar [t]. Lo usa
  /// la imagen que quedo borrosa en pantalla: asi se aclara sola, sin que
  /// nadie tenga que mover el mapa.
  ///
  /// Se avisa una sola vez. Quien sigue sin conseguirla se vuelve a anotar.
  void avisarAlVolver(Tesela t, void Function() reintentar) {
    _esperanRed.remove(t);
    // Un tope: en pantalla entran unas sesenta. Las que se pasen son de zonas
    // que ya no se miran, y se reintentan igual cuando se las vuelva a ver.
    if (_esperanRed.length >= 400) _esperanRed.remove(_esperanRed.keys.first);
    _esperanRed[t] = reintentar;
  }

  void _avisarQueVolvio() {
    if (_esperanRed.isEmpty) return;
    final avisos = List.of(_esperanRed.values);
    _esperanRed.clear();
    // Despues, no ahora: se llega aca desde el medio de un pedido.
    scheduleMicrotask(() {
      for (final aviso in avisos) {
        try {
          aviso();
        } catch (_) {
          // Una imagen que ya no existe no puede frenar el aviso a las demas.
        }
      }
    });
  }

  bool get _redCortada {
    final pausa = _sinRedHasta;
    return pausa != null && _reloj().isBefore(pausa);
  }

  void _anotarProvisional(Tesela t, bool provisional) {
    if (!provisional) {
      _provisionales.remove(t);
      return;
    }
    // Un tope, como el de las que faltan: vaciarlo solo cuesta que alguna no
    // se reintente sola hasta que se la vuelva a mirar.
    if (_provisionales.length > 5000) _provisionales.clear();
    _provisionales.add(t);
  }

  /// Un intento por una tesela exacta. Los pedidos simultaneos por la misma
  /// -cuatro hijas buscando a su madre- comparten uno solo.
  Future<_Intento> _una(Tesela t) {
    final enCurso = _enCurso[t];
    if (enCurso != null) return enCurso;
    // Con llaves: si la funcion devolviera lo que saca del mapa -este mismo
    // futuro-, `whenComplete` esperaria a que termine para terminar, y no
    // terminaria nunca.
    final nuevo = _intentar(t).whenComplete(() {
      _enCurso.remove(t);
    });
    _enCurso[t] = nuevo;
    return nuevo;
  }

  Future<_Intento> _intentar(Tesela t) async {
    if (_seSabeQueFalta(t)) return const _Intento.falta();

    final guardada = await _leer(t);
    if (guardada != null) {
      // Los telefonos que ya miraron esta zona tienen el cartel guardado
      // como si fuera una imagen: tambien se lo reconoce al leerlo.
      if (esRellenoEsri(guardada.bytes, etag: guardada.metadata.etag)) {
        _anotarFalta(t);
        return const _Intento.falta();
      }
      if (!guardada.metadata.isStale) {
        _anotarHay(t);
        return _Intento.con(guardada.bytes);
      }
    }

    // Hasta aca llega lo que no esta guardado, o esta vencido. Sin red se usa
    // la copia vencida si la hay: una imagen vieja del terreno sigue siendo
    // el terreno.
    final viejo = guardada?.bytes;
    _Intento sinRed() =>
        viejo != null ? _Intento.con(viejo) : const _Intento.sinSaber();

    if (!await _hayPaso()) return sinRed();
    if (!await _turno()) {
      return viejo != null ? _Intento.con(viejo) : const _Intento.sinTurno();
    }
    try {
      // Mientras esperaba el turno pudo fallar otro pedido y cortarse la red.
      if (_redCortada) return sinRed();

      final url = t.url(plantilla);
      final etag = guardada?.metadata.etag;
      final r = await _cliente
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': 'flutter_map ($paquete)',
              // "Solo si cambio": el satelite de una plantacion no cambia en
              // meses, y asi renovar una copia vencida no la vuelve a bajar.
              'If-None-Match': ?etag,
            },
          )
          .timeout(espera);
      // Contesto algo, lo que sea: la red anda.
      _redAnda();

      if (r.statusCode == 304 && guardada != null) {
        _anotarHay(t);
        _guardar(t, url, guardada.bytes, etag, soloFecha: true);
        return _Intento.con(guardada.bytes);
      }
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
        if (esRellenoEsri(r.bodyBytes, etag: r.headers['etag'])) {
          _anotarFalta(t);
          return const _Intento.falta();
        }
        _anotarHay(t);
        _guardar(t, url, r.bodyBytes, r.headers['etag']);
        return _Intento.con(r.bodyBytes);
      }
      if (r.statusCode == 404) {
        _anotarFalta(t);
        return const _Intento.falta();
      }
      // El servidor contesto otra cosa (saturado, caido): no dice nada sobre
      // si la imagen existe.
      return sinRed();
    } catch (_) {
      _redFallo();
      return sinRed();
    } finally {
      _soltar();
    }
  }

  /// La copia guardada de [t], de la memoria si se leyo hace poco y si no del
  /// disco. Nulo si no hay o si no se pudo leer.
  Future<CachedMapTile?> _leer(Tesela t) async {
    final aMano = _memoria.remove(t);
    if (aMano != null) {
      // Se vuelve a poner para que quede como la mas reciente.
      _memoria[t] = aMano;
      return aMano;
    }
    final cache = almacen();
    if (cache == null || !cache.isSupported) return null;
    try {
      final leida = await cache.getTile(t.url(plantilla));
      if (leida != null) _recordar(t, leida);
      return leida;
    } catch (_) {
      // Una copia ilegible es como no tenerla.
      return null;
    }
  }

  void _recordar(Tesela t, CachedMapTile copia) {
    _memoria.remove(t);
    _memoria[t] = copia;
    while (_memoria.length > _enMemoria) {
      _memoria.remove(_memoria.keys.first);
    }
  }

  /// Deja la imagen en el telefono, vigente por 60 dias. Con [soloFecha] la
  /// imagen ya estaba y no cambio: se le corre el vencimiento y nada mas.
  void _guardar(
    Tesela t,
    String url,
    Uint8List bytes,
    String? etag, {
    bool soloFecha = false,
  }) {
    final metadata = CachedMapTileMetadata(
      staleAt: DateTime.timestamp().add(const Duration(days: 60)),
      lastModified: null,
      etag: etag,
    );
    _recordar(t, (bytes: bytes, metadata: metadata));
    final cache = almacen();
    if (cache == null || !cache.isSupported) return;
    // Sin esperarla: guardar no puede demorar lo que se esta mirando.
    unawaited(
      cache
          .putTile(
            url: url,
            metadata: metadata,
            bytes: soloFecha ? null : bytes,
          )
          .catchError((Object _) {}),
    );
  }

  /// Si se puede salir a la red ahora.
  ///
  /// Con la red cortada, no. Vencida la pausa no salen todos a la vez a
  /// descubrir que sigue cortada: el primero sale a probar y los demas
  /// esperan lo que le pase a ese.
  Future<bool> _hayPaso() {
    if (_redCortada) return Future.value(false);
    if (_fallos == 0) return Future.value(true);
    final sonda = _sonda;
    if (sonda != null) return sonda.future;
    _sonda = Completer<bool>();
    return Future.value(true);
  }

  void _redAnda() {
    final volvio = _fallos > 0;
    _fallos = 0;
    _sinRedHasta = null;
    _sonda?.complete(true);
    _sonda = null;
    // Venia cortada y contesto: lo que quedo borroso puede salir a buscarse.
    if (volvio) _avisarQueVolvio();
  }

  void _redFallo() {
    // Los pedidos que salieron juntos fallan juntos: cuentan como un fallo,
    // no como seis, o la pausa saltaria al maximo de entrada.
    if (!_redCortada) {
      _fallos++;
      // 20 s, 40 s, 80 s... hasta el tope.
      final doblada = _fallos > 6 ? 6 : _fallos - 1;
      var pausa = pausaSinRed * (1 << doblada);
      if (pausa > pausaMaxima) pausa = pausaMaxima;
      _sinRedHasta = _reloj().add(pausa);
    }
    _sonda?.complete(false);
    _sonda = null;
  }

  /// Cuantos pedidos pueden esperar turno. Es mas o menos lo que entra en
  /// pantalla: lo que se pase es de zonas por las que el mapa ya paso de
  /// largo.
  static const _enEspera = 48;

  /// Espera el turno para salir a la red, y dice si llego. Los que esperan
  /// salen del mas nuevo al mas viejo: lo ultimo que se pidio es lo que se
  /// esta mirando ahora.
  ///
  /// Si hay demasiados esperando, el mas viejo se queda sin turno: moviendo
  /// el mapa rapido con poca senal, bajar despues las imagenes de por donde
  /// se paso es gastar datos en algo que ya nadie mira. Queda anotado como
  /// pendiente y se pide cuando se lo vuelva a ver.
  Future<bool> _turno() {
    if (_enVuelo < enParalelo) {
      _enVuelo++;
      return Future.value(true);
    }
    final turno = Completer<bool>();
    _cola.add(turno);
    if (_cola.length > _enEspera) _cola.removeAt(0).complete(false);
    return turno.future;
  }

  void _soltar() {
    if (_cola.isNotEmpty) {
      _cola.removeLast().complete(true);
    } else {
      _enVuelo--;
    }
  }

  /// Si ya se sabe, sin preguntar, que [t] no tiene imagen: porque falto ella,
  /// porque falto una de mas arriba que la contiene -si no hay imagen de la
  /// manzana, no la hay de la casa-, o porque en su zona ese nivel viene
  /// faltando entero.
  bool _seSabeQueFalta(Tesela t) {
    for (var s = 0; s <= 3 && s <= t.z; s++) {
      if (_noHay.contains(t.ancestro(s))) return true;
    }
    final bloque = _bloque(t);
    return (_faltanEnBloque[bloque] ?? 0) >= _faltasParaGeneralizar &&
        !_hayEnBloque.contains(bloque);
  }

  /// La zona de 16 x 16 teselas a la que pertenece [t]. Como es una tesela de
  /// cuatro niveles mas arriba, la clave es distinta para cada nivel.
  Tesela _bloque(Tesela t) => t.ancestro(4);

  void _anotarFalta(Tesela t) {
    // Un tope, para que una jornada entera mirando el mapa no acumule sin
    // fin. Vaciarlo solo cuesta volver a preguntar.
    if (_noHay.length > 20000) {
      _noHay.clear();
      _faltanEnBloque.clear();
    }
    if (_noHay.add(t)) {
      final bloque = _bloque(t);
      _faltanEnBloque[bloque] = (_faltanEnBloque[bloque] ?? 0) + 1;
    }
  }

  void _anotarHay(Tesela t) => _hayEnBloque.add(_bloque(t));
}

/// Como termino un intento por una tesela exacta.
class _Intento {
  const _Intento.con(Uint8List this.bytes) : sinSaber = false, sinTurno = false;

  /// Se sabe que no tiene imagen.
  const _Intento.falta() : bytes = null, sinSaber = false, sinTurno = false;

  /// No se pudo averiguar: sin red y sin copia.
  const _Intento.sinSaber() : bytes = null, sinSaber = true, sinTurno = false;

  /// No se pudo averiguar porque habia demasiados pedidos esperando.
  const _Intento.sinTurno() : bytes = null, sinSaber = true, sinTurno = true;

  final Uint8List? bytes;
  final bool sinSaber;
  final bool sinTurno;
}
