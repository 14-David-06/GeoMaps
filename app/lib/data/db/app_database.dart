import 'package:drift/drift.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// La base local. El codigo generado sale de:
///
/// ```bash
/// dart run build_runner build --delete-conflicting-outputs
/// ```
///
/// `app_database.g.dart` no se versiona: se regenera, y tenerlo en git solo
/// produce conflictos de merge en codigo que nadie edita a mano.
@DriftDatabase(
  tables: [
    Usuarios,
    Proyectos,
    Mapas,
    Trazados,
    Waypoints,
    Archivos,
    Sincronizaciones,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Subirlo es obligatorio en cuanto cambie cualquier tabla, junto con su
  /// paso en `onUpgrade`. Ver "Cambiar el esquema" abajo.
  @override
  int get schemaVersion => 2;

  /// Como pasa la base de una version del APK a la siguiente.
  ///
  /// El APK nuevo se instala encima del viejo y encuentra la base vieja. Lo
  /// que haya en ella es trabajo de campo que quizas todavia no se sincronizo,
  /// asi que la unica migracion aceptable es la que conserva todo: nunca un
  /// `deleteEverything`, nunca borrar y recrear una tabla con datos.
  ///
  /// ## Cambiar el esquema
  ///
  /// 1. Cambiar `tables.dart` y subir `schemaVersion` en uno.
  /// 2. `dart run drift_dev make-migrations`: guarda el esquema nuevo en
  ///    `drift_schemas/` y genera los pasos y las pruebas de migracion.
  /// 3. Agregar el paso en `onUpgrade` (`from1To2: ...`) usando solo
  ///    operaciones que conservan datos: `addColumn` (con default o nullable),
  ///    `createTable`, `createIndex`, o `alterTable(TableMigration(...))` para
  ///    lo que SQLite no sabe hacer en el lugar.
  /// 4. Correr `flutter test test/drift/`: prueba la migracion desde cada
  ///    version anterior con datos adentro.
  ///
  /// Columnas: primero se agrega la nueva, en otra version se deja de usar la
  /// vieja. Renombrar o borrar en un solo paso rompe a quien actualiza
  /// saltandose versiones.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, desde, hasta) async {
      // v1 -> v2: la columna de esquinas, para los planos importados que no
      // caen derechos sobre el mapa. Es `addColumn` de una columna nullable:
      // las filas que ya existan quedan como estaban, que es lo correcto -un
      // MBTiles ya reproyectado no tiene esquinas giradas-.
      if (desde < 2) {
        await m.addColumn(mapas, mapas.esquinas);
      }

      // Si se llega aca sin paso para `desde`, se corta con error en vez
      // de seguir: una base a medio migrar es peor que una app que no
      // abre, porque la segunda se arregla con otro APK y la primera no.
      if (desde > hasta || desde < 1) {
        throw StateError(
          'No hay migracion de la base v$desde a la v$hasta. Falta el paso '
          'en AppDatabase.migration.',
        );
      }
    },
  );
}
