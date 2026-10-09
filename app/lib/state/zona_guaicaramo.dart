import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/acopios.dart';
import '../core/parcelas.dart';
import '../core/ubicacion.dart';
import '../core/ruteo.dart';
import '../core/vias.dart';
import '../core/zona.dart';
import 'ubicacion_provider.dart';

/// El perimetro de la plantacion de Guaicaramo, cargado del asset.
///
/// Se lee una vez por arranque y queda en memoria: son 16 KB y la respuesta se
/// consulta con cada fix del GPS, que en campo llega cada pocos segundos.
final zonaGuaicaramoProvider = FutureProvider<Zona>((ref) {
  return Zona.cargar('guaicaramo.json');
});

/// Por que el mapa de Guaicaramo esta habilitado o no.
///
/// Son cuatro estados y no un booleano a proposito. "No podes abrirlo" sin
/// decir por que es lo que hace que alguien reinstale la app en un lote: no
/// sabe si le falta permiso, si el GPS no engancho o si simplemente todavia no
/// llego al predio.
enum MotivoZona {
  /// Adentro del predio. El mapa se abre.
  dentro,

  /// El GPS funciona y la posicion cae afuera.
  fuera,

  /// Todavia no hay un fix. No es lo mismo que estar afuera.
  buscandoGps,

  /// Sin permiso de ubicacion o con la ubicacion apagada.
  sinUbicacion,

  /// El APK se compilo sin los datos del predio, que son confidenciales y no
  /// viven en el repositorio. Es un caso de compilacion, no de campo: alguien
  /// clono y compilo sin pedir las fuentes a coordinacion.
  sinDatos,
}

class EstadoZona {
  const EstadoZona({
    required this.motivo,
    this.metrosAlBorde,
    this.detalle,
    this.recordadoDe,
  });

  final MotivoZona motivo;

  /// A que distancia queda el borde del predio, si esta afuera y se sabe.
  final double? metrosAlBorde;

  /// El motivo en castellano cuando falta el permiso: los tres modos de fallar
  /// piden acciones distintas de la persona.
  final String? detalle;

  /// Cuando el mapa se habilita por haber estado adentro hace poco, y no por
  /// un fix de ahora. Nulo si la respuesta es del GPS en vivo.
  final DateTime? recordadoDe;

  bool get habilitado => motivo == MotivoZona.dentro;

  /// Lo que se muestra debajo del nombre del mapa.
  String get explicacion {
    switch (motivo) {
      case MotivoZona.dentro:
        if (recordadoDe != null) {
          return 'Estabas en la plantacion. Buscando senal GPS...';
        }
        return 'Estas en la plantacion';
      case MotivoZona.fuera:
        final m = metrosAlBorde;
        if (m == null) return 'Estas fuera de la plantacion';
        if (m < 1000) return 'A ${m.toStringAsFixed(0)} m de la plantacion';
        return 'A ${(m / 1000).toStringAsFixed(1)} km de la plantacion';
      case MotivoZona.buscandoGps:
        return 'Buscando senal GPS...';
      case MotivoZona.sinUbicacion:
        return detalle ?? 'Sin permiso de ubicacion';
      case MotivoZona.sinDatos:
        return 'Este APK se compilo sin los datos del predio';
    }
  }
}

/// Cuanto alrededor del perimetro se sigue considerando "en la plantacion".
///
/// El perimetro son los lotes con 50 m de margen, y deja afuera todo lo que no
/// es lote: el centro administrativo, la planta, los campamentos y las vias
/// entre sectores, que quedan hasta un par de kilometros del lote mas cercano.
/// Con el margen viejo el mapa no abria justo ahi, adentro del predio.
const margenPlantacionM = 3000.0;

/// Por cuanto tiempo vale haber estado adentro mientras el GPS no engancha.
///
/// En las zonas apartadas, sin red, el primer fix puede tardar minutos o no
/// llegar bajo palma. Si hace unas horas el telefono estuvo en la plantacion,
/// sigue en ella: no se le puede pedir a alguien que salga a buscar cielo
/// abierto para abrir el mapa de donde esta parado.
const vigenciaRecuerdoAdentro = Duration(hours: 24);

/// La ultima vez que el GPS en vivo ubico el telefono en la plantacion.
///
/// Se guarda en el telefono y se lee una vez al arrancar. Solo se usa mientras
/// no hay fix: en cuanto el GPS responde, manda el GPS.
final ultimaVezAdentroProvider = NotifierProvider<UltimaVezAdentro, DateTime?>(
  UltimaVezAdentro.new,
);

class UltimaVezAdentro extends Notifier<DateTime?> {
  static const _clave = 'zona.guaicaramo.ultimaVezAdentro';

  DateTime? _escrita;

  @override
  DateTime? build() {
    _leer();
    return null;
  }

  Future<void> _leer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_clave);
      if (ms == null) return;
      final guardada = DateTime.fromMillisecondsSinceEpoch(ms);
      if (state == null || guardada.isAfter(state!)) state = guardada;
    } catch (_) {
      // Sin el recuerdo se espera al GPS, como antes.
    }
  }

  /// Anota que ahora mismo esta adentro.
  ///
  /// No cambia el estado del provider: se llama mientras se calcula otro
  /// provider, y Riverpod no deja tocar estado ahi. Lo que importa es que quede
  /// en disco para el proximo arranque; en esta sesion el GPS ya respondio.
  void anotar() {
    final ahora = DateTime.now();
    final antes = _escrita;
    // Una escritura por minuto basta: el fix llega cada segundo.
    if (antes != null && ahora.difference(antes) < const Duration(minutes: 1)) {
      return;
    }
    _escrita = ahora;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt(_clave, ahora.millisecondsSinceEpoch))
        .catchError((_) => false);
  }
}

