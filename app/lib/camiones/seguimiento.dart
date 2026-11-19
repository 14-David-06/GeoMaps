import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/api_client.dart';
import '../core/geo.dart';

/// Un paso de la vuelta: cuando paso y donde estaba el camion.
///
/// Se guarda con el recorrido -en las propiedades de su GeoJSON- y viaja al
/// backend con las mismas llaves, asi que lo que se ve en el archivo y lo que
/// queda en la tabla de seguimiento es el mismo dato.
class Movimiento {
  const Movimiento({
    required this.en,
    this.punto,
    this.precisionM,
    this.distanciaM,
    this.verificado = true,
  });

  static Movimiento? deJson(Object? j) {
    if (j is! Map) return null;
    final en = DateTime.tryParse('${j['en']}');
    if (en == null) return null;
    final lat = (j['lat'] as num?)?.toDouble();
    final lon = (j['lon'] as num?)?.toDouble();
    return Movimiento(
      en: en,
      punto: lat == null || lon == null ? null : PuntoGeo(lat, lon),
      precisionM: (j['precision_m'] as num?)?.toDouble(),
      distanciaM: (j['distancia_m'] as num?)?.toDouble(),
      verificado: j['verificado'] as bool? ?? true,
    );
  }

  final DateTime en;

  /// Nulo si no habia GPS en ese momento.
  final PuntoGeo? punto;
  final double? precisionM;

  /// A cuanto quedo de donde tenia que estar: de los vagones al llegar, del
  /// punto de salida al volver y al finalizar.
  final double? distanciaM;

  /// Falso si lo marco la persona y no el GPS.
  final bool verificado;

  Map<String, Object?> aJson() => {
    'en': en.toUtc().toIso8601String(),
    if (punto != null) 'lat': _redondeo(punto!.latitud, 6),
    if (punto != null) 'lon': _redondeo(punto!.longitud, 6),
    if (precisionM != null) 'precision_m': _redondeo(precisionM!, 1),
    if (distanciaM != null) 'distancia_m': _redondeo(distanciaM!, 1),
    if (!verificado) 'verificado': false,
  };

  static double _redondeo(double v, int decimales) =>
      double.parse(v.toStringAsFixed(decimales));
}

/// En que parte de la vuelta va el camion.
enum EtapaVuelta {
  /// Va por los vagones: todavia no llego al acopio.
  yendo,

  /// Ya estuvo en el acopio: le falta volver al punto de salida.
  volviendo,

  /// Fue y volvio: puede finalizar.
  deVuelta,
}

/// Las reglas de una vuelta: ir hasta los vagones, volver, y recien ahi
/// finalizar.
///
/// **Por que existen.** Una vuelta tomada que nadie finaliza -o que se
/// "finaliza" sin haber ido- deja la planilla diciendo que esos vagones ya
/// estan en camino cuando siguen en el lote. La regla es que el camion sale
/// de donde esta al tomarla, **tiene que pasar por el acopio** y **volver al
/// punto de salida**; mientras no la finalice no puede tomar otra.
///
/// Todo se decide con el GPS del telefono y sin senal: el lote no la tiene. El
/// estado no vive en memoria sino en las propiedades del recorrido que se esta
/// grabando, que se guardan en el telefono: si la app se cierra a mitad de
/// camino, al volver sigue sabiendo que ya habia llegado.
class SeguimientoVuelta {
  const SeguimientoVuelta({
    this.vueltaId,
    this.viaje,
    this.punto,
    this.salida,
    this.llegada,
    this.regreso,
  });

  /// Lee el estado de las propiedades de un recorrido.
  factory SeguimientoVuelta.de(Map<String, Object?> p) {
    final d = p['destino'];
    return SeguimientoVuelta(
      vueltaId: p['vuelta_id'] as String?,
      viaje: p['viaje'] as String?,
      // [lon, lat], como todo en el GeoJSON.
      punto: d is List && d.length >= 2
          ? PuntoGeo((d[1] as num).toDouble(), (d[0] as num).toDouble())
          : null,
      salida: Movimiento.deJson(p['salida']),
      llegada: Movimiento.deJson(p['llegada']),
      regreso: Movimiento.deJson(p['regreso']),
    );
  }

  /// A cuanto del acopio cuenta como haber llegado. Los acopios quedan sobre
  /// la via y el camion engancha ahi mismo; cien metros cubren el error del
  /// GPS bajo palma sin confundirlo con el acopio de al lado, que casi nunca
  /// esta a menos de 140.
  static const radioLlegadaM = 100.0;

  /// A cuanto del punto de salida cuenta como haber vuelto. Mas ancho que el
  /// de llegada: un patio es grande y nadie estaciona dos veces en la misma
  /// baldosa.
  static const radioRegresoM = 150.0;

