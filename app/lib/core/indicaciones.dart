import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'ruteo.dart';

/// Para donde se dobla en un cruce.
enum Giro {
  izquierda('gira a la izquierda'),
  derecha('gira a la derecha'),
  vuelta('da la vuelta');

  const Giro(this.frase);

  /// Como se dice, en minuscula: va tambien en medio de una frase.
  final String frase;
}

/// Un cruce de la ruta donde hay que doblar.
class Maniobra {
  const Maniobra({
    required this.giro,
    required this.punto,
    required this.faltanAlFinalM,
  });

  final Giro giro;
  final LatLng punto;

  /// Cuanto queda de ruta desde este cruce hasta el destino. Se compara con
  /// lo que le falta a quien va en camino: la diferencia es lo que le falta
  /// para llegar al cruce.
  final double faltanAlFinalM;
}

/// Los giros de una ruta, en el orden en que se encuentran.
///
/// Solo salen de los **cruces** -donde se juntan tres vias o mas-, que son
/// los unicos lugares donde hay que decidir. Un codo de la misma via, por
/// cerrado que sea, no se anuncia: no hay para donde equivocarse, y una voz
/// que habla en cada curva es una voz que se deja de escuchar.
///
/// Y de los cruces, solo donde de verdad se dobla. Seguir derecho no se dice.
List<Maniobra> maniobrasDe(Ruta ruta) {
  final linea = ruta.completa;
  // Lo que falta hasta el final desde cada punto de la linea.
  final faltan = List<double>.filled(linea.length, 0);
  for (var i = linea.length - 2; i >= 0; i--) {
    faltan[i] = faltan[i + 1] + _metros(linea[i], linea[i + 1]);
  }

  final maniobras = <Maniobra>[];
  for (final cruce in ruta.cruces) {
    // `cruces` cuenta sobre `porLaVia`; en la linea completa hay un punto
    // antes, que es de donde se salio.
    final i = cruce + 1;
    if (i <= 0 || i >= linea.length - 1) continue;

    final llega = _rumbo(_atras(linea, i), linea[i]);
    final sale = _rumbo(linea[i], _adelante(linea, i));
    if (llega == null || sale == null) continue;

    // De -180 a 180: positivo es a la derecha, como gira un reloj.
    var cambio = sale - llega;
    while (cambio > 180) {
      cambio -= 360;
    }
    while (cambio <= -180) {
      cambio += 360;
    }

    final Giro giro;
    if (cambio.abs() < anguloMinimo) {
      continue;
    } else if (cambio.abs() >= anguloDeVuelta) {
      giro = Giro.vuelta;
    } else {
      giro = cambio > 0 ? Giro.derecha : Giro.izquierda;
    }
    maniobras.add(
      Maniobra(giro: giro, punto: linea[i], faltanAlFinalM: faltan[i]),
    );
  }
  return maniobras;
}

/// Por debajo de esto no es un giro: es seguir por la via, que hace una curva
/// o cruza otra en diagonal.
const anguloMinimo = 35.0;

/// De aca en mas es volver por donde se vino.
const anguloDeVuelta = 150.0;

/// Cuanto se mira antes y despues del cruce para saber el rumbo. Las vias
/// estan dibujadas a mano y el vertice del cruce nunca cae justo: medido con
/// el vertice de al lado, a un metro, un cruce derecho da cualquier angulo.
const _miraM = 20.0;

LatLng _atras(List<LatLng> linea, int i) {
  var resto = _miraM;
  for (var k = i; k > 0; k--) {
    final tramo = _metros(linea[k - 1], linea[k]);
    if (tramo >= resto) return _entre(linea[k], linea[k - 1], resto / tramo);
    resto -= tramo;
  }
  return linea.first;
}

LatLng _adelante(List<LatLng> linea, int i) {
  var resto = _miraM;
  for (var k = i; k < linea.length - 1; k++) {
    final tramo = _metros(linea[k], linea[k + 1]);
    if (tramo >= resto) return _entre(linea[k], linea[k + 1], resto / tramo);
    resto -= tramo;
  }
  return linea.last;
}

LatLng _entre(LatLng a, LatLng b, double t) => LatLng(
  a.latitude + (b.latitude - a.latitude) * t,
  a.longitude + (b.longitude - a.longitude) * t,
);

