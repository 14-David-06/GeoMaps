import 'package:geolocator/geolocator.dart';

/// El GPS: permisos, lecturas y los dos filtros que hacen util un trazado.
///
/// Los filtros no son cosmetica:
///
/// - **Filtro de precision.** Un fix con 30 m de error bajo los arboles no
///   describe un lindero. Descartarlo y contarlo permite que la pantalla diga
///   "bajo el dosel no hay senal, sali al claro" en vez de dibujar un poligono
///   que parece bueno y no lo es.
/// - **Filtro de distancia minima.** Parado hablando, el GPS entrega puntos que
///   saltan unos metros. Sin el filtro, diez minutos de conversacion agregan
///   cientos de vertices de ruido al recorrido.
class Ubicacion {
  /// Metros de error por encima de los cuales un punto no sirve para marcar un
  /// vertice. No bloquea nada: avisa.
  static const precisionUtilM = 10.0;

  /// Pide los permisos y explica en castellano que falto.
  ///
  /// Devuelve el motivo y no un booleano pelado porque los tres modos de fallar
  /// exigen acciones distintas de la persona, y un "sin permiso" generico la
  /// deja sin saber cual.
  static Future<ResultadoPermiso> pedirPermisos() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const ResultadoPermiso(
        false,
        'La ubicacion del telefono esta apagada. Activala para ver donde estas.',
      );
    }

    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }

    if (permiso == LocationPermission.deniedForever) {
      return const ResultadoPermiso(
        false,
        'El permiso de ubicacion quedo denegado para siempre. Hay que '
        'habilitarlo en los ajustes del telefono.',
      );
    }
    if (permiso == LocationPermission.denied) {
      return const ResultadoPermiso(
        false,
        'Sin permiso de ubicacion no se puede saber donde estas en el mapa.',
      );
    }
    return const ResultadoPermiso(true, null);
  }

  /// Flujo de posiciones ya filtrado por distancia.
  ///
  /// `distanceFilter` en metros es lo que evita el ruido de estar parado. Va
  /// bajo (3 m) porque esta pantalla solo muestra la posicion; para grabar un
  /// trazado el filtro sube.
  ///
  /// Arranca con la ultima posicion que el telefono tenga guardada, si es de
  /// las ultimas [antiguedadMaximaCache]. Sin internet no hay GPS asistido y
  /// el primer fix puede tardar minutos; mientras tanto es mejor ver el mapa
  /// donde uno estaba -marcado con [esDeCache]- que una pantalla
  /// "buscando" sin fin.
  ///
  /// El proveedor se elige con [soloChipGps]:
  ///
  /// - **Fusionado** (por defecto): el de Google Play Services. Sin red usa el
  ///   chip GPS igual, y con red o wifi da una posicion aproximada en segundos
  ///   aun bajo techo. Pedir solo el chip -como se hacia antes- dejaba el mapa
  ///   sin ningun fix nuevo adentro de una oficina o bajo palma cerrada, y la
  ///   posicion solo "se actualizaba" al reiniciar la app, que volvia a leer la
  ///   ultima conocida.
  /// - **Solo chip** (`LocationManager`): para el telefono raro donde el
  ///   fusionado no entrega nada. La pantalla del mapa alterna entre los dos si
  ///   pasa un rato sin fixes.
  static Stream<Position> flujo({
    int distanciaMinimaM = 3,
    bool soloChipGps = false,
  }) async* {
    final cache = await ultimaConocida();
    if (cache != null) {
      _deCache[cache] = true;
      yield cache;
    }

    yield* Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanciaMinimaM,
        // Un fix por segundo: es lo que hace que la flecha y el mapa avancen
        // seguido al ir en la camioneta, en vez de dar saltos.
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: soloChipGps,
      ),
    );
  }

  /// Hasta que edad sirve la posicion guardada para arrancar. Mas vieja que
  /// esto puede ser de otra finca y confunde mas de lo que ayuda.
  static const antiguedadMaximaCache = Duration(hours: 2);

  static Future<Position?> ultimaConocida() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      if (p == null) return null;
      if (DateTime.now().difference(p.timestamp) > antiguedadMaximaCache) {
        return null;
      }
      return p;
    } catch (_) {
      // La cache es un extra: si falla, se espera el GPS como antes.
      return null;
    }
  }

  /// Marca las posiciones que salieron de la cache y no del GPS en vivo.
  ///
  /// Va marcada y no deducida de la hora del fix: parado, el filtro de
  /// distancia no entrega puntos nuevos, y un fix real de hace un minuto no es
  /// una posicion vieja.
  static final _deCache = Expando<bool>();

  static bool esDeCache(Position p) => _deCache[p] ?? false;

  /// "hace 3 min", "hace 1 h". Para decir de cuando es una posicion vieja.
  static String hace(Position p) {
    final d = DateTime.now().difference(p.timestamp);
    if (d.inMinutes < 1) return 'hace ${d.inSeconds} s';
    if (d.inHours < 1) return 'hace ${d.inMinutes} min';
    return 'hace ${d.inHours} h';
  }

  // TODO: flujoParaTrazado(...) con los contadores de descartados por cercania
  //       y por precision, que son los que se muestran mientras se captura.
}

class ResultadoPermiso {
  const ResultadoPermiso(this.concedido, this.motivo);

  final bool concedido;
  final String? motivo;
}