/// Si el telefono esta parado adentro de Guaicaramo, ahora mismo.
///
/// Se recalcula con cada fix. Mientras el GPS no engancha se acepta haber
/// estado adentro en las ultimas [vigenciaRecuerdoAdentro]; un fix que diga
/// afuera manda siempre sobre ese recuerdo.
final estadoGuaicaramoProvider = Provider.autoDispose<EstadoZona>((ref) {
  final zona = ref.watch(zonaGuaicaramoProvider);
  final posicion = ref.watch(posicionProvider);
  final recuerdo = ref.watch(ultimaVezAdentroProvider);

  // El asset no esta: este APK se compilo sin los datos del predio. Se dice
  // asi y no "buscando GPS", que dejaria a alguien esperando en un lote una
  // respuesta que no va a llegar nunca.
  if (zona.hasError) {
    return const EstadoZona(motivo: MotivoZona.sinDatos);
  }

  EstadoZona buscando() {
    if (recuerdo != null &&
        DateTime.now().difference(recuerdo) < vigenciaRecuerdoAdentro) {
      return EstadoZona(motivo: MotivoZona.dentro, recordadoDe: recuerdo);
    }
    return const EstadoZona(motivo: MotivoZona.buscandoGps);
  }

  // Mientras el asset se lee del disco se muestra lo mismo que sin fix: dura
  // milisegundos y no merece un estado propio en la pantalla.
  final perimetro = zona.valueOrNull;
  if (perimetro == null) return buscando();

  return posicion.when(
    data: (p) {
      final punto = PuntoLatLon(lat: p.latitude, lon: p.longitude);
      if (perimetro.cerca(punto, _margenSegunPrecision(p))) {
        if (!Ubicacion.esDeCache(p)) {
          ref.read(ultimaVezAdentroProvider.notifier).anotar();
        }
        return const EstadoZona(motivo: MotivoZona.dentro);
      }
      // La ultima conocida del telefono dice afuera, pero puede ser de antes
      // de llegar. Mientras el GPS en vivo no conteste, vale el recuerdo.
      if (Ubicacion.esDeCache(p)) {
        final b = buscando();
        if (b.habilitado) return b;
      }
      return EstadoZona(
        motivo: MotivoZona.fuera,
        metrosAlBorde: perimetro.metrosAlBorde(punto) - margenPlantacionM,
      );
    },
    loading: buscando,
    error: (e, _) => EstadoZona(
      motivo: MotivoZona.sinUbicacion,
      detalle: e is PermisoUbicacionDenegado ? e.motivo : null,
    ),
  );
});

/// El margen, mas lo que el propio fix admite no saber. Un fix de red con
/// 500 m de error en el borde no puede dejar a alguien afuera.
double _margenSegunPrecision(Position p) =>
    margenPlantacionM + (p.accuracy.isFinite ? p.accuracy : 0);

/// Las vias de un predio, leidas del asset.
///
/// `family` por nombre de archivo para que el dia que haya un segundo predio no
/// haya que tocar nada: la pantalla del mapa pide el suyo. Se cachea mientras
/// haya alguien mirandolo; volver a entrar al mapa no vuelve a parsear 353 KB.
final viasPredioProvider = FutureProvider.family<ViasPredio, String>((
  ref,
  archivo,
) {
  return ViasPredio.cargar(archivo);
});

/// Los lotes de un predio (bloques y parcelas), leidos del asset.
final parcelasPredioProvider = FutureProvider.family<ParcelasPredio, String>((
  ref,
  archivo,
) {
  return ParcelasPredio.cargar(archivo);
});

/// Los acopios de un predio, leidos del asset.
final acopiosPredioProvider = FutureProvider.family<AcopiosPredio, String>((
  ref,
  archivo,
) {
  return AcopiosPredio.cargar(archivo);
});

/// La red vial ruteable de un predio: el grafo que responde "por donde se llega
/// manejando hasta este punto".
///
/// Se arma sobre las vias ya cargadas, asi que no vuelve a leer el asset.
/// Armarlo cuesta unas decimas de segundo -son 12.000 cruces- y por eso este
/// provider **no se mira al abrir el mapa**: se pide recien cuando alguien
/// marca su primer destino, que es un momento en el que la pantalla ya esta
/// diciendo "calculando". Despues queda en memoria y las rutas siguientes
/// salen en milisegundos.
final redVialProvider = FutureProvider.family<RedVial, String>((
  ref,
  archivo,
) async {
  final vias = await ref.watch(viasPredioProvider(archivo).future);
  // Fuera del hilo de la interfaz: son unas decimas de segundo de calculo, y
  // ocurren mientras la pantalla dice "calculando". Si se hicieran donde corre
  // la pantalla, ese cartel se quedaria congelado sin siquiera animarse, que
  // es la forma exacta de que parezca que la app se colgo.
  return compute(RedVial.construir, vias);
});
