import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/geopdf.dart';
import 'package:geomaps/core/importar_geopdf.dart';

/// La lectura de la georreferencia de un GeoPDF.
///
/// Los casos inventados se escriben a mano porque son los que fijan las reglas
/// -que pasa si falta el dato, si viene al reves, si esta comprimido- y no
/// dependen de tener a mano un plano confidencial. Cada uno copia la forma en
/// que un programa de verdad escribe el archivo: el de topografia, QGIS,
/// ArcGIS Pro, Global Mapper.
///
/// Al final se lee el plano real de Guaicaramo si esta en la maquina. Ese es el
/// unico que prueba que esto sirve para el archivo que manda topografia, y no
/// solo para lo que yo imagine que manda topografia.
void main() {
  Uint8List pdf(String cuerpo) =>
      Uint8List.fromList('%PDF-1.6\n$cuerpo'.codeUnits);

  /// Las cuatro esquinas de un predio de mentira, en el orden en que las
  /// escriben los programas: suroeste, noroeste, noreste, sureste.
  const gptsPredio = '[4.20 -73.10 4.60 -73.10 4.60 -72.90 4.20 -72.90]';

  /// Un GeoPDF minimo con la misma forma que los de topografia: el BBox con la
  /// Y mayor primero y el /Measure en un objeto aparte.
  String armado({
    String bbox = '[10 900 700 100]',
    String gpts = gptsPredio,
    String limites = '[0 1 0 0 1 0 1 1]',
    String pagina = '',
  }) =>
      '39 0 obj\n<</Type/Page/MediaBox [0 0 720 1000]$pagina'
      '/VP[<</Type/Viewport/BBox$bbox/Measure 38 0 R >>]>>\nendobj\n'
      '38 0 obj\n<</Type/Measure/Subtype/GEO/Bounds$limites'
      '/GPTS$gpts/GCS 37 0 R>>\nendobj\n';

  Matcher cerca(double valor) => closeTo(valor, 1e-6);

  group('lee la ubicacion', () {
    test('empareja cada esquina con su fraccion', () {
      final g = GeoPdf.leer(pdf(armado()));

      // Lo que importa: el norte arriba y el oeste a la izquierda. Una esquina
      // cambiada dibuja el plano espejado y nadie lo nota hasta caminar hacia
      // el lado equivocado.
      expect(g.noroeste.latitude, cerca(4.60));
      expect(g.noroeste.longitude, cerca(-73.10));
      expect(g.noreste.longitude, cerca(-72.90));
      expect(g.sureste.latitude, cerca(4.20));
      expect(g.suroeste.longitude, cerca(-73.10));
      expect(g.aviso, isNull);
    });

    test('el recuadro queda normalizado aunque venga al reves', () {
      final g = GeoPdf.leer(pdf(armado()));
      expect(g.recuadro.abajo, 100);
      expect(g.recuadro.arriba, 900);
      expect(g.recuadro.ancho, 690);
      expect(g.pagina.ancho, 720);
      expect(g.pagina.alto, 1000);
    });

    test('el recorte se mide desde arriba, como dibuja el motor', () {
      // El PDF mide desde abajo y el motor desde arriba. Olvidar la vuelta
      // recorta la franja opuesta de la hoja, y como casi siempre hay plano a
      // ambos lados, el error pasa por "quedo corrido".
      final r = GeoPdf.leer(pdf(armado(bbox: '[10 950 700 100]'))).recorte;
      expect(r.x, 10);
      expect(r.y, 50);
      expect(r.ancho, 690);
      expect(r.alto, 850);
    });

    test('sin /Bounds asume el recuadro entero', () {
      final sinLimites = armado().replaceAll('/Bounds[0 1 0 0 1 0 1 1]', '');
      final g = GeoPdf.leer(pdf(sinLimites));
      expect(g.noroeste.latitude, cerca(4.60));
      expect(g.sureste.latitude, cerca(4.20));
    });

    test('un BBox escrito de abajo hacia arriba', () {
      // Como lo escribe GDAL: la fraccion (0,0) es la esquina de abajo, y el
      // (0,1) con el que empieza LPTS es la de arriba. Los mismos numeros que
      // en el plano de topografia, y el plano tiene que quedar igual de
      // derecho.
      final g = GeoPdf.leer(
        pdf(
          armado(
            bbox: '[10 100 700 900]',
            gpts: '[4.60 -73.10 4.20 -73.10 4.20 -72.90 4.60 -72.90]',
          ),
        ),
      );
      expect(g.noroeste.latitude, cerca(4.60));
      expect(g.noroeste.longitude, cerca(-73.10));
      expect(g.sureste.latitude, cerca(4.20));
      expect(g.sureste.longitude, cerca(-72.90));
    });

    test('un contorno que no es un rectangulo igual se ubica', () {
      // Tres esquinas y un punto del medio: no hay cuatro esquinas que
      // emparejar, pero la transformacion sale igual de los puntos que haya.
      final g = GeoPdf.leer(
        pdf(
          armado(
            limites: '[0 1 0 0 1 0 0.5 0.5]',
            gpts: '[4.20 -73.10 4.60 -73.10 4.60 -72.90 4.40 -73.00]',
          ),
        ),
      );
      expect(g.noroeste.latitude, closeTo(4.60, 1e-4));
      expect(g.sureste.latitude, closeTo(4.20, 1e-4));
      expect(g.sureste.longitude, closeTo(-72.90, 1e-4));
    });

    test('LPTS manda sobre Bounds, y Bounds define el recorte', () {
      // Los puntos de control estan en las esquinas del BBox, pero el mapa
      // -el contorno- ocupa solo el 80% del medio. Se recorta al contorno, y
      // sus esquinas se calculan, no se copian del archivo.
      final g = GeoPdf.leer(
        pdf(
          '39 0 obj\n<</Type/Page/MediaBox [0 0 1000 1000]'
          '/VP[<</Type/Viewport/BBox[0 1000 1000 0]/Measure 38 0 R >>]>>\n'
          'endobj\n38 0 obj\n<</Type/Measure/Subtype/GEO'
          '/Bounds[0.1 0.9 0.1 0.1 0.9 0.1 0.9 0.9]/LPTS[0 1 0 0 1 0 1 1]'
          '/GPTS$gptsPredio>>\nendobj\n',
        ),
      );
      expect(g.recuadro.izquierda, cerca(100));
      expect(g.recuadro.arriba, cerca(900));
      expect(g.noroeste.longitude, closeTo(-73.08, 1e-4));
      expect(g.noroeste.latitude, closeTo(4.56, 1e-4));
      expect(g.sureste.longitude, closeTo(-72.92, 1e-4));
      expect(g.sureste.latitude, closeTo(4.24, 1e-4));
    });
  });

  group('lee lo que escriben otros programas', () {
    test('el viewport como referencia a otro objeto (QGIS, GDAL)', () {
      // `/VP [ 7 0 R ]`: el viewport no esta adentro de la pagina. Buscando
      // el texto `/BBox` despues de `/VP` no se encuentra nada.
      final g = GeoPdf.leer(
        pdf(
          '7 0 obj\n<< /BBox [ 10 100 700 900 ] /Measure 8 0 R '
          '/Type /Viewport >>\nendobj\n'
          '8 0 obj\n<< /Bounds [ 0 1 0 0 1 0 1 1 ] '
          '/GPTS [ 4.60 -73.10 4.20 -73.10 4.20 -72.90 4.60 -72.90 ] '
          '/LPTS [ 0 1 0 0 1 0 1 1 ] /Subtype /GEO /Type /Measure >>\n'
          'endobj\n'
          '3 0 obj\n<< /MediaBox [ 0 0 720 1000 ] /Parent 1 0 R '
          '/Type /Page /VP [ 7 0 R ] >>\nendobj\n'
          '1 0 obj\n<< /Count 1 /Kids [ 3 0 R ] /Type /Pages >>\nendobj\n'
          '2 0 obj\n<< /Pages 1 0 R /Type /Catalog >>\nendobj\n'
          'trailer\n<< /Root 2 0 R /Size 9 >>\n',
        ),
      );
      expect(g.noroeste.latitude, cerca(4.60));
      expect(g.sureste.longitude, cerca(-72.90));
      expect(g.recuadro.ancho, 690);
    });

    test('los diccionarios comprimidos (ArcGIS Pro, Acrobat)', () {
      // Ni `/VP` ni `/GPTS` aparecen como texto en el archivo: estan adentro
      // de un flujo comprimido. Antes esto se rechazaba como "sin
      // coordenadas", que es justo lo contrario de lo que pasa.
      final bytes = _conFlujoDeObjetos({
        1: '<</Type/Pages/Count 1/Kids[3 0 R]/MediaBox[0 0 720 1000]>>',
        2: '<</Type/Catalog/Pages 1 0 R>>',
        3: '<</Type/Page/Parent 1 0 R/VP[7 0 R]>>',
        7: '<</Type/Viewport/BBox[10 900 700 100]/Measure 8 0 R>>',
        8: '<</Type/Measure/Subtype/GEO/Bounds[0 1 0 0 1 0 1 1]'
            '/GPTS$gptsPredio>>',
      }, despues: 'trailer\n<</Root 2 0 R>>\n');
      expect(String.fromCharCodes(bytes), isNot(contains('/GPTS')));

      final g = GeoPdf.leer(bytes);
      expect(g.noroeste.latitude, cerca(4.60));
      expect(g.sureste.longitude, cerca(-72.90));
      // El tamano de la hoja lo hereda del arbol de paginas.
      expect(g.pagina.alto, 1000);
    });

    test('la georreferencia de TerraGo, que hay que proyectar', () {
      // Los numeros son los de un plano en MAGNA-SIRGAS Bogota exportado con
      // GDAL: una matriz que lleva el papel a metros y la proyeccion
      // descripta, sin una sola latitud escrita. Las esquinas esperadas son
      // las que el mismo GDAL informa para ese plano.
      final g = GeoPdf.leer(
        pdf(
          '7 0 obj\n<< /CTM [ (12.5) 0 0 (12.5) 1093887 972448 ] '
          '/Neatline [ 60 (2459.2) 60 40 (3080.4) 40 (3080.4) (2459.2) ] '
          '/Projection << /CentralMeridian (-74.0775079166667) '
          '/Datum << /Ellipsoid << /InvFlattening (298.257222101) '
          '/SemiMajorAxis 6378137 >> >> /FalseEasting 1000000 '
          '/FalseNorthing 1000000 /OriginLatitude (4.59620041666667) '
          '/ProjectionType (TC) /ScaleFactor 1 /Type /Projection '
          '/Units (M) >> /Type /LGIDict /Version (2.1) >>\nendobj\n'
          '3 0 obj\n<< /LGIDict 7 0 R /MediaBox [ 0 0 3220.4 2549.2 ] '
          '/Type /Page >>\nendobj\n',
        ),
      );
      // Un mapa de 37 km no es un paralelogramo perfecto sobre Mercator: el
      // ajuste reparte unos pocos metros entre las cuatro esquinas.
      expect(g.noroeste.latitude, closeTo(4.62451627, 5e-5));
      expect(g.noroeste.longitude, closeTo(-73.22464245, 5e-5));
      expect(g.sureste.latitude, closeTo(4.35061999, 5e-5));
      expect(g.sureste.longitude, closeTo(-72.88488217, 5e-5));
      expect(g.recuadro.izquierda, 60);
      expect(g.recuadro.abajo, 40);
    });

    test('una hoja girada', () {
      // La hoja se muestra acostada: lo que el PDF llama abajo-izquierda se
      // ve arriba-izquierda. Las esquinas van en el orden en que se **ve** la
      // imagen, porque asi es como se la apoya sobre el mapa.
      final g = GeoPdf.leer(pdf(armado(pagina: '/Rotate 90')));
      expect(g.rotacion, 90);
      expect(g.anchoVisible, 1000);
      expect(g.altoVisible, 720);
      expect(g.esquinas[0].latitude, cerca(4.20)); // suroeste
      expect(g.esquinas[0].longitude, cerca(-73.10));
      expect(g.esquinas[1].latitude, cerca(4.60)); // noroeste
      expect(g.esquinas[1].longitude, cerca(-73.10));
      expect(g.esquinas[2].longitude, cerca(-72.90)); // noreste
      expect(g.recorte.x, 100);
      expect(g.recorte.y, 10);
      expect(g.recorte.ancho, 800);
      expect(g.recorte.alto, 690);
    });

    test('una hoja recortada con CropBox', () {
      // El motor dibuja solo el CropBox. Medir el recorte contra la hoja
      // entera lo corre exactamente el margen que se le quito.
      final g = GeoPdf.leer(pdf(armado(pagina: '/CropBox [5 50 715 950]')));
      expect(g.anchoVisible, 710);
      expect(g.altoVisible, 900);
      expect(g.recorte.x, 5);
      expect(g.recorte.y, 50);
    });

    test('el mapa principal y no el recuadro de ubicacion', () {
      // Dos mapas en la misma hoja, cada uno con sus coordenadas. El chico va
      // primero en el archivo; gana el grande.
      final g = GeoPdf.leer(
        pdf(
          '39 0 obj\n<</Type/Page/MediaBox [0 0 720 1000]/VP['
          '<</Type/Viewport/BBox[600 990 710 910]/Measure 40 0 R>>'
          '<</Type/Viewport/BBox[10 900 700 100]/Measure 38 0 R>>]>>\n'
          'endobj\n'
          '40 0 obj\n<</Type/Measure/Subtype/GEO/Bounds[0 1 0 0 1 0 1 1]'
          '/GPTS[1 -79 12 -79 12 -67 1 -67]>>\nendobj\n'
          '38 0 obj\n<</Type/Measure/Subtype/GEO/Bounds[0 1 0 0 1 0 1 1]'
          '/GPTS$gptsPredio>>\nendobj\n',
        ),
      );
      expect(g.noroeste.latitude, cerca(4.60));
      expect(g.recuadro.ancho, 690);
    });

    test('la caratula adelante y el mapa en la segunda hoja', () {
      final g = GeoPdf.leer(
        pdf(
          '1 0 obj\n<</Type/Pages/Count 2/Kids[4 0 R 3 0 R]>>\nendobj\n'
          '2 0 obj\n<</Type/Catalog/Pages 1 0 R>>\nendobj\n'
          // El mapa esta antes en el archivo, pero es la segunda hoja.
          '3 0 obj\n<</Type/Page/MediaBox[0 0 720 1000]/Parent 1 0 R'
          '/VP[<</BBox[10 900 700 100]/Measure 8 0 R>>]>>\nendobj\n'
          '4 0 obj\n<</Type/Page/MediaBox[0 0 612 792]/Parent 1 0 R>>\n'
          'endobj\n'
          '8 0 obj\n<</Subtype/GEO/GPTS$gptsPredio>>\nendobj\n'
          'trailer\n<</Root 2 0 R>>\n',
        ),
      );
      expect(g.indicePagina, 1);
      expect(g.pagina.ancho, 720);
    });

    test('una correccion agregada al final del archivo', () {
      // Un PDF se corrige agregando el objeto nuevo atras, sin borrar el
      // viejo. Vale el ultimo.
      final g = GeoPdf.leer(
        pdf(
          '${armado(gpts: '[0 0 1 0 1 1 0 1]')}'
          '38 0 obj\n<</Type/Measure/Subtype/GEO/Bounds[0 1 0 0 1 0 1 1]'
          '/GPTS$gptsPredio>>\nendobj\n',
        ),
      );
      expect(g.noroeste.latitude, cerca(4.60));
    });

    test('avisa cuando el plano esta en el datum viejo', () {
      final g = GeoPdf.leer(
        pdf(
          '${armado()}37 0 obj\n<</Type/PROJCS/WKT(PROJCS["Bogota",'
          'GEOGCS["GCS_Bogota",DATUM["D_Bogota",SPHEROID["International_1924"'
          ',6378388.0,297.0]]]])>>\nendobj\n',
        ),
      );
      expect(g.aviso, contains('300 metros'));
      // MAGNA-SIRGAS tiene "Bogota" en el nombre de la zona, no en el datum:
      // no es el sistema viejo y no tiene que asustar a nadie.
      final magna = GeoPdf.leer(
        pdf(
          '${armado()}37 0 obj\n<</Type/PROJCS/EPSG 3116'
          '/WKT(PROJCS["MAGNA_Colombia_Bogota",GEOGCS["GCS_MAGNA",'
          'DATUM["D_MAGNA",SPHEROID["GRS_1980",6378137.0,298.257222101]]]])>>'
          '\nendobj\n',
        ),
      );
      expect(magna.aviso, isNull);
    });
  });

  group('se planta y dice por que', () {
    Matcher rechaza(String fragmento) => throwsA(
      isA<GeoPdfInvalido>().having((e) => e.motivo, 'motivo', contains(fragmento)),
    );

    test('un PDF sin georreferencia', () {
      expect(
        () => GeoPdf.leer(
          pdf('39 0 obj\n<</Type/Page/MediaBox [0 0 720 1000]>>\nendobj\n'),
        ),
        rechaza('sin coordenadas'),
      );
    });

    test('un archivo que no es un PDF', () {
      expect(
        () => GeoPdf.leer(Uint8List.fromList('PK\x03\x04 un zip'.codeUnits)),
        rechaza('no es un PDF'),
      );
    });

    test('un PDF protegido que esconde sus diccionarios', () {
      // Cifrado y con los objetos comprimidos: lo que hay adentro del flujo
      // no se puede abrir, y el mensaje tiene que decir que es por la clave y
      // no que el plano no tiene coordenadas.
      final basura = List<int>.generate(64, (i) => (i * 37 + 11) & 0xFF);
      final bytes = BytesBuilder()
        ..add(
          '%PDF-1.6\n5 0 obj\n<</Type/ObjStm/N 3/First 20/Filter/FlateDecode'
                  '/Length 64>>\nstream\n'
              .codeUnits,
        )
        ..add(basura)
        ..add(
          '\nendstream\nendobj\ntrailer\n<</Root 2 0 R/Encrypt 9 0 R>>\n'
              .codeUnits,
        );
      expect(() => GeoPdf.leer(bytes.toBytes()), rechaza('protegido'));
    });

    test('un PDF protegido con los diccionarios en claro igual se lee', () {
      // La proteccion cifra las cadenas y los flujos, no los numeros: las
      // coordenadas siguen ahi. Si ademas pide clave para abrirse, eso lo
      // dice el motor al dibujar.
      final g = GeoPdf.leer(
        pdf('${armado()}trailer\n<</Encrypt 9 0 R>>\n'),
      );
      expect(g.noroeste.latitude, cerca(4.60));
    });

    test('una proyeccion que el telefono no conoce', () {
      expect(
        () => GeoPdf.leer(
          pdf(
            '3 0 obj\n<</Type/Page/MediaBox[0 0 720 1000]/LGIDict<<'
            '/CTM[1 0 0 1 0 0]/Projection<</ProjectionType(AC)>>>>>>\n'
            'endobj\n',
          ),
        ),
        rechaza('proyeccion (AC)'),
      );
    });

    test('coordenadas que no son latitud y longitud', () {
      expect(
        () => GeoPdf.leer(
          pdf(
            armado(
              gpts: '[972948 1094637 1003188 1094637 1003188 1132392 '
                  '972948 1132392]',
            ),
          ),
        ),
        rechaza('no son latitud y longitud'),
      );
    });

    test('puntos que no alcanzan para ubicar el plano', () {
      // Dos puntos sobre el mismo borde: se sabe el alto y nada del ancho.
      expect(
        () => GeoPdf.leer(pdf(armado(gpts: '[4.20 -73.10 4.60 -73.10]'))),
        rechaza('incompletas'),
      );
    });
  });

  group('el tamano de la imagen', () {
    GeoPdf hoja(String mediaBox, String bbox) => GeoPdf.leer(
      pdf(
        '39 0 obj\n<</Type/Page/MediaBox $mediaBox'
        '/VP[<</BBox$bbox/Measure 38 0 R>>]>>\nendobj\n'
        '38 0 obj\n<</Subtype/GEO/GPTS$gptsPredio>>\nendobj\n',
      ),
    );

    test('un plano de doble carta sale a 200 puntos por pulgada', () {
      final g = hoja('[0 0 1224 792]', '[36 756 1188 36]');
      final e = ImportadorGeoPdf.encuadre(g, anchoHoja: 1224, altoHoja: 792);
      expect(e.anchoPx, 3200); // 1152 pt = 16 pulgadas
      expect(e.altoPx, 2000);
      expect(e.x, 36);
      expect(e.y, 36);
    });

    test('un pliego cartografico se frena en el tope', () {
      // Un pliego a 200 DPI serian 60 millones de pixeles. Lo que mata la app
      // no es dibujarlo: es tenerlo abierto cada vez que la capa esta
      // encendida.
      final g = hoja('[0 0 3370 2384]', '[60 2300 3300 80]');
      final e = ImportadorGeoPdf.encuadre(g, anchoHoja: 3370, altoHoja: 2384);
      expect(e.anchoPx, ImportadorGeoPdf.ladoMaximo);
      expect(e.altoPx, lessThan(ImportadorGeoPdf.ladoMaximo));
      expect(e.anchoPx / e.altoPx, closeTo(3240 / 2220, 0.01));
    });

    test('el recorte se lleva a la medida del motor', () {
      // El motor informa la hoja al doble: el PDF usa una unidad propia. El
      // rectangulo que se le pide tiene que ir en su medida, no en la nuestra.
      final g = hoja('[0 0 1000 1000]', '[100 900 900 100]');
      final e = ImportadorGeoPdf.encuadre(g, anchoHoja: 2000, altoHoja: 2000);
      expect(e.x, 200);
      expect(e.ancho, 1600);
      // Y el redondeo a puntos enteros no cuenta como otra escala.
      final justo = ImportadorGeoPdf.encuadre(g, anchoHoja: 999, altoHoja: 1001);
      expect(justo.x, 100);
      expect(justo.ancho, 800);
    });
  });

  /// El plano de verdad. Confidencial: no esta en el repositorio y aca no se
  /// escribe ninguna coordenada suya, solo se comprueba que sea coherente.
  group('el plano real de topografia', () {
    final plano = _planoDeTopografia();

    test('se lee y cae donde debe', () {
      final g = GeoPdf.leer(plano!.readAsBytesSync());

      // Guaicaramo esta en el Meta: al norte del ecuador y al oeste de
      // Greenwich. Un signo cambiado manda el plano al otro hemisferio.
      for (final e in g.esquinas) {
        expect(e.latitude, inInclusiveRange(3.5, 5.5));
        expect(e.longitude, inInclusiveRange(-74.5, -72.0));
      }

      expect(g.noroeste.latitude, greaterThan(g.suroeste.latitude));
      expect(g.noreste.latitude, greaterThan(g.sureste.latitude));
      expect(g.noreste.longitude, greaterThan(g.noroeste.longitude));
      expect(g.sureste.longitude, greaterThan(g.suroeste.longitude));

      // El area georreferenciada es una parte de la hoja, no la hoja entera:
      // el marco y el membrete quedan afuera. Si esto fallara, el plano se
      // dibujaria estirado sobre el terreno.
      expect(g.recuadro.ancho, lessThan(g.pagina.ancho));
      expect(g.recuadro.alto, lessThan(g.pagina.alto));
    }, skip: plano != null ? false : 'no esta el plano en esta maquina');
  });
}

