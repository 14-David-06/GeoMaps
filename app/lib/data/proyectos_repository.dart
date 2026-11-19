import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'db/app_database.dart';

/// Un proyecto con lo que la lista necesita mostrar de el.
///
/// El conteo de mapas y los MB ocupados se calculan en la consulta y no
/// recorriendo el disco: la lista se redibuja con cada cambio de la base, y
/// medir archivos en cada redibujo trabaria el scroll en un telefono barato.
class ProyectoConResumen {
  const ProyectoConResumen({
    required this.proyecto,
    required this.mapasDescargados,
    required this.megasUsadas,
  });

  final Proyecto proyecto;

  /// Mapas de este proyecto que ya estan bajados al telefono. Los que estan
  /// en el servidor pero no bajados no cuentan: en campo solo sirven estos.
  final int mapasDescargados;

  final double megasUsadas;
}

/// Lectura y escritura de proyectos en la base local.
///
/// El espejo del directorio que baja de `GET /v1/proyectos` se mezcla con lo
/// que ya tiene el telefono con la regla **rellenar, no pisar**: lo que el
/// tecnico acaba de teclear puede ser mas nuevo que lo que hay en Airtable.
class ProyectosRepository {
  ProyectosRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Los proyectos de una cuenta, con su resumen, en vivo.
  ///
  /// Es un `Stream` y no un `Future` porque crear un proyecto tiene que
  /// aparecer en la lista sin que nadie recargue nada: drift reemite la
  /// consulta cuando cambia cualquiera de las dos tablas.
  ///
  /// Filtra por `duenoAuthUid` siempre. Un mismo telefono pasa por varias
  /// cuentas y mostrarle a alguien los predios del anterior seria una fuga de
  /// datos entre clientes, no un detalle de presentacion.
  Stream<List<ProyectoConResumen>> observar(
    String duenoAuthUid, {
    bool soloActivos = true,
  }) {
    final cuantosMapas = _db.mapas.codigo.count();
    final megas = _db.mapas.tamanoMb.sum();

    final consulta =
        _db.select(_db.proyectos).join([
            // Solo los mapas con `rutaLocal`: un mapa que existe en el servidor pero
            // no se bajo no ocupa nada en el telefono y no puede sumar MB.
            leftOuterJoin(
              _db.mapas,
              _db.mapas.proyectoCodigo.equalsExp(_db.proyectos.codigo) &
                  _db.mapas.rutaLocal.isNotNull(),
            ),
          ])
          ..addColumns([cuantosMapas, megas])
          ..groupBy([_db.proyectos.id])
          // El ultimo creado arriba: en campo se trabaja sobre el proyecto que se
          // acaba de abrir, no sobre el de hace seis meses.
          ..orderBy([OrderingTerm.desc(_db.proyectos.creadoEn)]);

    var filtro = _db.proyectos.duenoAuthUid.equals(duenoAuthUid);
    if (soloActivos) filtro = filtro & _db.proyectos.activo.equals(true);
    consulta.where(filtro);

    return consulta.watch().map(
      (filas) => filas
          .map(
            (f) => ProyectoConResumen(
              proyecto: f.readTable(_db.proyectos),
              mapasDescargados: f.read(cuantosMapas) ?? 0,
              megasUsadas: f.read(megas) ?? 0,
            ),
          )
          .toList(),
    );
  }

  /// Crea un proyecto y devuelve la fila ya guardada.
  ///
  /// El UUID lo genera el telefono, no el backend: el proyecto tiene que poder
  /// nacer en un lote sin senal y ser el mismo cuando se sincronice. Queda con
  /// `sincronizado = false`, que es lo que el sincronizador mira despues.
  Future<Proyecto> crear({
    required String duenoAuthUid,
    required String nombre,
    String? cliente,
    String? municipio,
  }) {
    return _db
        .into(_db.proyectos)
        .insertReturning(
          ProyectosCompanion.insert(
            codigo: _uuid.v4(),
            duenoAuthUid: duenoAuthUid,
            nombre: nombre.trim(),
            cliente: Value(_oNulo(cliente)),
            municipio: Value(_oNulo(municipio)),
            creadoEn: DateTime.now(),
          ),
        );
  }

  /// Saca un proyecto de la lista sin borrarlo.
  ///
  /// No hay borrado de verdad a proposito: adentro cuelgan trazados y waypoints
  /// que quizas todavia no subieron, y un DELETE en cascada se llevaria por
  /// delante una jornada de campo que nadie puede recuperar.
  Future<void> archivar(String codigo, {bool activo = false}) {
    return (_db.update(
      _db.proyectos,
    )..where((p) => p.codigo.equals(codigo))).write(
      ProyectosCompanion(
        activo: Value(activo),
        actualizadoEn: Value(DateTime.now()),
        // Volvio a cambiar: hay que subirlo de nuevo.
        sincronizado: const Value(false),
      ),
    );
  }

  /// Cuantos proyectos activos tiene la cuenta. Lo usa el home para el contador
  /// de la tarjeta sin tener que traerse la lista entera.
  Stream<int> contarActivos(String duenoAuthUid) {
    final cuantos = _db.proyectos.id.count();
    final consulta = _db.selectOnly(_db.proyectos)
      ..addColumns([cuantos])
      ..where(
        _db.proyectos.duenoAuthUid.equals(duenoAuthUid) &
            _db.proyectos.activo.equals(true),
      );
    return consulta.map((f) => f.read(cuantos) ?? 0).watchSingle();
  }

  /// Un campo opcional que quedo vacio es un null, no un `""`. Guardar la
  /// cadena vacia hace que la pantalla muestre un renglon en blanco en vez de
  /// omitir el dato.
  String? _oNulo(String? valor) {
    final limpio = valor?.trim();
    return (limpio == null || limpio.isEmpty) ? null : limpio;
  }

  /// Un proyecto por su codigo, en vivo. Nulo si no esta.
  Stream<Proyecto?> observarUno(String codigo) {
    return (_db.select(
      _db.proyectos,
    )..where((p) => p.codigo.equals(codigo))).watchSingleOrNull();
  }

  /// Los que faltan subir, el mas viejo primero. Entran los archivados: que
  /// se archivo tambien es un cambio que la base tiene que conocer.
  Future<List<Proyecto>> pendientes(String duenoAuthUid) {
    final consulta = _db.select(_db.proyectos)
      ..where(
        (p) =>
            p.duenoAuthUid.equals(duenoAuthUid) & p.sincronizado.equals(false),
      )
      ..orderBy([(p) => OrderingTerm.asc(p.creadoEn)]);
    return consulta.get();
  }

  /// Cuantos faltan subir, en vivo.
  Stream<int> contarPendientes(String duenoAuthUid) {
    final cuantos = _db.proyectos.id.count();
    final consulta = _db.selectOnly(_db.proyectos)
      ..addColumns([cuantos])
      ..where(
        _db.proyectos.duenoAuthUid.equals(duenoAuthUid) &
            _db.proyectos.sincronizado.equals(false),
      );
    return consulta.map((f) => f.read(cuantos) ?? 0).watchSingle();
  }

  Future<void> marcarSubido(String codigo) {
    return (_db.update(_db.proyectos)..where((p) => p.codigo.equals(codigo)))
        .write(const ProyectosCompanion(sincronizado: Value(true)));
  }

  // TODO: mezclarDirectorio(List<ProyectoRemoto>) -- rellenar, no pisar.
}
