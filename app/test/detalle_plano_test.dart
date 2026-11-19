import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/detalle_plano.dart';
import 'package:geomaps/core/geopdf.dart';
import 'package:geomaps/core/importar_geopdf.dart';
import 'package:geomaps/core/motor_planos.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/mapas_repository.dart';
import 'package:geomaps/state/afinado.dart';
import 'package:geomaps/ui/capa_pdf.dart';
import 'package:latlong2/latlong.dart';

/// Un dibujado que se le pidio al motor.
class _Pedido {
  const _Pedido({
    required this.x,
    required this.y,
    required this.ancho,
    required this.alto,
    required this.anchoPx,
    required this.altoPx,
    required this.destino,
    required this.destinoSinFondo,
    required this.papel,
  });

  final double x;
  final double y;
  final double ancho;
  final double alto;
  final int anchoPx;
  final int altoPx;
  final String destino;
  final String? destinoSinFondo;
  final List<int>? papel;
}

/// El motor de PDF del telefono, de mentira: anota lo que le piden dibujar y
/// deja un archivo donde iria la imagen.
class _MotorAnotado extends MotorPlanos {
  _MotorAnotado({this.anchoHoja = 3370, this.altoHoja = 2384});

  final double anchoHoja;
  final double altoHoja;
  final pedidos = <_Pedido>[];

  /// Si la hoja tiene un papel blanco que quitar.
  bool conPapel = true;

  /// Cuanto pesa la imagen entera, en bytes por pixel: un dibujo pesa poco y
  /// una foto mucho.
  double pesoPorPixel = 0.05;

  /// El numero de dibujado que falla, contando desde 1. Nulo: ninguno.
  int? fallaEl;

  /// Se llama antes de cada dibujado, con cuantos van.
  void Function(int van)? antes;

  @override
  Future<HojaPdf> hoja(String ruta, int pagina) async =>
      HojaPdf(paginas: 1, ancho: anchoHoja, alto: altoHoja);

  @override
  Future<Dibujo> dibujar({
    required String ruta,
    required int pagina,
    required double x,
    required double y,
    required double ancho,
    required double alto,
    required int anchoPx,
    required int altoPx,
    required String destino,
    String? destinoSinFondo,
    List<int>? papel,
  }) async {
    antes?.call(pedidos.length);
    pedidos.add(
      _Pedido(
        x: x,
        y: y,
        ancho: ancho,
        alto: alto,
        anchoPx: anchoPx,
        altoPx: altoPx,
        destino: destino,
        destinoSinFondo: destinoSinFondo,
        papel: papel,
      ),
    );
    if (fallaEl == pedidos.length) {
      throw const GeoPdfInvalido('El plano es demasiado pesado.');
    }
    if (!File(ruta).existsSync()) {
      throw const GeoPdfInvalido('El telefono no pudo abrir este PDF.');
    }
    // Un archivo del peso que tendria la imagen, sin escribirlo byte a byte.
    File(destino).openSync(mode: FileMode.write)
      ..truncateSync((anchoPx * altoPx * pesoPorPixel).ceil())
      ..closeSync();
    final quita = destinoSinFondo != null && conPapel;
    if (quita) File(destinoSinFondo).writeAsBytesSync(const [0]);
    return Dibujo(
      sinFondo: quita,
      papel: conPapel ? (papel ?? const [255, 255, 255]) : null,
    );
  }
}

