import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

import 'pdf_objetos.dart';

/// Donde cae en el mundo el plano que trae un PDF cartografico.
///
/// Un GeoPDF es un PDF normal con un diccionario extra que dice que punto del
/// papel corresponde a que latitud y longitud. Es lo que permite dibujarlo
/// encima del mapa en el lugar correcto; sin el, un plano es una imagen bonita
/// que nadie puede ubicar.
///
/// ## Las dos formas en que viene el dato
///
/// **La de Adobe (ISO 32000)**, que es la que escriben QGIS, ArcGIS, AutoCAD y
/// el software de topografia. La pagina trae `/VP`, una lista de *viewports*.
/// Cada uno tiene:
///
/// - `/BBox`: que parte del papel esta georreferenciada. Casi nunca es la hoja
///   entera: el marco, el membrete y la convencion quedan afuera.
/// - `/Measure`, con `/GPTS` y `/LPTS`. `GPTS` son puntos en latitud y
///   longitud, y `LPTS` los mismos puntos **como fracciones del BBox** (0 a
///   1). Emparejados dan la ubicacion. Cuando falta `LPTS` se usa `/Bounds`,
///   el contorno del mapa, que en casi todos los archivos son los mismos
///   cuatro puntos.
///
/// **La de TerraGo (OGC)**, la de los GeoPDF "de marca" y de Global Mapper. La
/// pagina trae `/LGIDict`, con una matriz `/CTM` que lleva cada punto del
/// papel a metros en la proyeccion del plano, la proyeccion descripta en
/// `/Projection`, y el contorno del mapa en `/Neatline`. Aca si hay que
/// proyectar: el archivo no trae latitudes escritas.
///
/// Las coordenadas del papel van en puntos PostScript, con el origen **abajo a
/// la izquierda** y la Y creciendo hacia arriba: al reves que una imagen.
///
/// ## Lo que entrega
///
/// No las esquinas que trae el archivo, sino las del **recorte**: se ajusta la
/// transformacion papel -> mundo con todos los puntos que haya, y con ella se
/// calcula donde cae cada esquina de la parte de la hoja que se va a dibujar.
/// Asi da igual en que orden vengan los puntos, cuantos sean, si la hoja esta
/// girada o si el contorno del mapa no es un rectangulo.
class GeoPdf {
  const GeoPdf({
    required this.esquinas,
    required this.recuadro,
    required this.pagina,
    this.indicePagina = 0,
    this.rotacion = 0,
    this.aviso,
  });

  /// Donde cae cada esquina del recorte, en el orden en que se ve en pantalla:
  /// arriba-izquierda, arriba-derecha, abajo-derecha, abajo-izquierda. En un
  /// plano con el norte arriba son noroeste, noreste, sureste y suroeste.
  final List<LatLng> esquinas;

  /// Que parte de la pagina esta georreferenciada, en puntos PostScript y ya
  /// normalizado (izquierda, abajo, derecha, arriba).
  final RecuadroPagina recuadro;

  /// La parte de la hoja que se muestra, tambien en puntos.
  final RecuadroPagina pagina;

  /// Cual hoja del PDF trae el mapa, desde 0. Un PDF de varias hojas puede
  /// tener la caratula adelante.
  final int indicePagina;

  /// Giro con el que se muestra la hoja: 0, 90, 180 o 270.
  final int rotacion;

  /// Algo que la persona tiene que saber aunque el plano se haya podido leer:
  /// por ejemplo, que usa un sistema viejo y puede quedar corrido.
  final String? aviso;

  LatLng get noroeste => esquinas[0];
  LatLng get noreste => esquinas[1];
  LatLng get sureste => esquinas[2];
  LatLng get suroeste => esquinas[3];

  /// El tamano de la hoja **como se ve**, ya girada.
  double get anchoVisible => rotacion % 180 == 0 ? pagina.ancho : pagina.alto;
  double get altoVisible => rotacion % 180 == 0 ? pagina.alto : pagina.ancho;

  /// El recuadro en el espacio en que dibuja el motor de PDF: origen **arriba**
  /// a la izquierda de la hoja visible, ya girada, y la Y hacia abajo.
  RecortePagina get recorte => _recorte(recuadro, pagina, rotacion);

