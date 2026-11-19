import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'db/app_database.dart';
import 'db/enums.dart';
import 'mapas_repository.dart';

/// Inventario de los archivos que la app genero. Hoy: las fotos de los puntos.
///
/// Una fila por archivo, con su ruta en el telefono siempre y su llave del
/// bucket solo despues de sincronizar. El archivo **no se borra al subir**:
/// la foto se tiene que poder ver en el lote, sin senal, que es donde se
/// vuelve a mirar el punto.
///
/// Las fotos viven en la carpeta de documentos de la app, que Android no
/// vacia cuando le falta espacio. La que entrega la camara queda en la cache,
/// que si se vacia: por eso se copia apenas se toma.
class ArchivosRepository {
  ArchivosRepository(this._db, {Future<Directory> Function()? carpetaBase})
    : _carpetaBase = carpetaBase ?? getApplicationDocumentsDirectory;

  final AppDatabase _db;
  final Future<Directory> Function() _carpetaBase;
  static const _uuid = Uuid();

  Future<Directory> _carpetaFotos() async {
    final carpeta = Directory(p.join((await _carpetaBase()).path, 'fotos'));
    await carpeta.create(recursive: true);
    return carpeta;
  }

  /// Guarda la foto que entrego la camara como foto del punto.
  ///
  /// La copia a la carpeta de la app y borra la de la cache. Queda sin
  /// sincronizar: sube sola cuando haya red, despues de su punto.
  Future<Archivo> guardarFoto({
    required File origen,
    required String waypointCodigo,
    required String usuarioCodigo,
  }) async {
    final codigo = _uuid.v4();
    final destino = File(p.join((await _carpetaFotos()).path, '$codigo.jpg'));
    await origen.copy(destino.path);
    try {
      await origen.delete();
    } catch (_) {
      // La cache la limpia Android cuando quiera: no es un problema.
    }
    final bytes = await destino.length();
    // La foto va al proyecto de su punto, no al que este elegido ahora: se
    // enlaza a el, y el servidor revisa que los dos sean del mismo proyecto.
    final punto = await (_db.select(
      _db.waypoints,
    )..where((w) => w.codigo.equals(waypointCodigo))).getSingleOrNull();
    return _db
        .into(_db.archivos)
        .insertReturning(
          ArchivosCompanion.insert(
            codigo: codigo,
            proyectoCodigo:
                punto?.proyectoCodigo ?? MapasRepository.proyectoLocal,
            waypointCodigo: Value(waypointCodigo),
            nombre: '$codigo.jpg',
            tipo: TipoArchivo.foto.name,
            rutaLocal: destino.path,
            tamanoMb: Value(bytes / (1024 * 1024)),
            usuarioCodigo: Value(usuarioCodigo),
            creadoEn: DateTime.now(),
          ),
        );
  }

  /// Las fotos de un punto, de la primera a la ultima, en vivo.
  Stream<List<Archivo>> observarFotos(String waypointCodigo) {
    final consulta = _db.select(_db.archivos)
      ..where(
        (a) =>
            a.waypointCodigo.equals(waypointCodigo) &
            a.tipo.equals(TipoArchivo.foto.name),
      )
      ..orderBy([(a) => OrderingTerm.asc(a.creadoEn)]);
    return consulta.watch();
  }

  Future<List<Archivo>> fotosDe(String waypointCodigo) {
    final consulta = _db.select(_db.archivos)
      ..where(
        (a) =>
            a.waypointCodigo.equals(waypointCodigo) &
            a.tipo.equals(TipoArchivo.foto.name),
      )
      ..orderBy([(a) => OrderingTerm.asc(a.creadoEn)]);
    return consulta.get();
  }

  /// Borra una foto: el archivo y su fila.
  Future<void> borrarFoto(String codigo) async {
    final fila = await (_db.select(
      _db.archivos,
    )..where((a) => a.codigo.equals(codigo))).getSingleOrNull();
    if (fila == null) return;
    try {
      await File(fila.rutaLocal).delete();
    } catch (_) {
      // Si el archivo ya no esta, la fila se va igual.
    }
    await (_db.delete(
      _db.archivos,
    )..where((a) => a.codigo.equals(codigo))).go();
  }

  /// Borra las fotos de un punto. Va con borrar el punto: una foto sin punto
  /// no se puede ver desde ningun lado y no sube nunca.
  Future<void> borrarDelPunto(String waypointCodigo) async {
    for (final foto in await fotosDe(waypointCodigo)) {
      await borrarFoto(foto.codigo);
    }
  }

  /// Borra del telefono todos los archivos de fotos. Es parte de eliminar la
  /// cuenta; las filas las borra la base.
  Future<void> borrarArchivosDeFotos() async {
    try {
      final carpeta = await _carpetaFotos();
      if (await carpeta.exists()) await carpeta.delete(recursive: true);
    } catch (_) {}
  }

  /// Las fotos que se pueden subir ahora, la mas vieja primero.
  ///
  /// Solo las de puntos que ya subieron: la foto se enlaza a la fila de su
  /// punto, y para eso el punto tiene que existir del otro lado. Las demas
  /// esperan a la proxima pasada.
  Future<List<Archivo>> fotosParaSubir(String usuarioCodigo) async {
    final pendientes =
        await (_db.select(_db.archivos)
              ..where(
                (a) =>
                    a.usuarioCodigo.equals(usuarioCodigo) &
                    a.sincronizado.equals(false) &
                    a.tipo.equals(TipoArchivo.foto.name) &
                    a.waypointCodigo.isNotNull(),
              )
              ..orderBy([(a) => OrderingTerm.asc(a.creadoEn)]))
            .get();
    if (pendientes.isEmpty) return pendientes;

    final puntos = {for (final f in pendientes) f.waypointCodigo!};
    final subidos =
        await (_db.select(_db.waypoints)..where(
              (w) => w.codigo.isIn(puntos) & w.sincronizado.equals(true),
            ))
            .map((w) => w.codigo)
            .get();
    final listos = subidos.toSet();
    return [
      for (final f in pendientes)
        if (listos.contains(f.waypointCodigo)) f,
    ];
  }

  /// Cuantas fotos faltan subir, en vivo. Cuenta todas, tambien las que
  /// esperan a su punto: para quien mira el contador, falta subirlas.
  Stream<int> contarPendientes(String usuarioCodigo) {
    final cuantos = _db.archivos.id.count();
    final consulta = _db.selectOnly(_db.archivos)
      ..addColumns([cuantos])
      ..where(
        _db.archivos.usuarioCodigo.equals(usuarioCodigo) &
            _db.archivos.sincronizado.equals(false) &
            _db.archivos.tipo.equals(TipoArchivo.foto.name),
      );
    return consulta.map((f) => f.read(cuantos) ?? 0).watchSingle();
  }

  Future<void> marcarSubida(String codigo, String llave) {
    return (_db.update(
      _db.archivos,
    )..where((a) => a.codigo.equals(codigo))).write(
      ArchivosCompanion(
        sincronizado: const Value(true),
        llaveS3: Value(llave),
        actualizadoEn: Value(DateTime.now()),
      ),
    );
  }
}