/// El detalle de los planos grandes: la hoja dibujada mas grande, en cuadros.
///
/// Un pliego cartografico entra en el telefono como una imagen de 4096
/// pixeles, que son menos de 90 puntos por pulgada: de cerca los rotulos no
/// se leen. El detalle los deja legibles. Lo que se cuida:
///
/// - que solo se haga cuando sirve -una hoja chica ya sale nitida, y una
///   ortofoto pesa demasiado para lo que gana-;
/// - que los cuadros cubran la hoja entera y caigan **exactamente** donde cae
///   la imagen entera, porque sobre un plano se ubican linderos;
/// - que cerrar la app en la mitad no pierda lo hecho ni deje el plano roto.
void main() {
  late Directory carpeta;

  setUp(() => carpeta = Directory.systemTemp.createTempSync('detalle_plano_'));
  tearDown(() {
    try {
      carpeta.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows a veces tarda en soltar un archivo recien escrito.
    }
  });

  /// Un pliego: 3240 x 2220 puntos de plano, con su imagen entera al tope.
  DetallePlano pliego() => DetallePlano.para(
    anchoPt: 3240,
    altoPt: 2220,
    anchoVista: 4096,
    altoVista: 2807,
  )!;

  String vista([String nombre = 'plano']) => '${carpeta.path}/$nombre.png';

  File unPdf([String nombre = 'elegido.pdf']) =>
      File('${carpeta.path}/$nombre')..writeAsStringSync('%PDF-1.6');

  const trabajo = TrabajoDeDetalle(
    pagina: 0,
    x: 60,
    y: 84,
    ancho: 3240,
    alto: 2220,
    lineas: true,
    papel: [255, 255, 255],
  );

  group('cuando se hace', () {
    test('a un pliego, al doble de la imagen entera', () {
      final d = pliego();

      expect(d.ancho, DetallePlano.ladoMaximo);
      expect(d.mejora, closeTo(2, 0.01));
      expect(d.columnas, 8);
      expect(d.filas, 6);
      expect(d.total, 48);
      expect(d.terminado, isTrue, reason: 'sin trabajo no hay que dibujar');
    });

    test('a medio pliego, a 200 puntos por pulgada y no mas', () {
      // 2384 x 1684 puntos: la imagen entera quedo en 4096 (124 por pulgada).
      final d = DetallePlano.para(
        anchoPt: 2384,
        altoPt: 1684,
        anchoVista: 4096,
        altoVista: 2893,
      )!;

      expect(d.ancho, (2384 * 200 / 72).round());
      expect(d.mejora, greaterThan(1.5));
    });

    test('a un plano de topografia no: ya salio con todo su detalle', () {
      // Doble carta, 16 pulgadas de plano: 3200 pixeles a 200 por pulgada.
      final d = DetallePlano.para(
        anchoPt: 1152,
        altoPt: 720,
        anchoVista: 3200,
        altoVista: 2000,
      );

      expect(d, isNull);
    });

    test('ni a una hoja que casi llega: por un 15% no se dibuja de nuevo', () {
      final d = DetallePlano.para(
        anchoPt: 1684,
        altoPt: 1191,
        anchoVista: 4096,
        altoVista: 2897,
      );

      expect(d, isNull);
    });
  });

  group('los cuadros', () {
    test('cubren la hoja entera, montados un pixel y sin salirse', () {
      final d = pliego();
      // Se mira la primera fila de cuadros a lo ancho y la primera columna a
      // lo alto: alcanza para ver que no queda nada sin cubrir, sin recorrer
      // los 46 millones de pixeles de la hoja.
      final columnas = List.filled(d.ancho, 0);
      final filas = List.filled(d.alto, 0);
      for (var i = 0; i < d.total; i++) {
        final p = d.pixeles(i);
        expect(p.x + p.ancho, lessThanOrEqualTo(d.ancho));
        expect(p.y + p.alto, lessThanOrEqualTo(d.alto));
        expect(p.ancho, lessThanOrEqualTo(d.lado + 1));
        if (i < d.columnas) {
          for (var x = p.x; x < p.x + p.ancho; x++) {
            columnas[x]++;
          }
        }
        if (i % d.columnas == 0) {
          for (var y = p.y; y < p.y + p.alto; y++) {
            filas[y]++;
          }
        }
      }
      expect(
        columnas.every((n) => n >= 1),
        isTrue,
        reason: 'columna sin cubrir',
      );
      expect(filas.every((n) => n >= 1), isTrue, reason: 'fila sin cubrir');
      // El monte es de un pixel: nunca tres cuadros sobre la misma columna.
      expect(columnas.every((n) => n <= 2), isTrue);
      expect(columnas.where((n) => n == 2), hasLength(d.columnas - 1));
    });

    test('se piden del centro de la hoja hacia afuera', () {
      final d = pliego();
      final orden = d.pendientes();

      expect(orden, hasLength(48));
      // Los cuatro del medio de una hoja de 8 x 6.
      expect(orden.take(4).toSet(), {19, 20, 27, 28});
      // Las esquinas quedan para el final.
      expect(orden.skip(44).toSet(), {0, 7, 40, 47});
    });

    test('los que ya estan no se vuelven a pedir', () {
      final d = pliego().conListo(19).conListo(20);

      expect(d.pendientes(), hasLength(46));
      expect(d.pendientes(), isNot(contains(19)));
    });

    test('los que tocan una parte de la hoja', () {
      final d = pliego();

      // El cuarto de arriba a la izquierda: 4 columnas por 3 filas.
      final cuarto = d.cuadrosEn(x0: 0, y0: 0, x1: 0.49, y1: 0.49);
      expect(cuarto, [0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19]);
      // Lo que cae afuera de la hoja no cuenta, y lo que se pasa se recorta.
      expect(d.cuadrosEn(x0: 1.2, y0: 0, x1: 1.6, y1: 1), isEmpty);
      expect(d.cuadrosEn(x0: -3, y0: -3, x1: 0.01, y1: 0.01), [0]);
    });
  });

  group('donde cae cada cuadro en el terreno', () {
    // Un plano girado unos grados, como salen los de MAGNA-SIRGAS: noroeste,
    // noreste, sureste y suroeste.
    const plano = [
      LatLng(4.600, -73.100),
      LatLng(4.610, -72.900),
      LatLng(4.210, -72.890),
      LatLng(4.200, -73.090),
    ];

    test('la hoja entera cae en sus esquinas', () {
      final e = esquinasDeParte(plano, x0: 0, y0: 0, x1: 1, y1: 1);

      for (final i in [0, 2, 3]) {
        expect(e[i].latitude, closeTo(plano[i].latitude, 1e-9));
        expect(e[i].longitude, closeTo(plano[i].longitude, 1e-9));
      }
    });

    test('dos cuadros vecinos comparten el borde, sin hueco ni escalon', () {
      final d = pliego();
      final a = d.parte(19, montado: false);
      final b = d.parte(20, montado: false);
      final izquierdo = esquinasDeParte(
        plano,
        x0: a.x0,
        y0: a.y0,
        x1: a.x1,
        y1: a.y1,
      );
      final derecho = esquinasDeParte(
        plano,
        x0: b.x0,
        y0: b.y0,
        x1: b.x1,
        y1: b.y1,
      );

      // El noreste del izquierdo es el noroeste del derecho, y lo mismo abajo.
      expect(izquierdo[1].latitude, closeTo(derecho[0].latitude, 1e-12));
      expect(izquierdo[1].longitude, closeTo(derecho[0].longitude, 1e-12));
      expect(izquierdo[2].latitude, closeTo(derecho[3].latitude, 1e-12));
      expect(izquierdo[2].longitude, closeTo(derecho[3].longitude, 1e-12));
    });

    test('un cuadro cae donde la imagen entera pone ese mismo pedazo', () {
      // El mapa estira la imagen entera derecha sobre el mapa proyectado. El
      // centro de la hoja, calculado por el cuadro que lo tiene en la esquina
      // o repartiendo en grados, no puede diferir en mas que un par de
      // metros; y calculado dos veces por caminos distintos, en nada.
      final centro = esquinasDeParte(plano, x0: 0.5, y0: 0.5, x1: 1, y1: 1)[0];
      final porMitades = esquinasDeParte(
        esquinasDeParte(plano, x0: 0, y0: 0, x1: 0.5, y1: 0.5),
        x0: 1,
        y0: 1,
        x1: 1,
        y1: 1,
      )[0];
      expect(centro.latitude, closeTo(porMitades.latitude, 1e-10));
      expect(centro.longitude, closeTo(porMitades.longitude, 1e-10));

      // En grados seria el promedio del noroeste y el sureste. Queda cerca,
      // pero no igual: por eso no se reparte en grados.
      const metros = Distance();
      final enGrados = LatLng(
        (plano[0].latitude + plano[2].latitude) / 2,
        (plano[0].longitude + plano[2].longitude) / 2,
      );
      expect(metros.distance(centro, enGrados), lessThan(20));
    });
  });

  group('el indice', () {
    test('se guarda y se vuelve a leer igual', () async {
      final d = pliego().conTrabajo(trabajo).conListo(19).conListo(3);
      await d.guardar(vista());

      final leido = DetallePlano.leer(vista())!;
      expect(leido.ancho, d.ancho);
      expect(leido.alto, d.alto);
      expect(leido.anchoVista, 4096);
      expect(leido.listos, {3, 19});
      expect(leido.trabajo!.papel, [255, 255, 255]);
      expect(leido.trabajo!.lineas, isTrue);
      expect(leido.trabajo!.x, 60);
      // No queda el borrador al lado.
      expect(
        File('${DetallePlano.indiceDe(vista())}.nuevo').existsSync(),
        isFalse,
      );
    });

    test('es el mismo se mire la hoja con papel o solo las lineas', () async {
      await pliego().guardar(vista());

      expect(DetallePlano.leer(ArchivosPlano.sinFondo(vista())), isNotNull);
      expect(
        DetallePlano.carpetaDe(ArchivosPlano.sinFondo(vista())),
        DetallePlano.carpetaDe(vista()),
      );
    });

    test('cada version del plano tiene sus cuadros', () {
      final d = pliego();

      expect(d.archivoDe(vista(), 9), endsWith('plano-detalle/f1c1.png'));
      expect(
        d.archivoDe(ArchivosPlano.sinFondo(vista()), 9),
        endsWith('plano-detalle/f1c1-lineas.png'),
      );
    });

    test('un plano sin detalle, o con el indice roto, no tiene', () {
      expect(DetallePlano.leer(vista()), isNull);

      final indice = File(DetallePlano.indiceDe(vista()))
        ..createSync(recursive: true);
      indice.writeAsStringSync('{"v":1,"vista":[40');
      expect(DetallePlano.leer(vista()), isNull);

      indice.writeAsStringSync(
        jsonEncode({
          'v': 1,
          'vista': [0, 0],
          'detalle': [0, 0],
          'lado': 0,
          'listos': <int>[],
        }),
      );
      expect(DetallePlano.leer(vista()), isNull);
    });
  });

  group('al importar', () {
    /// Un GeoPDF minimo, con el plano ocupando casi toda la hoja.
    File geoPdf({required String hoja, required String recuadro}) {
      final archivo = File('${carpeta.path}/origen.pdf');
      archivo.writeAsStringSync(
        '%PDF-1.6\n39 0 obj\n<</Type/Page/MediaBox $hoja'
        '/VP[<</BBox$recuadro/Measure 38 0 R>>]>>\nendobj\n'
        '38 0 obj\n<</Subtype/GEO'
        '/GPTS[4.20 -73.10 4.60 -73.10 4.60 -72.90 4.20 -72.90]>>\nendobj\n',
      );
      return archivo;
    }

    Future<PlanoImportado> importar(_MotorAnotado motor, File pdf) =>
        ImportadorGeoPdf.importar(
          pdf: pdf,
          destino: carpeta,
          codigo: 'plano',
          motor: motor,
        );

    test('a un pliego le queda el detalle por hacer, con su papel', () async {
      final motor = _MotorAnotado();
      final plano = await importar(
        motor,
        geoPdf(hoja: '[0 0 3370 2384]', recuadro: '[60 2300 3300 80]'),
      );

      // La imagen entera se dibuja igual que siempre, de una vez.
      expect(motor.pedidos, hasLength(1));
      expect(plano.ancho, ImportadorGeoPdf.ladoMaximo);

      final d = plano.detalle!;
      expect(d.terminado, isFalse);
      expect(d.listos, isEmpty);
      expect(d.mejora, closeTo(2, 0.01));
      expect(d.trabajo!.papel, [255, 255, 255]);
      expect(d.trabajo!.lineas, isTrue);
      expect(d.trabajo!.x, 60);
      expect(d.trabajo!.ancho, 3240);
    });

    test('a un plano de topografia no se le hace', () async {
      final plano = await importar(
        _MotorAnotado(anchoHoja: 1224, altoHoja: 792),
        geoPdf(hoja: '[0 0 1224 792]', recuadro: '[36 756 1188 36]'),
      );

      expect(plano.detalle, isNull);
    });

    test('a una ortofoto tampoco: pesa como foto y no tiene rotulos', () async {
      final motor = _MotorAnotado()
        ..conPapel = false
        ..pesoPorPixel = 2.4;
      final plano = await importar(
        motor,
        geoPdf(hoja: '[0 0 3370 2384]', recuadro: '[60 2300 3300 80]'),
      );

      expect(plano.detalle, isNull);
    });

    test('ni a un plano escaneado, aunque tenga papel que quitar', () async {
      // Un escaneo es una foto de la hoja: en cuadros serian mas de cien
      // megas en un telefono que ya anda justo de espacio.
      final motor = _MotorAnotado()..pesoPorPixel = 1.6;
      final plano = await importar(
        motor,
        geoPdf(hoja: '[0 0 3370 2384]', recuadro: '[60 2300 3300 80]'),
      );

      expect(plano.detalle, isNull);
    });

    test('a un plano que ya venia sin papel si: es un dibujo', () async {
      final motor = _MotorAnotado()..conPapel = false;
      final plano = await importar(
        motor,
        geoPdf(hoja: '[0 0 3370 2384]', recuadro: '[60 2300 3300 80]'),
      );

      expect(plano.detalle, isNotNull);
      expect(plano.detalle!.trabajo!.lineas, isFalse);
      expect(plano.detalle!.trabajo!.papel, isNull);
    });
  });

  group('dibujar los cuadros', () {
    test('entre todos dibujan el plano entero, y ninguno otra cosa', () async {
      final motor = _MotorAnotado();
      final d = pliego().conTrabajo(trabajo);

      final fin = await ImportadorGeoPdf.afinar(
        rutaVista: vista(),
        detalle: d,
        pdf: unPdf(),
        motor: motor,
      );

      expect(motor.pedidos, hasLength(48));
      expect(fin.terminado, isTrue);
      expect(fin.listos, hasLength(48));
      expect(DetallePlano.leer(vista())!.terminado, isTrue);

      var izquierda = double.infinity;
      var arriba = double.infinity;
      var derecha = 0.0;
      var abajo = 0.0;
      for (final p in motor.pedidos) {
        // Cada cuadro a la misma escala que los demas: si no, no empalman.
        expect(p.anchoPx / p.ancho, closeTo(d.ancho / trabajo.ancho, 1e-6));
        expect(p.altoPx / p.alto, closeTo(d.alto / trabajo.alto, 1e-6));
        expect(p.anchoPx, lessThanOrEqualTo(DetallePlano.ladoDeCuadro + 1));
        // Todos quitan el mismo papel, el que se vio en la hoja entera.
        expect(p.papel, [255, 255, 255]);
        expect(p.destinoSinFondo, ArchivosPlano.sinFondo(p.destino));
        if (p.x < izquierda) izquierda = p.x;
        if (p.y < arriba) arriba = p.y;
        if (p.x + p.ancho > derecha) derecha = p.x + p.ancho;
        if (p.y + p.alto > abajo) abajo = p.y + p.alto;
      }
      // Ni el marco ni el membrete de la hoja: solo el recorte del plano.
      expect(izquierda, closeTo(trabajo.x, 1e-6));
      expect(arriba, closeTo(trabajo.y, 1e-6));
      expect(derecha, closeTo(trabajo.x + trabajo.ancho, 1e-6));
      expect(abajo, closeTo(trabajo.y + trabajo.alto, 1e-6));

      // Y quedan los archivos de las dos versiones.
      expect(File(fin.archivoDe(vista(), 0)).existsSync(), isTrue);
      expect(
        File(fin.archivoDe(ArchivosPlano.sinFondo(vista()), 47)).existsSync(),
        isTrue,
      );
    });

    test('sin papel que quitar se guarda una sola version', () async {
      final motor = _MotorAnotado()..conPapel = false;
      const sinPapel = TrabajoDeDetalle(
        pagina: 0,
        x: 0,
        y: 0,
        ancho: 3240,
        alto: 2220,
        lineas: false,
      );

      await ImportadorGeoPdf.afinar(
        rutaVista: vista(),
        detalle: pliego().conTrabajo(sinPapel),
        pdf: unPdf(),
        motor: motor,
      );

      expect(motor.pedidos.every((p) => p.destinoSinFondo == null), isTrue);
      expect(motor.pedidos.every((p) => p.papel == null), isTrue);
    });

    test('cortado en la mitad, sigue despues desde donde quedo', () async {
      final motor = _MotorAnotado();
      final pdf = unPdf();
      final avances = <int>[];

      // La app se cierra cuando van diez cuadros.
      final cortado = await ImportadorGeoPdf.afinar(
        rutaVista: vista(),
        detalle: pliego().conTrabajo(trabajo),
        pdf: pdf,
        motor: motor,
        seguir: () => motor.pedidos.length < 10,
        alAvanzar: (d) => avances.add(d.listos.length),
      );

      expect(cortado.terminado, isFalse);
      expect(cortado.listos, hasLength(10));
      expect(avances, [for (var i = 1; i <= 10; i++) i]);

      // Al volver se lee el indice del telefono y se dibuja solo lo que falta.
      final guardado = DetallePlano.leer(vista())!;
      expect(guardado.listos, cortado.listos);
      final fin = await ImportadorGeoPdf.afinar(
        rutaVista: vista(),
        detalle: guardado,
        pdf: pdf,
        motor: motor,
      );

      expect(fin.terminado, isTrue);
      expect(motor.pedidos, hasLength(48), reason: 'ninguno dos veces');
      expect(motor.pedidos.map((p) => p.destino).toSet(), hasLength(48));
    });

    test('si un cuadro no se puede, lo hecho hasta ahi queda', () async {
      final motor = _MotorAnotado()..fallaEl = 6;

      await expectLater(
        ImportadorGeoPdf.afinar(
          rutaVista: vista(),
          detalle: pliego().conTrabajo(trabajo),
          pdf: unPdf(),
          motor: motor,
        ),
        throwsA(isA<GeoPdfInvalido>()),
      );

      expect(DetallePlano.leer(vista())!.listos, hasLength(5));
    });
  });

  group('de fondo, con el plano ya en el mapa', () {
    late List<String> terminados;

    Afinador afinador(_MotorAnotado motor) {
      terminados = [];
      final a = Afinador(
        motor,
        alTerminar: (ruta) async => terminados.add(ruta),
      );
      addTearDown(a.dispose);
      return a;
    }

    /// Espera a que el afinador se quede sin trabajo.
    Future<void> hastaQue(bool Function() listo) async {
      for (var i = 0; i < 400 && !listo(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(listo(), isTrue, reason: 'el afinador no termino');
    }

    test(
      'se queda con el PDF, avisa el avance y al terminar lo borra',
      () async {
        final motor = _MotorAnotado();
        final a = afinador(motor);
        final pdf = unPdf();
        final avances = <int>[];
        a.addListener((estado) {
          final d = estado[vista()];
          if (d != null) avances.add(d.listos.length);
        });

        await a.empezar(
          rutaVista: ArchivosPlano.sinFondo(vista()),
          detalle: pliego().conTrabajo(trabajo),
          pdf: pdf,
        );
        // La carpeta temporal se vacia con la proxima importacion: el PDF ya
        // no esta ahi.
        expect(pdf.existsSync(), isFalse);
        expect(File(DetallePlano.originalDe(vista())).existsSync(), isTrue);

        await hastaQue(() => terminados.isNotEmpty);

        expect(a.state[vista()]!.terminado, isTrue);
        expect(a.state[vista()]!.listos, hasLength(48));
        expect(avances.last, 48);
        expect(avances.toSet().length, greaterThan(40), reason: 'de a uno');
        expect(terminados, [vista()]);
        expect(File(DetallePlano.originalDe(vista())).existsSync(), isFalse);
      },
    );

    test('dos planos se afinan uno despues del otro', () async {
      final motor = _MotorAnotado();
      final a = afinador(motor);

      await a.empezar(
        rutaVista: vista('uno'),
        detalle: pliego().conTrabajo(trabajo),
        pdf: unPdf('uno.pdf'),
      );
      await a.empezar(
        rutaVista: vista('dos'),
        detalle: pliego().conTrabajo(trabajo),
        pdf: unPdf('dos.pdf'),
      );
      await hastaQue(() => terminados.length == 2);

      expect(terminados, [vista('uno'), vista('dos')]);
      // Primero todos los del uno: el motor dibuja de a una cosa.
      final carpetas = [
        for (final p in motor.pedidos) File(p.destino).parent.path,
      ];
      expect(carpetas.take(48).toSet(), hasLength(1));
      expect(carpetas.skip(48).toSet(), hasLength(1));
    });

    test('si se borra el plano, se corta ahi', () async {
      final motor = _MotorAnotado();
      final a = afinador(motor);
      motor.antes = (van) {
        if (van == 7) a.olvidar(vista());
      };

      await a.empezar(
        rutaVista: vista(),
        detalle: pliego().conTrabajo(trabajo),
        pdf: unPdf(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(motor.pedidos.length, lessThan(10));
      expect(a.state.containsKey(vista()), isFalse);
      expect(terminados, isEmpty);
    });

    test('si un cuadro falla, el plano se queda con los que tiene', () async {
      final motor = _MotorAnotado()..fallaEl = 9;
      final a = afinador(motor);

      await a.empezar(
        rutaVista: vista(),
        detalle: pliego().conTrabajo(trabajo),
        pdf: unPdf(),
      );
      await hastaQue(() => terminados.isNotEmpty);

      final d = a.state[vista()]!;
      expect(d.terminado, isTrue, reason: 'no se reintenta para siempre');
      expect(d.listos, hasLength(8));
      expect(DetallePlano.leer(vista())!.terminado, isTrue);
      expect(File(DetallePlano.originalDe(vista())).existsSync(), isFalse);
    });

    test('retoma el plano que quedo a medias la vez anterior', () async {
      // La app se cerro con doce cuadros hechos y el PDF todavia guardado.
      var d = pliego().conTrabajo(trabajo);
      for (final i in d.pendientes().take(12)) {
        d = d.conListo(i);
      }
      await d.guardar(vista());
      File(DetallePlano.originalDe(vista())).writeAsStringSync('%PDF-1.6');

      final motor = _MotorAnotado();
      final a = afinador(motor)..retomar([ArchivosPlano.sinFondo(vista())]);
      await hastaQue(() => terminados.isNotEmpty);

      expect(motor.pedidos, hasLength(36));
      expect(a.state[vista()]!.listos, hasLength(48));
    });

    test('sin el PDF no hay con que seguir: queda como esta', () async {
      var d = pliego().conTrabajo(trabajo);
      d = d.conListo(19);
      await d.guardar(vista());

      final motor = _MotorAnotado();
      afinador(motor).retomar([vista()]);
      await hastaQue(() => terminados.isNotEmpty);

      expect(motor.pedidos, isEmpty);
      final cerrado = DetallePlano.leer(vista())!;
      expect(cerrado.terminado, isTrue);
      expect(cerrado.listos, {19});
    });

    test('un plano comun, o ya afinado, no se toca', () async {
      await pliego().guardar(vista('listo'));

      final motor = _MotorAnotado();
      final a = afinador(motor)..retomar([vista('comun'), vista('listo')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(motor.pedidos, isEmpty);
      expect(a.state, isEmpty);
      expect(terminados, isEmpty);
    });
  });

  group('en la lista de planos', () {
    late AppDatabase db;
    late MapasRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = MapasRepository(db);
    });
    tearDown(() => db.close());

    Future<String> registrado() async {
      File(vista()).writeAsBytesSync(List.filled(2 * 1048576, 0));
      final lineas = ArchivosPlano.sinFondo(vista());
      File(lineas).writeAsBytesSync(List.filled(1048576, 0));
      final fila = await repo.registrarImportado(
        nombre: 'Vias Meta',
        plano: PlanoImportado(
          ruta: lineas,
          esquinas: const [
            LatLng(4.6, -73.1),
            LatLng(4.6, -72.9),
            LatLng(4.2, -72.9),
            LatLng(4.2, -73.1),
          ],
          ancho: 4096,
          alto: 2807,
          megas: 3,
        ),
      );
      return fila.codigo;
    }

    test('lo que ocupa cuenta tambien los cuadros', () async {
      final codigo = await registrado();
      final d = pliego();
      await d.guardar(vista());
      File(d.archivoDe(vista(), 0)).writeAsBytesSync(List.filled(1048576, 0));
      File(d.archivoDe(ArchivosPlano.sinFondo(vista()), 0))
          .writeAsBytesSync(List.filled(524288, 0));

      await repo.recontarPeso(vista());

      final fila = (await repo.observarTodas().first).single;
      expect(fila.codigo, codigo);
      expect(fila.tamanoMb, closeTo(4.5, 0.01));
    });

    test('quitar el plano se lleva tambien su detalle', () async {
      final codigo = await registrado();
      final d = pliego();
      await d.guardar(vista());
      File(d.archivoDe(vista(), 0)).writeAsBytesSync(const [0]);
      File(DetallePlano.originalDe(vista())).writeAsStringSync('%PDF-1.6');

      await repo.borrar(codigo);

      expect(Directory(DetallePlano.carpetaDe(vista())).existsSync(), isFalse);
      expect(File(vista()).existsSync(), isFalse);
      expect(await repo.observarTodas().first, isEmpty);
    });
  });

  group('que se pone en el mapa', () {
    // Un telefono: 400 x 800 puntos de pantalla, a 2,5 pixeles por punto.
    const pantalla = Size(400, 800);
    const puntosPorPixel = 2.5;

    /// La imagen entera con su esquina de arriba en la esquina de la pantalla
    /// y [anchoEnPantalla] puntos de ancho, sin girar.
    List<int> viendo(
      DetallePlano d, {
      required double anchoEnPantalla,
      Offset arriba = Offset.zero,
      Size tamano = pantalla,
    }) => cuadrosALaVista(
      d,
      arriba: arriba,
      ancho: Offset(anchoEnPantalla, 0),
      alto: Offset(0, anchoEnPantalla * d.altoVista / d.anchoVista),
      pantalla: tamano,
      puntosPorPixel: puntosPorPixel,
    );

    DetallePlano hecho() {
      var d = pliego();
      for (var i = 0; i < d.total; i++) {
        d = d.conListo(i);
      }
      return d;
    }

    test('con el plano alejado, la imagen entera y nada mas', () {
      // Todo el plano en la pantalla: cada pixel suyo es menos que uno de ella.
      expect(viendo(hecho(), anchoEnPantalla: 400), isEmpty);
      // Agrandada apenas todavia se lee bien.
      expect(viendo(hecho(), anchoEnPantalla: 4096 * 1.4 / 2.5), isEmpty);
    });

    test('de cerca, solo los cuadros que caen en la pantalla', () {
      // La imagen entera agrandada dos veces: 3277 puntos de ancho.
      final cuadros = viendo(hecho(), anchoEnPantalla: 4096 * 2 / 2.5);

      // 400 x 800 puntos son 1000 x 2000 pixeles del detalle: entran en un
      // cuadro de ancho y dos de alto, de los 48.
      expect(cuadros, [0, 8]);
      expect(cuadros.length, lessThanOrEqualTo(PlanoConDetalle.maximoALaVez));
    });

    test('corrido hacia el medio del plano, los de ahi', () {
      final ancho = 4096 * 2 / 2.5;
      final cuadros = viendo(
        hecho(),
        anchoEnPantalla: ancho,
        // El plano corrido media hoja hacia la izquierda y hacia arriba.
        arriba: Offset(-ancho / 2, -ancho * 2807 / 4096 / 2),
      );

      expect(cuadros, isNotEmpty);
      expect(cuadros.every((i) => i % 8 >= 3 && i % 8 <= 5), isTrue);
      expect(cuadros.every((i) => i ~/ 8 >= 2), isTrue);
    });

    test('los que todavia no se dibujaron no se ponen', () {
      final d = pliego().conListo(8);

      expect(viendo(d, anchoEnPantalla: 4096 * 2 / 2.5), [8]);
    });

    test('con el plano fuera de la pantalla, ninguno', () {
      final cuadros = viendo(
        hecho(),
        anchoEnPantalla: 4096 * 2 / 2.5,
        arriba: const Offset(5000, 5000),
      );

      expect(cuadros, isEmpty);
    });

    test('con el mapa girado sigue acertando', () {
      // El plano girado 90 grados: su ancho baja por la pantalla.
      final largo = 4096 * 2 / 2.5;
      final d = hecho();
      final cuadros = cuadrosALaVista(
        d,
        arriba: const Offset(400, 0),
        ancho: Offset(0, largo),
        alto: Offset(-largo * d.altoVista / d.anchoVista, 0),
        pantalla: pantalla,
        puntosPorPixel: puntosPorPixel,
      );

      // La pantalla mira la franja de arriba de la hoja, a lo largo: lo que
      // en la pantalla es alto, en la hoja es ancho.
      expect(cuadros, [0, 1]);
    });

    test('en una pantalla enorme no se abren decenas de cuadros', () {
      final cuadros = viendo(
        hecho(),
        anchoEnPantalla: 4096 * 1.6 / 2.5,
        tamano: const Size(2600, 1800),
      );

      expect(cuadros, isEmpty);
    });
  });
}