  /// Lee la georreferencia de un archivo. Pensado para correr en un isolate:
  /// un plano cartografico pesa decenas de megas, y recorrerlo en el hilo de
  /// la pantalla la deja congelada.
  static GeoPdf leerArchivo(String ruta) =>
      leer(File(ruta).readAsBytesSync());

  /// Lee la georreferencia, o explica por que no se puede.
  ///
  /// Lanza [GeoPdfInvalido] con un motivo en castellano: este mensaje termina
  /// en la pantalla del telefono, y "no se pudo importar" a secas obliga a
  /// llamar por telefono a alguien para averiguar que paso.
  static GeoPdf leer(Uint8List bytes) {
    final doc = PdfDocumento(bytes);
    if (!doc.esPdf) {
      throw const GeoPdfInvalido(
        'Este archivo no es un PDF. Elegi el plano en formato PDF.',
      );
    }

    // Se miran todas las hojas y todos los mapas de cada hoja, y se elige el
    // mas grande: una hoja puede traer el mapa principal y un mapita de
    // ubicacion, cada uno con su georreferencia, y el que se quiere encima
    // del terreno es el principal.
    _Marco? mejor;
    GeoPdfInvalido? tropiezo;
    for (final pagina in doc.paginas()) {
      final visible = _visible(pagina);
      for (final leerMarcos in [_marcosIso, _marcosOgc]) {
        try {
          for (final m in leerMarcos(doc, pagina, visible)) {
            if (mejor == null || m.area > mejor.area) mejor = m;
          }
        } on GeoPdfInvalido catch (e) {
          tropiezo ??= e;
        }
      }
    }

    if (mejor == null) {
      if (tropiezo != null) throw tropiezo;
      if (doc.cifrado) {
        throw const GeoPdfInvalido(
          'El PDF esta protegido con clave. Pedilo sin proteccion, o '
          'convertilo desde el computador.',
        );
      }
      if (doc.comprimidosIlegibles) {
        throw const GeoPdfInvalido(
          'Este PDF guarda sus datos de una forma que el telefono no sabe '
          'abrir. Convertilo desde el computador.',
        );
      }
      throw const GeoPdfInvalido(
        'Este PDF no trae georreferencia: es un plano sin coordenadas, y no '
        'hay forma de saber donde va en el mapa. Pedilo exportado como PDF '
        'geoespacial (GeoPDF).',
      );
    }

    return mejor.resolver();
  }

  // --- Lectura: formato de Adobe -------------------------------------------