  /// Un fix con mas error que esto no decide nada: diria "llegaste" a
  /// alguien que esta a media cuadra.
  static const precisionMaximaM = 60.0;

  /// Cuando el acopio no tiene coordenada la llegada se marca a mano, pero
  /// no desde el patio: hay que haberse alejado esto del punto de salida.
  static const alejarseParaMarcarM = 300.0;

  /// El renglon de la planilla. Nulo si el recorrido no es una vuelta.
  final String? vueltaId;

  /// El codigo del viaje en el seguimiento del servidor. Nulo si el servidor
  /// no lo esta llevando.
  final String? viaje;

  /// Donde estan los vagones. Nulo si el acopio no tiene coordenada.
  final PuntoGeo? punto;

  final Movimiento? salida;
  final Movimiento? llegada;
  final Movimiento? regreso;

  bool get esVuelta => vueltaId != null;

  EtapaVuelta get etapa => llegada == null
      ? EtapaVuelta.yendo
      : regreso == null
      ? EtapaVuelta.volviendo
      : EtapaVuelta.deVuelta;

  bool get puedeFinalizar => etapa == EtapaVuelta.deVuelta;

  /// Se devuelve a la lista solo antes de llegar: despues los vagones ya
  /// estan enganchados y esa vuelta se termina.
  bool get puedeDevolver => llegada == null;

  /// Sin coordenada el GPS no puede decir "llegaste": lo marca la persona.
  bool get llegadaAMano => punto == null && llegada == null;

  double? faltaAlPunto(PuntoGeo? donde) =>
      donde == null || punto == null ? null : distanciaM(donde, punto!);

  double? faltaALaSalida(PuntoGeo? donde) {
    final s = salida?.punto;
    return donde == null || s == null ? null : distanciaM(donde, s);
  }

  /// Lo que cambia con esta posicion, o nulo si no cambia nada.
  ///
  /// El primer fix bueno fija el punto de salida si todavia no lo habia -se
  /// tomo la vuelta antes de que el GPS enganchara-. Despues: llegar es
  /// entrar al radio del acopio, y volver es entrar al del punto de salida
  /// habiendo llegado antes.
  Map<String, Object?>? alFix({
    required PuntoGeo donde,
    required double precisionM,
    required DateTime hora,
  }) {
    if (!esVuelta || precisionM > precisionMaximaM) return null;
    final cambios = <String, Object?>{};

    var desde = salida;
    if (desde == null) {
      desde = Movimiento(en: hora, punto: donde, precisionM: precisionM);
      cambios['salida'] = desde.aJson();
    }

    var llego = llegada != null;
    final acopio = punto;
    if (!llego && acopio != null) {
      final falta = distanciaM(donde, acopio);
      if (falta <= radioLlegadaM) {
        llego = true;
        cambios['llegada'] = Movimiento(
          en: hora,
          punto: donde,
          precisionM: precisionM,
          distanciaM: falta,
        ).aJson();
      }
    }

    final origen = desde.punto;
    if (llego && regreso == null && origen != null) {
      final falta = distanciaM(donde, origen);
      if (falta <= radioRegresoM) {
        cambios['regreso'] = Movimiento(
          en: hora,
          punto: donde,
          precisionM: precisionM,
          distanciaM: falta,
        ).aJson();
      }
    }
    return cambios.isEmpty ? null : cambios;
  }

  /// Revisa lo ya grabado al retomar un viaje que se corto: si la linea paso
  /// por el acopio mientras la app estaba cerrada o sin pantalla, la llegada
  /// cuenta igual. La vuelta al punto de salida no se revisa aca: la dice la
  /// posicion de ahora, con el primer fix.
  Map<String, Object?>? alRetomar(List<PuntoGeo> linea, DateTime ahora) {
    if (!esVuelta || linea.isEmpty) return null;
    final cambios = <String, Object?>{};
    if (salida == null) {
      cambios['salida'] = Movimiento(en: ahora, punto: linea.first).aJson();
    }
    final acopio = punto;
    if (llegada == null && acopio != null) {
      for (final p in linea) {
        final falta = distanciaM(p, acopio);
        if (falta <= radioLlegadaM) {
          cambios['llegada'] = Movimiento(
            en: ahora,
            punto: p,
            distanciaM: falta,
          ).aJson();
          break;
        }
      }
    }
    return cambios.isEmpty ? null : cambios;
  }

  /// Por que todavia no se puede marcar la llegada a mano, o nulo si se
  /// puede. Solo aplica cuando el acopio no tiene coordenada.
  String? porQueNoMarcar(PuntoGeo? donde) {
    final falta = faltaALaSalida(donde);
    if (falta == null) {
      return 'Sin GPS no se puede marcar la llegada. Revisa que la ubicacion '
          'del telefono este prendida.';
    }
    if (falta < alejarseParaMarcarM) {
      return 'Todavia estas en el punto de salida. Marca la llegada cuando '
          'estes en los vagones.';
    }
    return null;
  }

