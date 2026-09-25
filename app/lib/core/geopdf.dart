import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

/// Donde cae en el mundo el plano que trae un PDF de topografia.
///
/// Un GeoPDF es un PDF normal con un diccionario extra que dice que punto del
/// papel corresponde a que latitud y longitud. Es lo que permite dibujarlo
/// encima del mapa en el lugar correcto; sin el, un plano es una imagen bonita
/// que nadie puede ubicar.
///
/// ## Como viene el dato
///
/// La pagina trae `/VP`, una lista de *viewports*. Cada uno tiene:
///
/// - `/BBox`: que parte del papel esta georreferenciada. Casi nunca es la hoja
///   entera: el marco, el membrete y la convencion quedan afuera.
/// - `/Measure`, con `/GPTS` y `/Bounds`. `Bounds` son cuatro esquinas
///   expresadas **como fracciones del BBox** (0 a 1), y `GPTS` las mismas
///   cuatro esquinas en latitud y longitud. Emparejadas dan la ubicacion.
///
/// Las coordenadas del papel van en puntos PostScript, con el origen **abajo a
/// la izquierda** y la Y creciendo hacia arriba: al reves que una imagen.
///
/// ## Lo que este lector no hace
///
/// No es un parser de PDF completo y no pretende serlo. Lee los diccionarios
/// que estan escritos en claro, que es como los deja el software de topografia
/// que usa el equipo. Un PDF que guarde sus objetos comprimidos (`/ObjStm`) o
/// cifrado se rechaza **diciendolo**, para que la salida sea convertirlo desde
/// el PC con `tools/convertir_mapa.py` y no quedarse adivinando por que no
/// aparece la capa.
class GeoPdf {
  const GeoPdf({
    required this.esquinas,
    required this.recuadro,
    required this.pagina,
  });

  /// Las cuatro esquinas del area georreferenciada, en el orden que espera el
  /// mapa: noroeste, noreste, sureste, suroeste.
  final List<LatLng> esquinas;

  /// Que parte de la pagina esta georreferenciada, en puntos PostScript y ya
  /// normalizado (izquierda, abajo, derecha, arriba).
  final RecuadroPagina recuadro;

  /// El tamano de la pagina completa, tambien en puntos.
  final RecuadroPagina pagina;

  LatLng get noroeste => esquinas[0];
  LatLng get noreste => esquinas[1];
  LatLng get sureste => esquinas[2];
  LatLng get suroeste => esquinas[3];

  /// Lee la georreferencia, o explica por que no se puede.
  ///
  /// Lanza [GeoPdfInvalido] con un motivo en castellano: este mensaje termina
  /// en la pantalla del telefono, y "no se pudo importar" a secas obliga a
  /// llamar por telefono a alguien para averiguar que paso.
  static GeoPdf leer(Uint8List bytes) {
    // latin-1 y no utf-8: la estructura del PDF es ASCII, pero entre medio hay
    // flujos binarios que no son texto valido en ninguna codificacion. latin-1
    // mapea cualquier byte a un caracter sin fallar, y como solo se buscan
    // marcas ASCII, alcanza.
    final texto = String.fromCharCodes(bytes);

    if (texto.contains('/Encrypt')) {
      throw const GeoPdfInvalido(
        'El PDF esta protegido con clave. Pedilo sin proteccion, o '
        'convertilo desde el computador.',
      );
    }

    final vp = _bloque(texto, '/VP');
    if (vp == null) {
      throw const GeoPdfInvalido(
        'Este PDF no trae georreferencia: es un plano sin coordenadas, y no '
        'hay forma de saber donde va en el mapa.',
      );
    }

    final bbox = _numeros(_bloque(vp, '/BBox'));
    if (bbox.length < 4) {
      throw const GeoPdfInvalido('El PDF trae un recuadro ilegible.');
    }

    // El /Measure puede estar escrito adentro del viewport o como referencia a
    // otro objeto ("38 0 R"). Las dos formas son validas y las dos aparecen en
    // archivos reales.
    var medida = _bloque(vp, '/Measure');
    final referencia = RegExp(r'/Measure\s+(\d+)\s+\d+\s+R').firstMatch(vp);
    if (referencia != null) {
      medida = _objeto(texto, int.parse(referencia.group(1)!));
    }
    if (medida == null) {
      throw const GeoPdfInvalido(
        'El PDF declara un area georreferenciada pero no dice a que '
        'coordenadas corresponde.',
      );
    }

    final gpts = _numeros(_bloque(medida, '/GPTS'));
    if (gpts.length < 8) {
      if (texto.contains('/ObjStm')) {
        throw const GeoPdfInvalido(
          'Este PDF guarda su georreferencia comprimida, que el telefono no '
          'sabe abrir. Convertilo desde el computador.',
        );
      }
      throw const GeoPdfInvalido('El PDF trae coordenadas incompletas.');
    }

    // `/Bounds` son las esquinas como fracciones del recuadro. Cuando falta,
    // el estandar dice que se asume el recuadro entero.
    var limites = _numeros(_bloque(medida, '/Bounds'));
    if (limites.length < 8) limites = const [0, 1, 0, 0, 1, 0, 1, 1];

    final recuadro = RecuadroPagina.deLista(bbox);
    final mediaBox = _numeros(_bloque(texto, '/MediaBox'));
    if (mediaBox.length < 4) {
      throw const GeoPdfInvalido('El PDF no declara el tamano de la pagina.');
    }

    // Cada esquina se identifica por su fraccion, no por el orden en que
    // aparece: el orden cambia entre archivos y confiar en el es como se
    // termina con un plano dado vuelta.
    LatLng buscar(double fx, double fy) {
      for (var i = 0; i < 4; i++) {
        if ((limites[i * 2] - fx).abs() < 0.01 &&
            (limites[i * 2 + 1] - fy).abs() < 0.01) {
          return LatLng(gpts[i * 2], gpts[i * 2 + 1]);
        }
      }
      throw const GeoPdfInvalido(
        'El PDF georreferencia un area que no es un rectangulo. Convertilo '
        'desde el computador.',
      );
    }

    // Fraccion (0,0) es el origen del recuadro tal como lo escribio el PDF, y
    // ese origen es su primera esquina: arriba a la izquierda en los archivos
    // de topografia, porque el BBox viene con la Y mayor primero.
    final arribaIzq = bbox[1] > bbox[3];
    final noroeste = buscar(0, arribaIzq ? 0 : 1);
    final noreste = buscar(1, arribaIzq ? 0 : 1);
    final sureste = buscar(1, arribaIzq ? 1 : 0);
    final suroeste = buscar(0, arribaIzq ? 1 : 0);

    return GeoPdf(
      esquinas: [noroeste, noreste, sureste, suroeste],
      recuadro: recuadro,
      pagina: RecuadroPagina.deLista(mediaBox),
    );
  }

