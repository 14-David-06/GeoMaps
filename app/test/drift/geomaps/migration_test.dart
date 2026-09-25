// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:geomaps/data/db/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = AppDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // The following template shows how to write tests ensuring your migrations
  // preserve existing data.
  // Testing this can be useful for migrations that change existing columns
  // (e.g. by alterating their type or constraints). Migrations that only add
  // tables or columns typically don't need these advanced tests. For more
  // information, see https://drift.simonbinder.eu/migrations/tests/#verifying-data-integrity
  // TODO: This generated template shows how these tests could be written. Adopt
  // it to your own needs when testing migrations with data integrity.
  test('migration from v1 to v2 does not corrupt data', () async {
    // Add data to insert into the old database, and the expected rows after the
    // migration.
    // TODO: Fill these lists
    final oldUsuariosData = <v1.UsuariosData>[];
    final expectedNewUsuariosData = <v2.UsuariosData>[];

    final oldProyectosData = <v1.ProyectosData>[];
    final expectedNewProyectosData = <v2.ProyectosData>[];

    final oldMapasData = <v1.MapasData>[];
    final expectedNewMapasData = <v2.MapasData>[];

    final oldTrazadosData = <v1.TrazadosData>[];
    final expectedNewTrazadosData = <v2.TrazadosData>[];

    final oldWaypointsData = <v1.WaypointsData>[];
    final expectedNewWaypointsData = <v2.WaypointsData>[];

    final oldArchivosData = <v1.ArchivosData>[];
    final expectedNewArchivosData = <v2.ArchivosData>[];

    final oldSincronizacionesData = <v1.SincronizacionesData>[];
    final expectedNewSincronizacionesData = <v2.SincronizacionesData>[];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: AppDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.usuarios, oldUsuariosData);
        batch.insertAll(oldDb.proyectos, oldProyectosData);
        batch.insertAll(oldDb.mapas, oldMapasData);
        batch.insertAll(oldDb.trazados, oldTrazadosData);
        batch.insertAll(oldDb.waypoints, oldWaypointsData);
        batch.insertAll(oldDb.archivos, oldArchivosData);
        batch.insertAll(oldDb.sincronizaciones, oldSincronizacionesData);
      },
      validateItems: (newDb) async {
        expect(
          expectedNewUsuariosData,
          await newDb.select(newDb.usuarios).get(),
        );
        expect(
          expectedNewProyectosData,
          await newDb.select(newDb.proyectos).get(),
        );
        expect(expectedNewMapasData, await newDb.select(newDb.mapas).get());
        expect(
          expectedNewTrazadosData,
          await newDb.select(newDb.trazados).get(),
        );
        expect(
          expectedNewWaypointsData,
          await newDb.select(newDb.waypoints).get(),
        );
        expect(
          expectedNewArchivosData,
          await newDb.select(newDb.archivos).get(),
        );
        expect(
          expectedNewSincronizacionesData,
          await newDb.select(newDb.sincronizaciones).get(),
        );
      },
    );
  });
}
