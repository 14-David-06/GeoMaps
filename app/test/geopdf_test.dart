import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/geopdf.dart';

/// La lectura de la georreferencia de un GeoPDF.
///
/// Los casos inventados se escriben a mano porque son los que fijan las reglas
/// -que pasa si falta el dato, si viene al reves, si esta comprimido- y no
/// dependen de tener a mano un plano confidencial.
///
/// Al final se lee el plano real de Guaicaramo si esta en la maquina. Ese es el
/// unico que prueba que esto sirve para el archivo que manda topografia, y no
/// solo para lo que yo imagine que manda topografia.
void main() {
  Uint8List pdf(String cuerpo) =>
      Uint8List.fromList('%PDF-1.6\n$cuerpo'.codeUnits);

  /// Un GeoPDF minimo con la misma forma que los de topografia: el BBox con la
  /// Y mayor primero y el /Measure en un objeto aparte.
  String armado({
    String bbox = '[10 900 700 100]',
    String gpts =
        '[4.20 -73.10 4.60 -73.10 4.60 -72.90 4.20 -72.90]',
    String limites = '[0 1 0 0 1 0 1 1]',
  }) =>
      '39 0 obj\n<</Type/Page/MediaBox [0 0 720 1000]'
      '/VP[<</Type/Viewport/BBox$bbox/Measure 38 0 R >>]>>\nendobj\n'
      '38 0 obj\n<</Type/Measure/Subtype/GEO/Bounds$limites'
      '/GPTS$gpts/GCS 37 0 R>>\nendobj\n';

  group('lee la ubicacion', () {
    test('empareja cada esquina con su fraccion', () {
      final g = GeoPdf.leer(pdf(armado()));

      // Lo que importa: el norte arriba y el oeste a la izquierda. Una esquina
      // cambiada dibuja el plano espejado y nadie lo nota hasta caminar hacia
      // el lado equivocado.
      expect(g.noroeste.latitude, 4.60);
      expect(g.noroeste.longitude, -73.10);
      expect(g.noreste.longitude, -72.90);
      expect(g.sureste.latitude, 4.20);
      expect(g.suroeste.longitude, -73.10);
    });

    test('el recuadro queda normalizado aunque venga al reves', () {
      final g = GeoPdf.leer(pdf(armado()));
      expect(g.recuadro.abajo, 100);
      expect(g.recuadro.arriba, 900);
      expect(g.recuadro.ancho, 690);
      expect(g.pagina.ancho, 720);
      expect(g.pagina.alto, 1000);
    });

    test('sin /Bounds asume el recuadro entero', () {
      final sinLimites = armado().replaceAll('/Bounds[0 1 0 0 1 0 1 1]', '');
      final g = GeoPdf.leer(pdf(sinLimites));
      expect(g.noroeste.latitude, 4.60);
      expect(g.sureste.latitude, 4.20);
    });
  });

  group('se planta y dice por que', () {
    test('un PDF sin georreferencia', () {
      expect(
        () => GeoPdf.leer(pdf('39 0 obj\n<</Type/Page/MediaBox [0 0 720 1000]>>')),
        throwsA(
          isA<GeoPdfInvalido>().having(
            (e) => e.motivo,
            'motivo',
            contains('sin coordenadas'),
          ),
        ),
      );
    });

    test('un PDF protegido con clave', () {
      expect(
        () => GeoPdf.leer(pdf('<</Encrypt 9 0 R>>${armado()}')),
        throwsA(
          isA<GeoPdfInvalido>().having(
            (e) => e.motivo,
            'motivo',
            contains('protegido'),
          ),
        ),
      );
    });

    test('un PDF con la georreferencia comprimida', () {
      // Sin GPTS legibles y con objetos comprimidos: es el caso que hay que
      // mandar a convertir al computador, y el mensaje tiene que decirlo.
      final comprimido = '39 0 obj\n<</Type/Page/MediaBox [0 0 720 1000]'
          '/VP[<</Type/Viewport/BBox[10 900 700 100]/Measure 38 0 R >>]>>\n'
          'endobj\n38 0 obj\n<</Type/ObjStm/N 4>>\nendobj\n';
      expect(
        () => GeoPdf.leer(pdf(comprimido)),
        throwsA(
          isA<GeoPdfInvalido>().having(
            (e) => e.motivo,
            'motivo',
            contains('computador'),
          ),
        ),
      );
    });

    test('un area georreferenciada que no es un rectangulo', () {
      final raro = armado(limites: '[0 1 0 0 1 0 0.5 0.5]');
      expect(
        () => GeoPdf.leer(pdf(raro)),
        throwsA(isA<GeoPdfInvalido>()),
      );
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