/// Un PDF cuyos objetos van todos adentro de un flujo comprimido, como los
/// deja cualquier programa que "optimiza" el archivo. [objetos] es numero ->
/// cuerpo; [despues] se agrega suelto al final.
Uint8List _conFlujoDeObjetos(Map<int, String> objetos, {String despues = ''}) {
  final cabecera = StringBuffer();
  final cuerpos = StringBuffer();
  objetos.forEach((numero, cuerpo) {
    cabecera.write('$numero ${cuerpos.length} ');
    cuerpos.write('$cuerpo\n');
  });
  final comprimido = zlib.encode('$cabecera$cuerpos'.codeUnits);
  return (BytesBuilder()
        ..add(
          '%PDF-1.5\n50 0 obj\n<</Type/ObjStm/N ${objetos.length}'
                  '/First ${cabecera.length}/Filter/FlateDecode'
                  '/Length ${comprimido.length}>>\nstream\n'
              .codeUnits,
        )
        ..add(comprimido)
        ..add('\nendstream\nendobj\n$despues'.codeUnits))
      .toBytes();
}

/// Donde cada quien tenga el plano: primero la variable `PLANO_GEOPDF`, y si
/// no, cualquier PDF de acopios en las descargas. La ruta no se escribe a mano
/// en el codigo, que es como una prueba pasa en una sola maquina y falla en
/// todas las demas.
File? _planoDeTopografia() {
  final declarado = Platform.environment['PLANO_GEOPDF'];
  if (declarado != null && declarado.isNotEmpty) {
    final f = File(declarado);
    return f.existsSync() ? f : null;
  }

  final casa =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (casa == null) return null;

  final descargas = Directory('$casa/Downloads');
  if (!descargas.existsSync()) return null;

  for (final e in descargas.listSync()) {
    final nombre = e.path.toLowerCase();
    if (e is File && nombre.endsWith('.pdf') && nombre.contains('acopios')) {
      return e;
    }
  }
  return null;
}