  /// El contenido de `/Clave[...]` o `/Clave<<...>>`, con sus llaves anidadas
  /// respetadas. Devuelve null si la clave no esta.
  static String? _bloque(String texto, String clave) {
    final i = texto.indexOf(clave);
    if (i < 0) return null;

    var j = i + clave.length;
    while (j < texto.length && (texto[j] == ' ' || texto[j] == '\r' || texto[j] == '\n')) {
      j++;
    }
    if (j >= texto.length) return null;

    final abre = texto[j];
    if (abre == '[') return _hasta(texto, j, '[', ']');
    if (abre == '<' && j + 1 < texto.length && texto[j + 1] == '<') {
      return _hasta(texto, j + 1, '<', '>');
    }
    return null;
  }

  /// Desde una apertura hasta su cierre, contando los anidados. Un `/VP` con
  /// varios viewports adentro tiene corchetes adentro de corchetes, y cortar en
  /// el primer cierre devuelve medio diccionario.
  static String _hasta(String texto, int desde, String abre, String cierra) {
    var nivel = 0;
    for (var i = desde; i < texto.length; i++) {
      if (texto[i] == abre) nivel++;
      if (texto[i] == cierra) {
        nivel--;
        if (nivel <= 0) return texto.substring(desde + 1, i);
      }
    }
    return texto.substring(desde + 1);
  }

  /// El cuerpo del objeto numerado, buscado como "N 0 obj ... endobj".
  static String? _objeto(String texto, int numero) {
    final m = RegExp(
      '(^|[^0-9])$numero\\s+\\d+\\s+obj',
      multiLine: true,
    ).firstMatch(texto);
    if (m == null) return null;
    final fin = texto.indexOf('endobj', m.end);
    return texto.substring(m.end, fin < 0 ? texto.length : fin);
  }

  static List<double> _numeros(String? bloque) {
    if (bloque == null) return const [];
    return RegExp(r'-?\d+\.?\d*')
        .allMatches(bloque)
        .map((m) => double.parse(m.group(0)!))
        .toList(growable: false);
  }
}

/// Un rectangulo de la pagina en puntos PostScript, ya normalizado.
class RecuadroPagina {
  const RecuadroPagina({
    required this.izquierda,
    required this.abajo,
    required this.derecha,
    required this.arriba,
  });

  /// De `[x1 y1 x2 y2]`, que el PDF **no** garantiza ordenado: el BBox de un
  /// viewport suele venir con la Y mayor primero.
  factory RecuadroPagina.deLista(List<double> v) => RecuadroPagina(
    izquierda: v[0] < v[2] ? v[0] : v[2],
    abajo: v[1] < v[3] ? v[1] : v[3],
    derecha: v[0] < v[2] ? v[2] : v[0],
    arriba: v[1] < v[3] ? v[3] : v[1],
  );

  final double izquierda;
  final double abajo;
  final double derecha;
  final double arriba;

  double get ancho => derecha - izquierda;
  double get alto => arriba - abajo;
}

/// El PDF no sirve como capa, y el motivo esta escrito para que lo lea quien
/// esta parado en un lote, no quien escribio el codigo.
class GeoPdfInvalido implements Exception {
  const GeoPdfInvalido(this.motivo);

  final String motivo;

  @override
  String toString() => motivo;
}