  /// La llegada marcada por la persona, para un acopio sin coordenada.
  Map<String, Object?> marcarLlegada({
    required PuntoGeo donde,
    double? precisionM,
    required DateTime hora,
  }) => {
    'llegada': Movimiento(
      en: hora,
      punto: donde,
      precisionM: precisionM,
      verificado: false,
    ).aJson(),
  };

  /// El paso de finalizar, con a cuanto del punto de salida se hizo.
  Movimiento fin({PuntoGeo? donde, double? precisionM, required DateTime hora}) =>
      Movimiento(
        en: hora,
        punto: donde,
        precisionM: precisionM,
        distanciaM: faltaALaSalida(donde),
      );

  /// Lo que se le manda al backend: todo lo que se sabe del viaje hasta
  /// ahora, no solo lo nuevo. Nulo si el recorrido no tiene viaje que avisar.
  static Map<String, Object?>? cuerpo(
    Map<String, Object?> propiedades, {
    double? recorridoM,
    String? trazado,
  }) {
    if (propiedades['viaje'] is! String) return null;
    return {
      for (final paso in const ['salida', 'llegada', 'regreso', 'fin'])
        if (propiedades[paso] is Map) paso: propiedades[paso],
      if (recorridoM != null) 'recorrido_m': recorridoM.roundToDouble(),
      'trazado': ?trazado,
    };
  }
}

/// Avisa al backend por donde va la vuelta. Nunca falla hacia afuera: en el
/// lote no hay senal, y lo que no llego ahora viaja despues con el recorrido.
Future<void> avisarSeguimiento(
  ApiClient api,
  Map<String, Object?> propiedades, {
  double? recorridoM,
  String? trazado,
}) async {
  final codigo = propiedades['viaje'];
  final cuerpo = SeguimientoVuelta.cuerpo(
    propiedades,
    recorridoM: recorridoM,
    trazado: trazado,
  );
  if (codigo is! String || cuerpo == null) return;
  try {
    await api.seguimientoViaje(codigo, cuerpo);
  } catch (_) {
    // Sin senal, o un backend anterior: sube despues con el recorrido.
  }
}

/// Mira cada posicion de un viaje de camion mientras se graba.
///
/// Es lo que el grabador llama con cada fix: si el recorrido es una vuelta,
/// devuelve lo que hay que anotarle -llego, volvio- y de paso le avisa al
/// backend, por si justo ahi hay senal.
class VigiaDeVueltas {
  const VigiaDeVueltas({this.avisar, this.decir});

  /// Se llama con las propiedades ya actualizadas cuando el camion llego o
  /// volvio.
  final void Function(Map<String, Object?> propiedades)? avisar;

  /// Se llama con la frase que hay que decirle al conductor en el momento en
  /// que llega a los vagones o vuelve al punto de salida. El conductor va
  /// manejando y con el telefono en el soporte o en la guantera: que la
  /// pantalla cambie de "1 de 3" a "2 de 3" no le avisa nada.
  final void Function(String frase)? decir;

  /// Lo que se dice al entrar al radio de los vagones.
  static const alLlegar =
      'Llegaste a los vagones. Engánchalos y vuelve al punto de salida.';

  /// Lo que se dice al volver al punto de salida habiendo ido.
  static const alVolver =
      'Ya estás en el punto de salida. Puedes finalizar la vuelta.';

  Map<String, Object?>? alFix(Position p, Map<String, Object?> propiedades) {
    final cambios = SeguimientoVuelta.de(propiedades).alFix(
      donde: PuntoGeo(p.latitude, p.longitude),
      precisionM: p.accuracy,
      hora: p.timestamp,
    );
    _avisarSi(propiedades, cambios);
    // Solo con una posicion de ahora. Al retomar un viaje que se corto, la
    // llegada se reconstruye de lo grabado y decir "llegaste" seria tarde.
    if (cambios != null) {
      if (cambios.containsKey('regreso')) {
        decir?.call(alVolver);
      } else if (cambios.containsKey('llegada')) {
        decir?.call(alLlegar);
      }
    }
    return cambios;
  }

  Map<String, Object?>? alRetomar(
    List<PuntoGeo> linea,
    Map<String, Object?> propiedades,
  ) {
    final cambios = SeguimientoVuelta.de(
      propiedades,
    ).alRetomar(linea, DateTime.now());
    _avisarSi(propiedades, cambios);
    return cambios;
  }

  void _avisarSi(
    Map<String, Object?> propiedades,
    Map<String, Object?>? cambios,
  ) {
    if (cambios == null) return;
    if (cambios.containsKey('llegada') || cambios.containsKey('regreso')) {
      avisar?.call({...propiedades, ...cambios});
    }
  }
}
