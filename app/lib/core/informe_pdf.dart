import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/db/app_database.dart';
import '../data/db/enums.dart';
import 'geo.dart';
import 'geojson.dart';

/// Un renglon del resumen: "Area" -> "4,20 ha".
class DatoInforme {
  const DatoInforme(this.etiqueta, this.valor);

  final String etiqueta;
  final String valor;

  @override
  String toString() => '$etiqueta: $valor';
}

/// Lo que dice el informe de un levantamiento, antes de ponerlo en papel.
///
/// Esta aparte del dibujo del PDF para poder probar **que** dice sin abrir un
/// PDF: los numeros, las fechas y, sobre todo, las advertencias.
class ContenidoInforme {
  const ContenidoInforme({
    required this.titulo,
    required this.tipo,
    required this.esArea,
    required this.datos,
    required this.notas,
    required this.linea,
    required this.marcas,
    required this.conTablaDeVertices,
    required this.generadoEn,
  });

  final String titulo;

  /// "Area medida", "Recorrido grabado" o "Ruta calculada".
  final String tipo;
  final bool esArea;
  final List<DatoInforme> datos;

  /// Lo que hay que saber para no usar mal el dato. Van en el papel, debajo
  /// de los numeros, y no en letra chica.
  final List<String> notas;
  final List<PuntoGeo> linea;
  final List<Waypoint> marcas;

  /// Si los vertices van en una tabla. Un area tiene pocos y son el dato; un
  /// recorrido grabado tiene miles y no le sirven a nadie en papel.
  final bool conTablaDeVertices;
  final DateTime generadoEn;
}

/// El PDF que se imprime y se entrega: lo que se levanto, en una hoja que
/// puede leer quien no usa mapas ni tiene Google Earth.
///
/// Se arma entero en el telefono, sin red, con las fuentes que trae el
/// formato PDF: no hay que empaquetar ni bajar ninguna.
///
/// Lo que el informe tiene que decir y casi siempre se olvida: **la precision
/// del GPS con la que se levanto**. Un area de 4,2 ha medida con 30 m de error
/// no es el mismo dato que una medida con 3 m, y en el papel se ven iguales si
/// nadie lo escribe. Por eso las advertencias van como notas, con el mismo
/// tamano de letra que los numeros.
abstract final class InformePdf {
  /// Hasta cuantos vertices se listan. Mas que esto ya no es una tabla que
  /// alguien lea: va el archivo (KML, GeoJSON) y el informe lo dice.
  static const maximoDeVertices = 60;

  /// El PDF de [trazado], listo para guardar o compartir.
  static Future<Uint8List> deTrazado(
    Trazado trazado, {
    List<Waypoint> marcas = const [],
    String? proyecto,
    String? autor,
    DateTime? generadoEn,
  }) {
    return armar(
      contenido(
        trazado,
        marcas: marcas,
        proyecto: proyecto,
        autor: autor,
        generadoEn: generadoEn,
      ),
    );
  }