  static Iterable<_Marco> _marcosIso(
    PdfDocumento doc,
    PdfPagina pagina,
    RecuadroPagina visible,
  ) sync* {
    for (final v in doc.lista(pagina.dicc['VP']) ?? const <Object?>[]) {
      final vista = doc.dicc(v);
      if (vista == null) continue;
      final bbox = doc.numeros(vista['BBox']);
      final medida = doc.dicc(vista['Measure']);
      if (bbox == null || bbox.length < 4 || medida == null) continue;

      // `/RL` es una regla para medir sobre el papel, sin coordenadas.
      final tipo = doc.texto(medida['Subtype']);
      if (tipo != null && tipo != 'GEO') continue;

      final gpts = doc.numeros(medida['GPTS']);
      if (gpts == null || gpts.length < 4) continue;
      final cuantos = gpts.length ~/ 2;

      final limites = doc.numeros(medida['Bounds']);
      var fracciones = doc.numeros(medida['LPTS']);
      if (fracciones == null || fracciones.length < cuantos * 2) {
        fracciones = (limites != null && limites.length >= cuantos * 2)
            ? limites
            // El orden que usan los programas cuando no lo aclaran.
            : const <double>[0, 1, 0, 0, 1, 0, 1, 1];
      }
      if (fracciones.length < cuantos * 2) continue;

      // Cada fraccion se mide sobre el BBox **tal como esta escrito**, sin
      // ordenarlo: la fraccion (0,0) es su primera esquina, que en los planos
      // de topografia es la de arriba porque el BBox viene con la Y mayor
      // primero. Ordenarlo antes da vuelta el plano.
      double x(double f) => bbox[0] + f * (bbox[2] - bbox[0]);
      double y(double f) => bbox[1] + f * (bbox[3] - bbox[1]);

      final puntos = <_Control>[];
      for (var i = 0; i < cuantos; i++) {
        final lat = gpts[i * 2];
        final lon = gpts[i * 2 + 1];
        if (lat.abs() > 90 || lon.abs() > 180) {
          throw const GeoPdfInvalido(
            'El PDF trae coordenadas que no son latitud y longitud. '
            'Convertilo desde el computador.',
          );
        }
        puntos.add(
          _Control(x(fracciones[i * 2]), y(fracciones[i * 2 + 1]), lat, lon),
        );
      }

      // El recorte es el contorno del mapa cuando el archivo lo declara mas
      // chico que el BBox; si no, el BBox entero.
      var recuadro = RecuadroPagina.deLista(bbox);
      if (limites != null && limites.length >= 6) {
        final xs = [for (var i = 0; i + 1 < limites.length; i += 2) limites[i]];
        final ys = [
          for (var i = 1; i < limites.length; i += 2) limites[i],
        ];
        final contorno = RecuadroPagina.deLista([
          x(xs.reduce(math.min).clamp(0, 1).toDouble()),
          y(ys.reduce(math.min).clamp(0, 1).toDouble()),
          x(xs.reduce(math.max).clamp(0, 1).toDouble()),
          y(ys.reduce(math.max).clamp(0, 1).toDouble()),
        ]);
        if (contorno.ancho > 1 && contorno.alto > 1) recuadro = contorno;
      }

      final recortado = recuadro.dentroDe(visible);
      if (recortado == null) continue;

      yield _Marco(
        pagina: pagina,
        visible: visible,
        recuadro: recortado,
        puntos: puntos,
        aviso: _avisoDeDatum(doc, doc.dicc(medida['GCS'])),
      );
    }
  }

  /// Un plano en el datum Bogota (el de antes de MAGNA-SIRGAS) trae latitudes
  /// que no son las del GPS: caen unos 300 metros corridas. No se rechaza
  /// -sigue sirviendo de referencia-, pero se dice.
  static String? _avisoDeDatum(PdfDocumento doc, Map<String, Object?>? gcs) {
    if (gcs == null) return null;
    final epsg = doc.numero(gcs['EPSG'])?.round();
    final wkt = doc.texto(gcs['WKT']) ?? '';
    final datum =
        RegExp(r'DATUM\s*\[\s*"([^"]*)"').firstMatch(wkt)?.group(1) ?? '';
    final viejo =
        datum.toLowerCase().contains('bogota') ||
        epsg == 4218 ||
        (epsg != null && epsg >= 21891 && epsg <= 21899);
    return viejo ? _avisoBogota : null;
  }

  static const _avisoBogota =
      'Este plano usa el sistema de coordenadas viejo (Bogota 1975). Puede '
      'quedar corrido unos 300 metros respecto del GPS.';

  // --- Lectura: formato de TerraGo -----------------------------------------

