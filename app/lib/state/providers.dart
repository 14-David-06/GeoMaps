import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/version_app.dart';
import '../data/db/app_database.dart';
import '../data/mapas_repository.dart';
import '../data/proyectos_repository.dart';
import '../ui/capa_pdf.dart';

/// Los providers raiz: base de datos, repositorios y cliente HTTP.
///
/// Todo lo demas los lee de aca. Tenerlos en un archivo permite sobreescribir
/// la base por una en memoria en las pruebas con un solo `overrides`.
///
/// El cliente HTTP (`apiProvider`) vive en `state/sesion.dart` porque el token
/// se le monta ahi; no se duplica aca.

/// La base local. Es un unico SQLite en el directorio de datos de la app, asi
/// que sobrevive a cerrar sesion: el trabajo de campo no se borra porque
/// alguien salio y volvio a entrar.
final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(driftDatabase(name: 'geomaps'));
  ref.onDispose(db.close);
  return db;
});

/// La version de este APK. Se sobreescribe en `main` con lo que lee
/// `package_info_plus`; sin eso (en pruebas) es null y no se bloquea nada.
final versionLocalProvider = Provider<VersionLocal?>((ref) => null);

final proyectosRepositoryProvider = Provider<ProyectosRepository>(
  (ref) => ProyectosRepository(ref.watch(dbProvider)),
);

final mapasRepositoryProvider = Provider<MapasRepository>(
  (ref) => MapasRepository(ref.watch(dbProvider)),
);

/// Las capas encendidas del telefono, listas para que el mapa las dibuje.
final capasVisiblesProvider = StreamProvider<List<PlanoEnMapa>>(
  (ref) => ref.watch(mapasRepositoryProvider).observarVisibles(),
);

/// Todas las capas importadas, para la pantalla que las administra.
final capasImportadasProvider = StreamProvider<List<Mapa>>(
  (ref) => ref.watch(mapasRepositoryProvider).observarTodas(),
);