/// El rumbo de [a] hacia [b] en grados, con el norte en 0 y creciendo como el
/// reloj. Nulo si son el mismo punto.
double? _rumbo(LatLng a, LatLng b) {
  final dx = (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180);
  final dy = b.latitude - a.latitude;
  if (dx == 0 && dy == 0) return null;
  return math.atan2(dx, dy) * 180 / math.pi;
}

double _metros(LatLng a, LatLng b) => distanciaM(
  PuntoGeo(a.latitude, a.longitude),
  PuntoGeo(b.latitude, b.longitude),
);

/// Lo que hay que ir diciendo mientras alguien sigue una ruta.
///
/// Es para quien maneja con las manos en el volante y para quien no alcanza
/// a leer la pantalla: la mayoria de quienes usan la app en campo son
/// personas mayores que no ven bien. Con cada posicion se le pregunta que
/// decir, y casi siempre contesta que nada.
///
/// Se dice poco a proposito:
///
/// - Cada giro, dos veces: con tiempo para prepararse ([avisoLejosM]) y al
///   llegar al cruce ([avisoCercaM]).
/// - Cuanto falta, en tres o cuatro hitos del camino.
/// - Donde termina la via, si el punto queda adentro de un lote.
///
/// No sabe nada de voces ni de pantallas: entrega frases, y por eso se puede
/// probar entera sin telefono.
class GuiaRuta {
  GuiaRuta(this.ruta, {this.destino}) : maniobras = maniobrasDe(ruta) {
    // Un hito que ya quedo atras al empezar -o que esta ahi nomas- no se
    // anuncia: quien sale a 280 m del destino no tiene que oir, a los ochenta
    // metros, "faltan 200".
    for (final hito in _hitos) {
      if (ruta.metrosTotales < hito * 1.5) _hitosDichos.add(hito);
    }
  }

  final Ruta ruta;

  /// Como se llama a donde se va, si tiene nombre.
  final String? destino;

  final List<Maniobra> maniobras;

  /// A cuanto del cruce se avisa el giro por primera vez. A la velocidad de
  /// un camion en plantacion son entre diez y veinte segundos.
  static const avisoLejosM = 150.0;

  /// A cuanto del cruce se repite, ya para doblar.
  static const avisoCercaM = 35.0;

  /// Si entre el aviso largo y el corto quedaria menos que esto, se da uno
  /// solo: dos frases seguidas sobre el mismo giro se pisan.
  static const _entreAvisosM = 70.0;

  /// Los puntos del camino donde se dice cuanto falta.
  static const _hitos = [2000.0, 1000.0, 500.0, 200.0];

  final _dichoLejos = <Maniobra>{};
  final _dichoCerca = <Maniobra>{};
  final _hitosDichos = <double>{};
  bool _dichoFinDeVia = false;

  /// Lo que se dice al iniciar la ruta: a donde se va y cuanto es.
  String alEmpezar() {
    final a = destino == null ? 'al punto marcado' : 'a $destino';
    return 'Ruta $a. ${_mayuscula(decirDistancia(ruta.metrosTotales))}, '
        '${decirMinutos(ruta.minutos)}.';
  }

  /// Lo que se dice al llegar.
  String alLlegar() =>
      destino == null ? 'Llegaste al punto marcado.' : 'Llegaste a $destino.';

  /// Lo que se dice cuando se pierde la ruta y hay que buscar otra.
  static const alDesviarse = 'Te saliste de la ruta. Busco otro camino.';

