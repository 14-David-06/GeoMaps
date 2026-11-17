import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geomaps/core/importar_geopdf.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:geomaps/data/mapas_repository.dart';
import 'package:geomaps/state/providers.dart';
import 'package:geomaps/ui/importar_mapa_page.dart';
import 'package:latlong2/latlong.dart';

/// Ver un plano con su hoja blanca o solo con sus lineas.
///
/// Un plano se importa en dos copias. La que se dibuja es la que dice la fila;
/// la otra se encuentra por el nombre. Aca se cuida que las dos se sigan
/// encontrando, que cambiar de una a otra no deje la capa sin imagen, y que al
/// borrar el plano no quede ninguna de las dos ocupando lugar.
void main() {
  const esquinas = [
    LatLng(4.60, -73.10),
    LatLng(4.60, -72.90),
    LatLng(4.20, -72.90),
    LatLng(4.20, -73.10),
  ];

  group('los nombres de las dos copias', () {
    test('de una sale la otra, en los dos sentidos', () {
      const hoja = '/capas/abc.png';
      const lineas = '/capas/abc-lineas.png';

      expect(ArchivosPlano.sinFondo(hoja), lineas);
      expect(ArchivosPlano.conFondo(lineas), hoja);
      // Pedir la que ya se tiene no le agrega ni le saca nada.
      expect(ArchivosPlano.sinFondo(lineas), lineas);
      expect(ArchivosPlano.conFondo(hoja), hoja);

      expect(ArchivosPlano.esSinFondo(lineas), isTrue);
      expect(ArchivosPlano.esSinFondo(hoja), isFalse);
    });
  });

  group('en el telefono', () {
    late AppDatabase db;
    late MapasRepository repo;
    late Directory carpeta;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = MapasRepository(db);
      carpeta = Directory.systemTemp.createTempSync('geomaps-planos');
    });

    tearDown(() async {
      await db.close();
      if (carpeta.existsSync()) carpeta.deleteSync(recursive: true);
    });

    /// Un plano importado, con una o con las dos copias en disco.
    Future<Mapa> importado({required bool conLineas}) {
      final hoja = File('${carpeta.path}/p.png')..writeAsBytesSync([1]);
      final lineas = File(ArchivosPlano.sinFondo(hoja.path));
      if (conLineas) lineas.writeAsBytesSync([2]);
      return repo.registrarImportado(
        nombre: 'Vias',
        plano: PlanoImportado(
          ruta: conLineas ? lineas.path : hoja.path,
          esquinas: esquinas,
          ancho: 10,
          alto: 10,
          megas: 0.1,
        ),
      );
    }

    Future<String?> rutaDe(String codigo) async =>
        (await repo.observarTodas().first)
            .singleWhere((m) => m.codigo == codigo)
            .rutaLocal;

    test('cambia entre las lineas y la hoja entera', () async {
      final plano = await importado(conLineas: true);
      expect(ArchivosPlano.esSinFondo(plano.rutaLocal!), isTrue);
      expect(MapasRepository.sePuedeQuitarElFondo(plano.rutaLocal), isTrue);

      await repo.cambiarFondo(plano.codigo, quitar: false);
      expect(await rutaDe(plano.codigo), '${carpeta.path}/p.png');

      await repo.cambiarFondo(plano.codigo, quitar: true);
      expect(await rutaDe(plano.codigo), '${carpeta.path}/p-lineas.png');
    });

    test('si la otra copia no esta, se queda como estaba', () async {
      // Una ortofoto no tiene papel que quitar: hay una sola copia. Apuntar
      // la fila a un archivo que no existe dejaria la capa en blanco.
      final plano = await importado(conLineas: false);
      expect(MapasRepository.sePuedeQuitarElFondo(plano.rutaLocal), isFalse);

      await repo.cambiarFondo(plano.codigo, quitar: true);
      expect(await rutaDe(plano.codigo), '${carpeta.path}/p.png');
    });

    test('borrar el plano se lleva las dos copias', () async {
      final plano = await importado(conLineas: true);
      // Aunque la que este puesta sea la hoja entera.
      await repo.cambiarFondo(plano.codigo, quitar: false);

      await repo.borrar(plano.codigo);

      expect(carpeta.listSync(), isEmpty);
      expect(await repo.observarTodas().first, isEmpty);
    });

    testWidgets('el interruptor aparece solo si hay un fondo que quitar', (
      tester,
    ) async {
      final filas = await tester.runAsync(() async {
        await importado(conLineas: true);
        // El segundo plano, con otro nombre de archivo y una sola copia.
        final foto = File('${carpeta.path}/foto.png')..writeAsBytesSync([3]);
        await repo.registrarImportado(
          nombre: 'Ortofoto',
          plano: PlanoImportado(
            ruta: foto.path,
            esquinas: esquinas,
            ancho: 10,
            alto: 10,
            megas: 0.1,
          ),
        );
        return repo.observarTodas().first;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbProvider.overrideWithValue(db),
            capasImportadasProvider.overrideWith(
              (ref) => Stream.value(filas!),
            ),
          ],
          child: const MaterialApp(home: ImportarMapaPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Vias'), findsOneWidget);
      expect(find.text('Ortofoto'), findsOneWidget);
      // Dos planos, un solo interruptor de fondo: el de las vias.
      expect(find.text('Quitar el fondo blanco'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Quitar el fondo blanco'), 200);
      await tester.tap(find.text('Quitar el fondo blanco'));
      await tester.pump();

      final ruta = await tester.runAsync(
        () async => (await repo.observarTodas().first)
            .singleWhere((m) => m.nombre == 'Vias')
            .rutaLocal,
      );
      expect(ArchivosPlano.esSinFondo(ruta!), isFalse);
    });
  });
}