  static Iterable<_Marco> _marcosOgc(
    PdfDocumento doc,
    PdfPagina pagina,
    RecuadroPagina visible,
  ) sync* {
    final crudo = doc.resolver(pagina.dicc['LGIDict']);
    final registros = crudo is List<Object?> ? crudo : [crudo];

    for (final r in registros) {
      final d = doc.dicc(r);
      if (d == null) continue;
      final ctm = doc.numeros(d['CTM']);
      final proyeccion = doc.dicc(d['Projection']);
      if (ctm == null || ctm.length < 6 || proyeccion == null) continue;

      var recuadro = visible;
      final contorno = doc.numeros(d['Neatline']);
      if (contorno != null && contorno.length >= 6) {
        final xs = [
          for (var i = 0; i + 1 < contorno.length; i += 2) contorno[i],
        ];
        final ys = [
          for (var i = 1; i < contorno.length; i += 2) contorno[i],
        ];
        final caja = RecuadroPagina.deLista([
          xs.reduce(math.min),
          ys.reduce(math.min),
          xs.reduce(math.max),
          ys.reduce(math.max),
        ]).dentroDe(visible);
        if (caja != null) recuadro = caja;
      }

      final (aLatLon, aviso) = _proyeccionOgc(doc, proyeccion);

      // La matriz lleva puntos del papel a metros del plano; de ahi a latitud
      // y longitud va la proyeccion. Se toman las esquinas y el centro del
      // recorte: con eso alcanza para ajustar la transformacion.
      final muestras = [
        (recuadro.izquierda, recuadro.arriba),
        (recuadro.derecha, recuadro.arriba),
        (recuadro.derecha, recuadro.abajo),
        (recuadro.izquierda, recuadro.abajo),
        (
          (recuadro.izquierda + recuadro.derecha) / 2,
          (recuadro.abajo + recuadro.arriba) / 2,
        ),
      ];
      final puntos = <_Control>[];
      for (final (x, y) in muestras) {
        final este = ctm[0] * x + ctm[2] * y + ctm[4];
        final norte = ctm[1] * x + ctm[3] * y + ctm[5];
        final donde = aLatLon(este, norte);
        if (donde == null) {
          throw const GeoPdfInvalido(
            'El PDF trae coordenadas que no se pudieron ubicar en el mundo. '
            'Convertilo desde el computador.',
          );
        }
        puntos.add(_Control(x, y, donde.latitude, donde.longitude));
      }

      yield _Marco(
        pagina: pagina,
        visible: visible,
        recuadro: recuadro,
        puntos: puntos,
        aviso: aviso,
      );
    }
  }

  /// Arma la funcion que lleva metros del plano a latitud y longitud, a partir
  /// del diccionario `/Projection`.
  ///
  /// Cubre lo que se usa en planos de predios y cartografia basica: geografica,
  /// UTM, Transversa de Mercator (la de MAGNA-SIRGAS) y conica de Lambert. Lo
  /// demas se rechaza diciendo cual es, en vez de dibujarlo en cualquier lado.
  static (LatLng? Function(double este, double norte), String? aviso)
  _proyeccionOgc(PdfDocumento doc, Map<String, Object?> p) {
    final tipo = (doc.texto(p['ProjectionType']) ?? '').trim().toUpperCase();
    double n(String clave, [double porDefecto = 0]) =>
        doc.numero(p[clave]) ?? porDefecto;

    // El elipsoide. Un datum que no se conoce no se rechaza: la diferencia
    // entre elipsoides modernos es de centimetros. Los viejos si se avisan.
    var elipsoide = '+ellps=WGS84';
    String? aviso;
    final datum = doc.resolver(p['Datum']);
    if (datum is Map<String, Object?>) {
      final e = doc.dicc(datum['Ellipsoid']);
      final a = doc.numero(e?['SemiMajorAxis']);
      final rf = doc.numero(e?['InvFlattening']);
      if (a != null && rf != null && a > 6000000 && rf > 200) {
        elipsoide = '+a=$a +rf=$rf';
      }
      final nombre = (doc.texto(datum['Description']) ?? '').toLowerCase();
      if (nombre.contains('bogota')) aviso = _avisoBogota;
    } else {
      final codigo = (doc.texto(datum) ?? '').trim().toUpperCase();
      if (codigo.startsWith('NAR')) {
        elipsoide = '+ellps=GRS80';
      } else if (codigo.startsWith('BOO')) {
        elipsoide = '+ellps=intl';
        aviso = _avisoBogota;
      } else if (codigo.isNotEmpty &&
          !codigo.startsWith('WG') &&
          codigo != 'WE') {
        aviso =
            'Este plano usa un sistema de coordenadas que el telefono no '
            'conoce ($codigo). Puede quedar corrido respecto del GPS.';
      }
    }

    if (tipo == 'GEOGRAPHIC' || tipo == 'GEODETIC') {
      return ((este, norte) => _latLon(norte, este), aviso);
    }

    final unidad = (doc.texto(p['Units']) ?? 'M').trim().toUpperCase();
    final aMetros = switch (unidad) {
      'FT' || 'F' || 'FEET' => ' +to_meter=0.3048',
      'US' || 'USFT' || 'SF' => ' +to_meter=0.3048006096012192',
      _ => '',
    };

    final String definicion;
    switch (tipo) {
      case 'UT':
        final sur = (doc.texto(p['Hemisphere']) ?? 'N').toUpperCase() == 'S';
        definicion = '+proj=utm +zone=${n('Zone').round()}${sur ? ' +south' : ''}';
      case 'TC':
        definicion =
            '+proj=tmerc +lat_0=${n('OriginLatitude')} '
            '+lon_0=${n('CentralMeridian')} +k=${n('ScaleFactor', 1)} '
            '+x_0=${n('FalseEasting')} +y_0=${n('FalseNorthing')}';
      case 'LE':
        definicion =
            '+proj=lcc +lat_1=${n('StandardParallelOne')} '
            '+lat_2=${n('StandardParallelTwo')} '
            '+lat_0=${n('OriginLatitude')} +lon_0=${n('CentralMeridian')} '
            '+x_0=${n('FalseEasting')} +y_0=${n('FalseNorthing')}';
      default:
        throw GeoPdfInvalido(
          'Este PDF usa una proyeccion (${tipo.isEmpty ? 'sin nombre' : tipo}) '
          'que el telefono no sabe leer. Convertilo desde el computador.',
        );
    }

    final proj4.Projection origen;
    try {
      origen = proj4.Projection.parse(
        '$definicion $elipsoide$aMetros +no_defs',
      );
    } on Object {
      throw const GeoPdfInvalido(
        'El PDF describe su proyeccion de una forma que el telefono no '
        'entiende. Convertilo desde el computador.',
      );
    }
    final destino = proj4.Projection.WGS84;

    return (
      (este, norte) {
        try {
          final r = origen.transform(destino, proj4.Point(x: este, y: norte));
          return _latLon(r.y, r.x);
        } on Object {
          return null;
        }
      },
      aviso,
    );
  }