  /// Lo que hay que decir ahora, o nulo si no hay nada que decir.
  String? alAvanzar(ProgresoRuta progreso) {
    final falta = progreso.metrosRestantes;

    // El primer giro que todavia queda adelante.
    Maniobra? proxima;
    Maniobra? siguiente;
    for (var i = 0; i < maniobras.length; i++) {
      final m = maniobras[i];
      // Con margen: el GPS llega al cruce unos metros antes o despues.
      if (falta - m.faltanAlFinalM < -15) continue;
      proxima = m;
      if (i + 1 < maniobras.length) siguiente = maniobras[i + 1];
      break;
    }

    if (proxima != null) {
      final alCruce = falta - proxima.faltanAlFinalM;
      if (alCruce <= avisoCercaM && _dichoCerca.add(proxima)) {
        _dichoLejos.add(proxima);
        var frase = _mayuscula(proxima.giro.frase);
        // Dos giros pegados se dicen juntos: despues del primero no hay
        // tiempo de avisar el segundo.
        if (siguiente != null &&
            proxima.faltanAlFinalM - siguiente.faltanAlFinalM <=
                _entreAvisosM) {
          _dichoLejos.add(siguiente);
          _dichoCerca.add(siguiente);
          frase = '$frase, y enseguida ${siguiente.giro.frase}';
        }
        return '$frase.';
      }
      if (alCruce <= avisoLejosM &&
          alCruce > _entreAvisosM &&
          _dichoLejos.add(proxima)) {
        return 'En ${decirDistancia(alCruce)}, ${proxima.giro.frase}.';
      }
    }

    // Donde se deja la via para seguir a pie, si el punto queda lote adentro.
    final aPie = ruta.metrosDesdeLaVia;
    if (!_dichoFinDeVia && aPie > 30 && falta <= aPie + 20) {
      _dichoFinDeVia = true;
      _hitosDichos.addAll(_hitos);
      return 'Hasta aquí llega la vía. El punto queda a '
          '${decirDistancia(aPie)}, a pie${_ladoDelDestino()}.';
    }

    // Cuanto falta. Se da por dicho todo hito mas largo que el que toca, por
    // si el GPS salto alguno.
    for (final hito in _hitos.reversed) {
      if (falta <= hito && !_hitosDichos.contains(hito)) {
        _hitosDichos.addAll(_hitos.where((h) => h >= hito));
        // Solo si es verdad: si el GPS salto y ya se esta bastante mas
        // cerca, decir el hito seria dar un numero que no es.
        if (falta < hito * 0.8) return null;
        return hito == 1000
            ? 'Falta un kilómetro.'
            : 'Faltan ${decirDistancia(hito)}.';
      }
    }
    return null;
  }

  /// De que lado de la via queda el punto, visto por quien viene llegando.
  String _ladoDelDestino() {
    final via = ruta.porLaVia;
    if (via.length < 2) return '';
    final llega = _rumbo(_atras(via, via.length - 1), via.last);
    final alPunto = _rumbo(via.last, ruta.destino);
    if (llega == null || alPunto == null) return '';
    var cambio = alPunto - llega;
    while (cambio > 180) {
      cambio -= 360;
    }
    while (cambio <= -180) {
      cambio += 360;
    }
    // Casi al frente o casi atras: decir un lado seria inventarlo.
    if (cambio.abs() < 25 || cambio.abs() > 155) return '';
    return cambio > 0 ? ', a tu derecha' : ', a tu izquierda';
  }
}

/// Una distancia como se dice en voz alta: "150 metros", "2 kilómetros",
/// "un kilómetro y medio". Redondeada, porque nadie necesita oir "143
/// metros". Va con sus tildes: el sintetizador las usa para acentuar, y sin
/// ellas dice "kiloMEtros".
String decirDistancia(double metros) {
  if (metros < 950) {
    final paso = metros < 100 ? 10 : 50;
    final redondo = math.max(paso, (metros / paso).round() * paso);
    return '$redondo metros';
  }
  // De a medio kilometro.
  final medios = (metros / 500).round();
  final enteros = medios ~/ 2;
  final km = enteros == 1 ? 'un kilómetro' : '$enteros kilómetros';
  return medios.isOdd ? '$km y medio' : km;
}

/// Un tiempo como se dice en voz alta: "unos 5 minutos", "una hora y media".
String decirMinutos(double minutos) {
  if (minutos < 1.5) return 'un minuto';
  if (minutos < 52) return 'unos ${minutos.round()} minutos';
  // De a media hora.
  final medias = (minutos / 30).round();
  final horas = medias ~/ 2;
  final h = horas == 1 ? 'una hora' : '$horas horas';
  if (medias.isOdd) return '$h y media';
  return horas == 1 ? h : 'unas $h';
}

String _mayuscula(String texto) =>
    texto.isEmpty ? texto : texto[0].toUpperCase() + texto.substring(1);