  /// Lo que dice el informe de [trazado].
  static ContenidoInforme contenido(
    Trazado trazado, {
    List<Waypoint> marcas = const [],
    String? proyecto,
    String? autor,
    DateTime? generadoEn,
  }) {
    final t = trazado;
    final geojson = jsonDecode(t.geometria) as Map<String, dynamic>;
    final linea = GeoJson.puntosDeLinea(geojson);
    final propiedades =
        (geojson['properties'] as Map<String, dynamic>?) ?? const {};

    final esArea = t.tipo == TipoTrazado.poligono.name;
    final aMano = t.metodo == MetodoCaptura.manual.name;
    final calculada = t.metodo == MetodoCaptura.calculada.name;
    // Un area se guarda como linea cerrada: el ultimo vertice repite al
    // primero y no es un vertice mas.
    final vertices = esArea && linea.length > 1
        ? linea.length - 1
        : linea.length;

    final tipo = esArea
        ? 'Área medida'
        : calculada
        ? 'Ruta calculada'
        : 'Recorrido grabado';

    final datos = <DatoInforme>[
      DatoInforme('Proyecto', _oSin(proyecto, 'Sin proyecto')),
      if (t.areaHa != null) DatoInforme('Área', area(t.areaHa!)),
      if (t.distanciaM != null)
        DatoInforme(
          esArea ? 'Perímetro' : 'Distancia',
          distancia(t.distanciaM!),
        ),
      DatoInforme(esArea ? 'Vértices' : 'Puntos del recorrido', '$vertices'),
      DatoInforme(
        'Cómo se levantó',
        aMano
            ? 'Tocando puntos sobre el mapa, sin GPS'
            : calculada
            ? 'Calculada por las vías del predio'
            : 'Con el GPS del teléfono',
      ),
      if (t.precisionMediaM != null)
        DatoInforme(
          'Precisión media del GPS',
          '± ${t.precisionMediaM!.round()} m',
        ),
      DatoInforme('Fecha', _fecha(t.iniciadoEn ?? t.creadoEn)),
      if (_duracion(t.iniciadoEn, t.terminadoEn) case final d?)
        DatoInforme('Duración', d),
      if (propiedades['calificacion'] case final int estrellas)
        DatoInforme('Calificación del camino', '$estrellas de 5'),
      if (_oSin(autor, '') case final quien when quien.isNotEmpty)
        DatoInforme('Levantado por', quien),
    ];

    final precision = t.precisionMediaM;
    final notas = <String>[
      if (aMano)
        'Las medidas salen de puntos tocados sobre la imagen del mapa, no '
            'del GPS. Sirven como referencia y no como lindero.'
      else if (calculada)
        'Es el camino que la aplicación sugiere por las vías del predio, no '
            'un recorrido medido en el terreno.'
      else if (precision != null && precision > 10)
        'El GPS tuvo un error medio de ± ${precision.round()} m, que es alto: '
            '${esArea ? 'el área y el perímetro son aproximados' : 'la distancia es aproximada'}'
            '. Bajo árboles o con el cielo tapado el error crece.'
      else if (precision != null)
        'El GPS tuvo un error medio de ± ${precision.round()} m.',
      if (!calculada)
        'El GPS de un teléfono no reemplaza un levantamiento topográfico.',
      if (!esArea && vertices > maximoDeVertices)
        'El recorrido tiene $vertices puntos, que no se listan en este '
            'informe. Van completos en el archivo KML o GeoJSON del mismo '
            'recorrido.'
      else if (esArea && vertices > maximoDeVertices)
        'Se listan los primeros $maximoDeVertices vértices de $vertices. Van '
            'completos en el archivo KML o GeoJSON de la misma área.',
      'Coordenadas en WGS84 (EPSG:4326), en grados decimales.',
    ];

    return ContenidoInforme(
      titulo: t.nombre,
      tipo: tipo,
      esArea: esArea,
      datos: datos,
      notas: notas,
      linea: linea,
      marcas: marcas,
      conTablaDeVertices: esArea || vertices <= maximoDeVertices,
      generadoEn: generadoEn ?? DateTime.now(),
    );
  }

  /// Un area como se escribe aca: "4,20 ha", y en metros cuando es chica.
  static String area(double hectareas) {
    if (hectareas < 1) {
      return '${_numero(hectareas * 10000, 0)} m² '
          '(${_numero(hectareas, 2)} ha)';
    }
    return '${_numero(hectareas, 2)} ha';
  }

  static String distancia(double metros) => metros < 1000
      ? '${_numero(metros, 0)} m'
      : '${_numero(metros / 1000, 2)} km (${_numero(metros, 0)} m)';