  static LatLng? _latLon(double lat, double lon) =>
      (lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180)
      ? LatLng(lat, lon)
      : null;

  // --- Geometria de la hoja ------------------------------------------------

  /// La parte de la hoja que el motor de PDF va a mostrar: el `CropBox`
  /// recortado al `MediaBox`. Un plano exportado "solo el area de impresion"
  /// tiene un CropBox mas chico, y calcular el recorte contra la hoja entera
  /// lo deja corrido.
  static RecuadroPagina _visible(PdfPagina pagina) {
    final hoja = RecuadroPagina.deLista(
      // Sin MediaBox el PDF es invalido; se asume carta, que es lo que hacen
      // los visores, para no negarse a abrir un plano por eso.
      pagina.mediaBox ?? const <double>[0, 0, 612, 792],
    );
    final crop = pagina.cropBox;
    if (crop == null) return hoja;
    return RecuadroPagina.deLista(crop).dentroDe(hoja) ?? hoja;
  }

  /// Un punto del papel (origen abajo, Y hacia arriba) en el espacio en que se
  /// ve la hoja (origen arriba, Y hacia abajo), con el giro aplicado.
  static (double, double) _aPantalla(
    double x,
    double y,
    RecuadroPagina hoja,
    int rotacion,
  ) => switch (rotacion) {
    90 => (y - hoja.abajo, x - hoja.izquierda),
    180 => (hoja.derecha - x, y - hoja.abajo),
    270 => (hoja.arriba - y, hoja.derecha - x),
    _ => (x - hoja.izquierda, hoja.arriba - y),
  };

  static RecortePagina _recorte(
    RecuadroPagina recuadro,
    RecuadroPagina hoja,
    int rotacion,
  ) {
    final (x1, y1) = _aPantalla(
      recuadro.izquierda,
      recuadro.abajo,
      hoja,
      rotacion,
    );
    final (x2, y2) = _aPantalla(
      recuadro.derecha,
      recuadro.arriba,
      hoja,
      rotacion,
    );
    return RecortePagina(
      x: math.min(x1, x2),
      y: math.min(y1, y2),
      ancho: (x2 - x1).abs(),
      alto: (y2 - y1).abs(),
    );
  }
}

