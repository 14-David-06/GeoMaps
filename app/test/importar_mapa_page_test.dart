import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/detalle_plano.dart';
import 'package:geomaps/core/geopdf.dart';
import 'package:geomaps/core/importar_geopdf.dart';
import 'package:geomaps/core/motor_planos.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/mapas_repository.dart';
import 'package:geomaps/state/afinado.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/ui/importar_mapa_page.dart';
import 'package:geomaps/ui/theme.dart';
import 'package:latlong2/latlong.dart';

/// La pantalla donde se importa un plano en PDF.
///
/// Lo que se cuida aca es lo que ve la persona cuando algo no sale: que el
/// motivo quede escrito en la pantalla, que el boton vuelva a servir, y que
/// nada se desborde con la letra agrandada.
void main() {
  const esquinas = [
    LatLng(4.60, -73.10),
    LatLng(4.60, -72.90),
    LatLng(4.20, -72.90),
    LatLng(4.20, -73.10),
  ];

  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// Las filas tal como las guarda la app, sacadas de una base de verdad.
  Future<List<Mapa>> planosGuardados(
    WidgetTester tester,
    List<String> nombres,
  ) async {
    final filas = await tester.runAsync(() async {
      final repo = MapasRepository(db);
      for (final nombre in nombres) {
        await repo.registrarImportado(
          nombre: nombre,
          plano: const PlanoImportado(
            ruta: '/no/existe.png',
            esquinas: esquinas,
            ancho: 4096,
            alto: 3281,
            megas: 3.4,
          ),
        );
      }
      return repo.observarTodas().first;
    });
    return filas!;
  }

  Future<void> abrir(
    WidgetTester tester, {
    required MotorPlanos motor,
    List<Mapa> planos = const [],
    ValueChanged<List<LatLng>?>? alCerrar,
    Map<String, DetallePlano> afinando = const {},
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          capasImportadasProvider.overrideWith((ref) => Stream.value(planos)),
          afinadorProvider.overrideWith((ref) => _AfinadorFijo(afinando)),
        ],
        child: MaterialApp(
          theme: temaSirius,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    final r = await Navigator.of(context).push<List<LatLng>>(
                      MaterialPageRoute(
                        builder: (_) => ImportarMapaPage(motor: motor),
                      ),
                    );
                    alCerrar?.call(r);
                  },
                  child: const Text('abrir'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('un PDF sin coordenadas lo dice en la pantalla', (tester) async {
    await abrir(
      tester,
      motor: _MotorFalso(
        falla: const GeoPdfInvalido('Este PDF no trae georreferencia.'),
      ),
    );

    await tester.tap(find.text('Elegir un PDF'));
    await tester.pumpAndSettle();

    expect(find.text('Este PDF no trae georreferencia.'), findsOneWidget);
    // El boton vuelve a servir: se puede probar con otro archivo.
    expect(find.text('Elegir un PDF'), findsOneWidget);
  });

  testWidgets('cancelar el selector no deja nada raro', (tester) async {
    await abrir(tester, motor: _MotorFalso());

    await tester.tap(find.text('Elegir un PDF'));
    await tester.pumpAndSettle();

    expect(find.text('Elegir un PDF'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('"Ver en el mapa" vuelve con las esquinas del plano', (
    tester,
  ) async {
    final planos = await planosGuardados(tester, ['Vias del Meta']);
    List<LatLng>? devuelto;
    await abrir(
      tester,
      motor: _MotorFalso(),
      planos: planos,
      alCerrar: (r) => devuelto = r,
    );

    expect(find.text('Vias del Meta'), findsOneWidget);
    await tester.tap(find.text('Ver en el mapa'));
    await tester.pumpAndSettle();

    expect(devuelto, hasLength(4));
    expect(devuelto!.first.latitude, 4.60);
    expect(devuelto!.first.longitude, -73.10);
  });

  testWidgets('una hoja grande dice cuanto le falta de detalle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final planos = await planosGuardados(tester, ['Vias del Meta 2026']);
    // Doce cuadros hechos de los 48 de un pliego.
    var detalle = const DetallePlano(
      anchoVista: 4096,
      altoVista: 2807,
      ancho: 8192,
      alto: 5613,
      trabajo: TrabajoDeDetalle(
        pagina: 0,
        x: 60,
        y: 84,
        ancho: 3240,
        alto: 2220,
        lineas: true,
      ),
    );
    for (var i = 0; i < 12; i++) {
      detalle = detalle.conListo(i);
    }

    await abrir(
      tester,
      motor: _MotorFalso(),
      planos: planos,
      afinando: {Afinador.clave('/no/existe.png'): detalle},
    );

    // Con la letra agrandada la lista queda debajo de la tarjeta de importar.
    final aviso = find.text(
      'Mejorando el detalle: 12 de 48. Ya se puede usar.',
    );
    await tester.scrollUntilVisible(
      aviso,
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // Se dice que ya sirve: nadie tiene que quedarse esperando.
    expect(aviso, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('con el detalle terminado no dice nada', (tester) async {
    final planos = await planosGuardados(tester, ['Vias del Meta 2026']);

    await abrir(
      tester,
      motor: _MotorFalso(),
      planos: planos,
      afinando: {
        Afinador.clave('/no/existe.png'): const DetallePlano(
          anchoVista: 4096,
          altoVista: 2807,
          ancho: 8192,
          alto: 5613,
        ),
      },
    );

    expect(find.textContaining('Mejorando el detalle'), findsNothing);
  });

  testWidgets('con la letra del telefono agrandada no se desborda', (
    tester,
  ) async {
    // Un telefono angosto, con la letra al 130%: como lo tiene configurado
    // quien no ve bien.
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final planos = await planosGuardados(tester, [
      'Plancha 266-II-A Restrepo Cumaral Medina escala 1 a 25000 (2)',
      'Vias',
    ]);
    await abrir(
      tester,
      motor: _MotorFalso(
        falla: const GeoPdfInvalido(
          'Este PDF no trae georreferencia: es un plano sin coordenadas, y '
          'no hay forma de saber donde va en el mapa. Pedilo exportado como '
          'PDF geoespacial (GeoPDF).',
        ),
      ),
      planos: planos,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Elegir un PDF'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('sin coordenadas'), findsOneWidget);
  });
}

/// Un afinador con el avance puesto a mano: la lista solo lo mira.
class _AfinadorFijo extends Afinador {
  _AfinadorFijo(Map<String, DetallePlano> avance) : super(const MotorPlanos()) {
    state = avance;
  }
}

/// El lado nativo, de mentira: o la persona cancela, o el archivo no sirve.
class _MotorFalso extends MotorPlanos {
  _MotorFalso({this.falla});

  final GeoPdfInvalido? falla;

  @override
  Future<PdfElegido?> elegir() async {
    final f = falla;
    if (f != null) throw f;
    return null;
  }
}