  /// Pone [c] en papel. Con [comprimir] en falso el archivo pesa mas y se
  /// puede leer por dentro: es para las pruebas.
  static Future<Uint8List> armar(ContenidoInforme c, {bool comprimir = true}) {
    final documento = pw.Document(
      title: _t(c.titulo),
      author: 'Sirius GeoMaps',
      creator: 'Sirius GeoMaps',
      compress: comprimir,
    );
    final normal = pw.Font.helvetica();
    final negrita = pw.Font.helveticaBold();
    final gris = PdfColor.fromInt(0xFF555555);
    final verde = PdfColor.fromInt(0xFF1B5E20);

    final vertices = c.esArea && c.linea.length > 1
        ? c.linea.sublist(0, c.linea.length - 1)
        : c.linea;
    final listados = vertices.take(maximoDeVertices).toList();

    documento.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 40),
        theme: pw.ThemeData.withFont(base: normal, bold: negrita),
        footer: (contexto) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Sirius GeoMaps · generado el ${_fecha(c.generadoEn)}',
                style: pw.TextStyle(fontSize: 8, color: gris),
              ),
              pw.Text(
                'Página ${contexto.pageNumber} de ${contexto.pagesCount}',
                style: pw.TextStyle(fontSize: 8, color: gris),
              ),
            ],
          ),
        ),
        build: (contexto) => [
          pw.Text(
            _t(c.tipo).toUpperCase(),
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: verde,
              letterSpacing: 1,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            _t(c.titulo),
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Container(height: 2, color: verde),
          pw.SizedBox(height: 12),

          // Los numeros, en dos columnas de etiqueta y valor.
          pw.Table(
            columnWidths: const {
              0: pw.FixedColumnWidth(150),
              1: pw.FlexColumnWidth(),
            },
            children: [
              for (final d in c.datos)
                pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 3),
                      child: pw.Text(
                        _t(d.etiqueta),
                        style: pw.TextStyle(fontSize: 11, color: gris),
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 3),
                      child: pw.Text(
                        _t(d.valor),
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          pw.SizedBox(height: 12),

          if (c.linea.length >= 2) ...[
            _dibujo(c, verde),
            pw.SizedBox(height: 12),
          ],

          // Las advertencias, del mismo tamano que los numeros: son parte del
          // dato, no letra chica.
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFF3F6F1),
              border: pw.Border(left: pw.BorderSide(color: verde, width: 3)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Para leer bien este informe',
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                for (final nota in c.notas)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 4),
                    child: pw.Text(
                      '- ${_t(nota)}',
                      style: const pw.TextStyle(fontSize: 10.5),
                    ),
                  ),
              ],
            ),
          ),

          if (c.marcas.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            _subtitulo('Puntos marcados'),
            pw.TableHelper.fromTextArray(
              headers: ['N°', 'Nombre', 'Latitud', 'Longitud', 'GPS', 'Nota'],
              data: [
                for (var i = 0; i < c.marcas.length; i++)
                  [
                    '${i + 1}',
                    _t(c.marcas[i].nombre),
                    c.marcas[i].latitud.toStringAsFixed(6),
                    c.marcas[i].longitud.toStringAsFixed(6),
                    c.marcas[i].precisionM == null
                        ? 'a mano'
                        : '± ${c.marcas[i].precisionM!.round()} m',
                    _t(c.marcas[i].nota ?? ''),
                  ],
              ],
              headerStyle: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey300,
              ),
              cellAlignments: const {
                0: pw.Alignment.centerRight,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
              },
              columnWidths: const {
                0: pw.FixedColumnWidth(24),
                1: pw.FlexColumnWidth(2),
                2: pw.FixedColumnWidth(62),
                3: pw.FixedColumnWidth(66),
                4: pw.FixedColumnWidth(44),
                5: pw.FlexColumnWidth(3),
              },
            ),
          ],

          if (c.conTablaDeVertices && listados.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            _subtitulo(c.esArea ? 'Vértices del área' : 'Puntos del recorrido'),
            pw.TableHelper.fromTextArray(
              headers: ['N°', 'Latitud', 'Longitud'],
              data: [
                for (var i = 0; i < listados.length; i++)
                  [
                    '${i + 1}',
                    listados[i].latitud.toStringAsFixed(6),
                    listados[i].longitud.toStringAsFixed(6),
                  ],
              ],
              headerStyle: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey300,
              ),
              cellAlignment: pw.Alignment.centerRight,
              columnWidths: const {
                0: pw.FixedColumnWidth(30),
                1: pw.FixedColumnWidth(90),
                2: pw.FixedColumnWidth(90),
              },
              tableWidth: pw.TableWidth.min,
            ),
          ],
        ],
      ),
    );
    return documento.save();
  }

  static pw.Widget _subtitulo(String texto) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 6),
    child: pw.Text(
      texto,
      style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
    ),
  );

  /// La forma de lo levantado, a escala, con el norte arriba.
  ///
  /// No lleva imagen de fondo: se arma sin red y un satelite en papel carta
  /// no se lee. Lo que da es la forma, la escala y donde quedo cada punto
  /// marcado, que es lo que permite reconocer el lote.
  static pw.Widget _dibujo(ContenidoInforme c, PdfColor color) {
    const ancho = 532.0;
    const alto = 250.0;
    const borde = 22.0;

    // A metros, en un plano local: sobre un predio es indistinguible de
    // hacerlo sobre el elipsoide.
    final todos = [
      ...c.linea,
      for (final m in c.marcas) PuntoGeo(m.latitud, m.longitud),
    ];
    final lat0 = todos.map((p) => p.latitud).reduce(math.min);
    final lon0 = todos.map((p) => p.longitud).reduce(math.min);
    final mPorLon = 111320.0 * math.cos(lat0 * math.pi / 180);
    const mPorLat = 110540.0;
    double mx(PuntoGeo p) => (p.longitud - lon0) * mPorLon;
    double my(PuntoGeo p) => (p.latitud - lat0) * mPorLat;

    final anchoM = todos.map(mx).reduce(math.max);
    final altoM = todos.map(my).reduce(math.max);
    final escala = math.min(
      (ancho - borde * 2) / (anchoM <= 0 ? 1 : anchoM),
      (alto - borde * 2) / (altoM <= 0 ? 1 : altoM),
    );
    // Centrado en el recuadro.
    final dx = (ancho - anchoM * escala) / 2;
    final dy = (alto - altoM * escala) / 2;
    double x(PuntoGeo p) => dx + mx(p) * escala;
    double y(PuntoGeo p) => dy + my(p) * escala;

    // La barra de escala: una medida redonda que entre en un tercio.
    var barraM = 1.0;
    for (final base in [1.0, 2.0, 5.0]) {
      for (var exp = 0; exp < 7; exp++) {
        final m = base * math.pow(10, exp);
        if (m * escala <= ancho * 0.3 && m > barraM) barraM = m.toDouble();
      }
    }

    return pw.Container(
      width: ancho,
      height: alto,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey500, width: 0.5),
      ),
      child: pw.Stack(
        children: [
          pw.CustomPaint(
            size: const PdfPoint(ancho, alto),
            painter: (lienzo, _) {
              lienzo
                ..setLineWidth(1.6)
                ..setStrokeColor(color)
                ..setFillColor(PdfColor.fromInt(0xFFDDEBD9))
                ..moveTo(x(c.linea.first), y(c.linea.first));
              for (final p in c.linea.skip(1)) {
                lienzo.lineTo(x(p), y(p));
              }
              if (c.esArea) {
                lienzo.fillAndStrokePath(close: true);
              } else {
                lienzo.strokePath();
              }
              // Los puntos marcados, encima.
              lienzo
                ..setFillColor(PdfColors.black)
                ..setStrokeColor(PdfColors.white)
                ..setLineWidth(1);
              for (final m in c.marcas) {
                final p = PuntoGeo(m.latitud, m.longitud);
                lienzo
                  ..drawEllipse(x(p), y(p), 3.2, 3.2)
                  ..fillAndStrokePath();
              }
              // La flecha del norte, arriba a la derecha.
              const fx = ancho - 18;
              lienzo
                ..setStrokeColor(PdfColors.black)
                ..setFillColor(PdfColors.black)
                ..setLineWidth(1.2)
                ..drawLine(fx, alto - 44, fx, alto - 22)
                ..strokePath()
                ..moveTo(fx, alto - 12)
                ..lineTo(fx - 4.5, alto - 23)
                ..lineTo(fx + 4.5, alto - 23)
                ..fillPath();
            },
          ),
          for (var i = 0; i < c.marcas.length; i++)
            pw.Positioned(
              left: x(PuntoGeo(c.marcas[i].latitud, c.marcas[i].longitud)) + 5,
              bottom:
                  y(PuntoGeo(c.marcas[i].latitud, c.marcas[i].longitud)) + 2,
              child: pw.Text(
                '${i + 1}',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          pw.Positioned(
            right: 14,
            top: 46,
            child: pw.Text(
              'N',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Positioned(
            left: 10,
            bottom: 8,
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Container(
                  width: barraM * escala,
                  height: 3,
                  color: PdfColors.black,
                ),
                pw.SizedBox(width: 5),
                pw.Text(
                  barraM >= 1000
                      ? '${_numero(barraM / 1000, 0)} km'
                      : '${_numero(barraM, 0)} m',
                  style: const pw.TextStyle(fontSize: 9),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fecha(DateTime momento) =>
      DateFormat('dd/MM/yyyy HH:mm').format(momento.toLocal());

  static String? _duracion(DateTime? inicio, DateTime? fin) {
    if (inicio == null || fin == null) return null;
    final minutos = fin.difference(inicio).inMinutes;
    if (minutos < 1) return null;
    if (minutos < 60) return '$minutos min';
    final resto = minutos % 60;
    return resto == 0 ? '${minutos ~/ 60} h' : '${minutos ~/ 60} h $resto min';
  }

  static String _oSin(String? texto, String sin) {
    final limpio = texto?.trim() ?? '';
    return limpio.isEmpty ? sin : limpio;
  }

  /// Un numero como se escribe aca: coma decimal y punto de miles.
  static String _numero(double valor, int decimales) {
    final partes = valor.toStringAsFixed(decimales).split('.');
    final entero = partes[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => '.',
    );
    return decimales == 0 ? entero : '$entero,${partes[1]}';
  }

  /// El texto que las fuentes del PDF saben dibujar.
  ///
  /// Las fuentes que trae el formato cubren el espanol entero -tildes, enie,
  /// el signo de mas o menos- pero no un emoji ni una letra de otro alfabeto,
  /// y con una sola que no conozcan el documento entero no se arma. Un nombre
  /// de punto con una carita no puede dejar a alguien sin su informe: lo que
  /// no se puede dibujar sale como un signo de pregunta.
  static String _t(String texto) {
    final b = StringBuffer();
    for (final r in texto.runes) {
      final imprimible = (r >= 0x20 && r <= 0x7E) || (r >= 0xA1 && r <= 0xFF);
      b.write(imprimible || r == 0x0A ? String.fromCharCode(r) : '?');
    }
    return b.toString();
  }
}