/// Un mapa georreferenciado adentro de una hoja, todavia sin resolver.
class _Marco {
  _Marco({
    required this.pagina,
    required this.visible,
    required this.recuadro,
    required this.puntos,
    this.aviso,
  });

  final PdfPagina pagina;
  final RecuadroPagina visible;
  final RecuadroPagina recuadro;
  final List<_Control> puntos;
  final String? aviso;

  double get area => recuadro.ancho * recuadro.alto;

  /// Ajusta la transformacion pantalla -> mundo con los puntos de control y
  /// calcula donde cae cada esquina del recorte.
  ///
  /// El ajuste se hace en Mercator y no en grados: el mapa de la app esta en
  /// Mercator, el plano en una proyeccion conforme, y entre dos proyecciones
  /// conformes la relacion es casi exactamente una transformacion afin. En
  /// grados la latitud se estira distinto que la longitud y el error crece
  /// hacia los bordes.
  GeoPdf resolver() {
    final rotacion = pagina.rotacion;
    final muestras = [
      for (final p in puntos)
        (
          GeoPdf._aPantalla(p.x, p.y, visible, rotacion),
          (p.lon, _mercator(p.lat)),
        ),
    ];

    final afin = _Afin.ajustar(muestras);
    if (afin == null) {
      throw const GeoPdfInvalido(
        'El PDF trae coordenadas incompletas: no alcanzan para ubicar el '
        'plano. Convertilo desde el computador.',
      );
    }

    final r = GeoPdf._recorte(recuadro, visible, rotacion);
    final esquinas = <LatLng>[];
    for (final (u, v) in [
      (r.x, r.y),
      (r.x + r.ancho, r.y),
      (r.x + r.ancho, r.y + r.alto),
      (r.x, r.y + r.alto),
    ]) {
      final (lon, my) = afin.aplicar(u, v);
      final lat = _latitud(my);
      if (!lat.isFinite || !lon.isFinite || lat.abs() > 85 || lon.abs() > 180) {
        throw const GeoPdfInvalido(
          'El PDF trae coordenadas que caen fuera del mundo. Convertilo '
          'desde el computador.',
        );
      }
      esquinas.add(LatLng(lat, lon));
    }

    // Un plano de ancho cero no se puede dibujar, y casi siempre quiere decir
    // que los puntos de control estaban repetidos.
    final ancho = (esquinas[0].longitude - esquinas[2].longitude).abs();
    final alto = (esquinas[0].latitude - esquinas[2].latitude).abs();
    if (ancho < 1e-7 || alto < 1e-7) {
      throw const GeoPdfInvalido(
        'El PDF trae coordenadas incompletas: no alcanzan para ubicar el '
        'plano. Convertilo desde el computador.',
      );
    }

    // Cuanto se apartan los puntos del archivo de la transformacion ajustada.
    // Si es mucho, el mapa cubre un area tan grande que su proyeccion ya no
    // se parece a la del mapa de fondo, y los bordes van a quedar corridos.
    var desvio = 0.0;
    for (final (pantalla, mundo) in muestras) {
      final (lon, my) = afin.aplicar(pantalla.$1, pantalla.$2);
      desvio = math.max(
        desvio,
        math.max((lon - mundo.$1).abs(), (my - mundo.$2).abs()),
      );
    }
    final amplio = desvio > 0.01 * math.max(ancho, alto);

    return GeoPdf(
      esquinas: esquinas,
      recuadro: recuadro,
      pagina: visible,
      indicePagina: pagina.indice,
      rotacion: rotacion,
      aviso:
          aviso ??
          (amplio
              ? 'Este mapa cubre un area muy grande: hacia los bordes puede '
                    'quedar corrido respecto del mapa de fondo.'
              : null),
    );
  }

  static double _mercator(double lat) {
    final rad = lat.clamp(-85.0, 85.0) * math.pi / 180;
    return math.log(math.tan(math.pi / 4 + rad / 2)) * 180 / math.pi;
  }

  static double _latitud(double mercator) =>
      (2 * math.atan(math.exp(mercator * math.pi / 180)) - math.pi / 2) *
      180 /
      math.pi;
}

