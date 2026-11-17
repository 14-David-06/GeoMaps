import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/importar_geopdf.dart';
import '../ui/capa_pdf.dart';
import 'db/app_database.dart';
import 'db/enums.dart';

/// El catalogo de capas y su estado de descarga.
///
/// Distingue tres cosas que la pantalla de capas confunde facil:
///
/// - **Registrado**: existe la ficha, el MBTiles esta en el bucket.
/// - **Descargado**: el archivo esta en el telefono (`rutaLocal != null`).
/// - **Visible**: el usuario lo tiene encendido ahora.
///
/// Un mapa en estado `procesando` no se le ofrece al telefono: descargar un
/// MBTiles a medio escribir deja la app con un mapa corrupto y sin error.
class MapasRepository {
  MapasRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Donde quedan los planos que se importaron en este telefono y todavia no
  /// pertenecen a ningun proyecto.
  ///
  /// Hoy el mapa se abre sin proyecto -se entra por "Guaicaramo" y punto-, pero
  /// la tabla exige uno porque el bucket se organiza asi. En vez de inventar un
  /// proyecto falso por cada importacion, todas caen en este, y el dia que
  /// exista el directorio de proyectos se reasignan. Es una cadena constante y
  /// no un UUID para que sea reconocible al mirar la base.
  static const proyectoLocal = 'local';

  /// Las capas encendidas de un proyecto, listas para dibujar, en vivo.
  ///
  /// Solo las que estan **bajadas** (`rutaLocal`) y **visibles**: la capa del
  /// mapa no tiene que saber filtrar nada, y una ficha sin archivo dibujada
  /// como capa es una excepcion en medio del potrero.
  Stream<List<PlanoEnMapa>> observarVisibles({
    String proyecto = proyectoLocal,
  }) {
    final consulta = _db.select(_db.mapas)
      ..where(
        (m) =>
            m.proyectoCodigo.equals(proyecto) &
            m.visible.equals(true) &
            m.rutaLocal.isNotNull() &
            m.esquinas.isNotNull(),
      )
      ..orderBy([(m) => OrderingTerm(expression: m.orden)]);

    return consulta.watch().map(
      (filas) => filas
          .map(
            (f) => PlanoEnMapa(
              codigo: f.codigo,
              nombre: f.nombre,
              ruta: f.rutaLocal!,
              esquinas: PlanoImportado.esquinasDeTexto(f.esquinas!),
              opacidad: f.opacidad,
            ),
          )
          .toList(growable: false),
    );
  }

  /// Todas las capas del proyecto, encendidas o no. Es lo que lista la
  /// pantalla de capas.
  Stream<List<Mapa>> observarTodas({String proyecto = proyectoLocal}) {
    final consulta = _db.select(_db.mapas)
      ..where((m) => m.proyectoCodigo.equals(proyecto))
      ..orderBy([(m) => OrderingTerm(expression: m.orden)]);
    return consulta.watch();
  }

  /// Registra un plano recien importado del telefono.
  ///
  /// Nace **visible y arriba de todo**: alguien que acaba de elegir un archivo
  /// espera verlo, no tener que ir a encenderlo a otra pantalla.
  Future<Mapa> registrarImportado({
    required String nombre,
    required PlanoImportado plano,
    String proyecto = proyectoLocal,
  }) async {
    final orden = await _proximoOrden(proyecto);
    return _db
        .into(_db.mapas)
        .insertReturning(
          MapasCompanion.insert(
            codigo: _uuid.v4(),
            proyectoCodigo: proyecto,
            nombre: nombre,
            formatoOrigen: FormatoMapa.geoPdf.name,
            // El estado es `listo` y no `procesando`: para el telefono esta
            // listo de verdad. Que ademas se pueda mandar a convertir con GDAL
            // para tenerlo nitido es otra historia, y no lo bloquea.
            estado: EstadoMapa.listo.name,
            creadoEn: DateTime.now(),
            rutaLocal: Value(plano.ruta),
            bbox: Value(plano.bbox),
            esquinas: Value(plano.esquinasSerializadas),
            tamanoMb: Value(plano.megas),
            orden: Value(orden),
          ),
        );
  }

  Future<void> cambiarVisible(String codigo, bool visible) {
    return (_db.update(_db.mapas)..where((m) => m.codigo.equals(codigo))).write(
      MapasCompanion(visible: Value(visible)),
    );
  }