/// Un punto del papel y donde cae en el mundo.
class _Control {
  const _Control(this.x, this.y, this.lat, this.lon);
  final double x;
  final double y;
  final double lat;
  final double lon;
}

/// Transformacion afin de la pantalla al mundo: admite escala, giro y sesgo,
/// que es todo lo que le puede pasar a una hoja al ponerla sobre el mapa.
class _Afin {
  const _Afin(this.a, this.b, this.c, this.d, this.e, this.f);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  (double, double) aplicar(double u, double v) =>
      (a * u + b * v + c, d * u + e * v + f);

  /// Minimos cuadrados sobre todos los puntos. Con cuatro esquinas exactas da
  /// lo mismo que usar tres; con mas puntos, o con esquinas que no forman un
  /// paralelogramo perfecto, reparte el error en vez de cargarlo en una.
  static _Afin? ajustar(List<((double, double), (double, double))> muestras) {
    final n = muestras.length;
    if (n < 2) return null;

    var um = 0.0, vm = 0.0, xm = 0.0, ym = 0.0;
    for (final ((u, v), (x, y)) in muestras) {
      um += u;
      vm += v;
      xm += x;
      ym += y;
    }
    um /= n;
    vm /= n;
    xm /= n;
    ym /= n;

    var suu = 0.0, suv = 0.0, svv = 0.0;
    var sux = 0.0, svx = 0.0, suy = 0.0, svy = 0.0;
    for (final ((u, v), (x, y)) in muestras) {
      final du = u - um;
      final dv = v - vm;
      suu += du * du;
      suv += du * dv;
      svv += dv * dv;
      sux += du * (x - xm);
      svx += dv * (x - xm);
      suy += du * (y - ym);
      svy += dv * (y - ym);
    }

    final det = suu * svv - suv * suv;
    if (suu <= 0 || svv <= 0) return null;

    if (det.abs() < 1e-9 * suu * svv) {
      // Todos los puntos sobre una linea: lo comun es que sean solo dos
      // esquinas opuestas. Se asume el plano derecho, con el norte arriba.
      final ((u1, v1), (x1, y1)) = muestras.first;
      final ((u2, v2), (x2, y2)) = muestras.last;
      if ((u2 - u1).abs() < 1e-9 || (v2 - v1).abs() < 1e-9) return null;
      final a = (x2 - x1) / (u2 - u1);
      final e = (y2 - y1) / (v2 - v1);
      return _Afin(a, 0, x1 - a * u1, 0, e, y1 - e * v1);
    }

    final a = (sux * svv - svx * suv) / det;
    final b = (svx * suu - sux * suv) / det;
    final d = (suy * svv - svy * suv) / det;
    final e = (svy * suu - suy * suv) / det;
    return _Afin(a, b, xm - a * um - b * vm, d, e, ym - d * um - e * vm);
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

  /// La parte de este rectangulo que cae adentro de [otro]. Null si no se
  /// tocan, o si lo que queda es una astilla que no se puede dibujar.
  RecuadroPagina? dentroDe(RecuadroPagina otro) {
    final r = RecuadroPagina(
      izquierda: math.max(izquierda, otro.izquierda),
      abajo: math.max(abajo, otro.abajo),
      derecha: math.min(derecha, otro.derecha),
      arriba: math.min(arriba, otro.arriba),
    );
    return (r.ancho > 1 && r.alto > 1) ? r : null;
  }
}

/// Un rectangulo de la hoja **como se ve**: origen arriba a la izquierda, en
/// puntos, con el giro de la hoja ya aplicado. Es lo que se le pide al motor
/// de PDF que dibuje.
class RecortePagina {
  const RecortePagina({
    required this.x,
    required this.y,
    required this.ancho,
    required this.alto,
  });

  final double x;
  final double y;
  final double ancho;
  final double alto;
}

/// El PDF no sirve como capa, y el motivo esta escrito para que lo lea quien
/// esta parado en un lote, no quien escribio el codigo.
class GeoPdfInvalido implements Exception {
  const GeoPdfInvalido(this.motivo);

  final String motivo;

  @override
  String toString() => motivo;
}