  /// La opacidad se guarda en la base y no en la pantalla: el tecnico la
  /// ajusta una vez y espera encontrarla asi al dia siguiente.
  Future<void> cambiarOpacidad(String codigo, double opacidad) {
    return (_db.update(_db.mapas)..where((m) => m.codigo.equals(codigo))).write(
      MapasCompanion(opacidad: Value(opacidad.clamp(0.1, 1))),
    );
  }

  /// Si el plano tiene las dos copias -con la hoja y sin ella- y por lo tanto
  /// se puede elegir cual ver. Un plano sin papel que quitar tiene una sola.
  static bool sePuedeQuitarElFondo(String? ruta) =>
      ruta != null &&
      File(ArchivosPlano.conFondo(ruta)).existsSync() &&
      File(ArchivosPlano.sinFondo(ruta)).existsSync();

  /// Cambia entre ver solo las lineas del plano o la hoja entera.
  ///
  /// No dibuja nada de nuevo: las dos copias se hicieron al importar, y esto
  /// solo cambia cual de las dos se pone encima del mapa. Si la copia pedida
  /// no esta, se queda como estaba en vez de dejar la capa sin imagen.
  Future<void> cambiarFondo(String codigo, {required bool quitar}) async {
    final fila = await (_db.select(
      _db.mapas,
    )..where((m) => m.codigo.equals(codigo))).getSingleOrNull();
    final actual = fila?.rutaLocal;
    if (actual == null) return;

    final nueva = quitar
        ? ArchivosPlano.sinFondo(actual)
        : ArchivosPlano.conFondo(actual);
    if (nueva == actual || !File(nueva).existsSync()) return;

    await (_db.update(_db.mapas)..where((m) => m.codigo.equals(codigo))).write(
      MapasCompanion(rutaLocal: Value(nueva)),
    );
  }

  /// Saca la capa del telefono: la fila y sus archivos.
  ///
  /// Aca si se borra de verdad, al reves que un proyecto: un plano importado no
  /// tiene trabajo de campo colgando, y el original sigue siendo un PDF que
  /// alguien tiene guardado. Lo que ocupa son megas en un telefono que se queda
  /// sin espacio.
  Future<void> borrar(String codigo) async {
    final fila = await (_db.select(
      _db.mapas,
    )..where((m) => m.codigo.equals(codigo))).getSingleOrNull();
    if (fila == null) return;

    final ruta = fila.rutaLocal;
    if (ruta != null) {
      // Las dos copias: borrar solo la que esta puesta dejaria la otra
      // ocupando lugar para siempre, sin ninguna fila que la recuerde.
      for (final copia in {
        ArchivosPlano.conFondo(ruta),
        ArchivosPlano.sinFondo(ruta),
      }) {
        final archivo = File(copia);
        // Que el archivo ya no este no puede impedir borrar la fila: quedaria
        // una capa fantasma imposible de sacar de la lista.
        if (!archivo.existsSync()) continue;
        try {
          await archivo.delete();
        } on FileSystemException {
          // Sin ruido: la fila se va igual y los megas los recupera Android
          // cuando limpie la cache de la app.
        }
      }
    }

    await (_db.delete(_db.mapas)..where((m) => m.codigo.equals(codigo))).go();
  }

  /// Cuanto ocupan las capas bajadas, para poder decirlo antes de que el
  /// telefono se quede sin espacio.
  Future<double> megasUsadas({String proyecto = proyectoLocal}) async {
    final suma = _db.mapas.tamanoMb.sum();
    final consulta = _db.selectOnly(_db.mapas)
      ..addColumns([suma])
      ..where(
        _db.mapas.proyectoCodigo.equals(proyecto) &
            _db.mapas.rutaLocal.isNotNull(),
      );
    final fila = await consulta.getSingle();
    return fila.read(suma) ?? 0;
  }

  Future<int> _proximoOrden(String proyecto) async {
    final maximo = _db.mapas.orden.max();
    final consulta = _db.selectOnly(_db.mapas)
      ..addColumns([maximo])
      ..where(_db.mapas.proyectoCodigo.equals(proyecto));
    final fila = await consulta.getSingle();
    return (fila.read(maximo) ?? 0) + 1;
  }

  // TODO: registrarDescarga(codigo, rutaLocal, tamanoMb) -- para los MBTiles
  //       que bajen del bucket cuando existan los endpoints.
}
