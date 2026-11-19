import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/geo.dart';
import 'db/app_database.dart';
import 'db/enums.dart';
import 'mapas_repository.dart';

/// Waypoints: los puntos marcados a mano.
///
/// Un punto es lo mas chico que se levanta en campo -"aca hay una alcantarilla
/// rota", "de este arbol salio la muestra"- y por eso tiene que poder marcarse
/// en dos toques y sin senal. Quedan en el telefono, se ven sobre el mapa y
/// salen en el KML y el GPX que se comparten.
///
/// Suben a Airtable con la sincronizacion, despues de los trazados: un punto
/// marcado durante un recorrido se enlaza a su fila, y para eso el recorrido
/// tiene que haber subido antes.
class WaypointsRepository {
  WaypointsRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Marca un punto. [precisionM] es la que reporto el GPS al marcarlo, o
  /// nulo si el punto se eligio con el dedo sobre el mapa: ahi no hay GPS que
  /// responda por el, y decirlo es lo que impide usarlo como lindero.
  Future<Waypoint> marcar({
    required String usuarioCodigo,
    required String nombre,
    required PuntoGeo punto,
    SimboloWaypoint simbolo = SimboloWaypoint.generico,
    String? nota,
    double? precisionM,
    double? altitudM,
    String? trazadoCodigo,
    DateTime? marcadoEn,
    String proyectoCodigo = MapasRepository.proyectoLocal,
  }) {
    final ahora = DateTime.now();
    final limpio = nombre.trim();
    final notaLimpia = nota?.trim();
    return _db
        .into(_db.waypoints)
        .insertReturning(
          WaypointsCompanion.insert(
            codigo: _uuid.v4(),
            proyectoCodigo: proyectoCodigo,
            trazadoCodigo: Value(trazadoCodigo),
            nombre: limpio.isEmpty ? 'Punto sin nombre' : limpio,
            latitud: punto.latitud,
            longitud: punto.longitud,
            altitudM: Value(altitudM),
            precisionM: Value(precisionM),
            simbolo: simbolo.name,
            nota: Value(
              notaLimpia == null || notaLimpia.isEmpty ? null : notaLimpia,
            ),
            marcadoEn: marcadoEn ?? ahora,
            usuarioCodigo: Value(usuarioCodigo),
            creadoEn: ahora,
          ),
        );
  }

  /// Los puntos de una cuenta, el mas nuevo arriba, en vivo.
  ///
  /// Filtra por usuario siempre: un mismo telefono pasa por varias cuentas.
  Stream<List<Waypoint>> observar(String usuarioCodigo) {
    final consulta = _db.select(_db.waypoints)
      ..where((w) => w.usuarioCodigo.equals(usuarioCodigo))
      ..orderBy([(w) => OrderingTerm.desc(w.marcadoEn)]);
    return consulta.watch();
  }

  /// Los que se marcaron mientras se grababa un recorrido: salen con el en el
  /// archivo que se comparte.
  Future<List<Waypoint>> delTrazado(String trazadoCodigo) {
    final consulta = _db.select(_db.waypoints)
      ..where((w) => w.trazadoCodigo.equals(trazadoCodigo))
      ..orderBy([(w) => OrderingTerm.asc(w.marcadoEn)]);
    return consulta.get();
  }

  Future<void> borrar(String codigo) {
    return (_db.delete(
      _db.waypoints,
    )..where((w) => w.codigo.equals(codigo))).go();
  }

  /// Lo que se puede subir ahora, lo mas viejo primero.
  ///
  /// Un punto atado a un recorrido que todavia no subio -porque se sigue
  /// grabando, o porque su tanda fallo- espera: subirlo antes lo dejaria en
  /// la base sin el enlace a su recorrido, y despues nadie se lo pone.
  Future<List<Waypoint>> pendientes(String usuarioCodigo) async {
    final consulta = _db.select(_db.waypoints)
      ..where(
        (w) =>
            w.usuarioCodigo.equals(usuarioCodigo) &
            w.sincronizado.equals(false),
      )
      ..orderBy([(w) => OrderingTerm.asc(w.creadoEn)]);
    final filas = await consulta.get();
    if (filas.every((w) => w.trazadoCodigo == null)) return filas;

    final sinSubir = _db.selectOnly(_db.trazados)
      ..addColumns([_db.trazados.codigo])
      ..where(_db.trazados.sincronizado.equals(false));
    final esperan = {
      for (final f in await sinSubir.get()) f.read(_db.trazados.codigo),
    };
    return [
      for (final w in filas)
        if (!esperan.contains(w.trazadoCodigo)) w,
    ];
  }

  /// Cuantos faltan por subir, en vivo. Cuenta tambien los que esperan a su
  /// recorrido: siguen sin estar en la base, que es lo que la tarjeta dice.
  Stream<int> contarPendientes(String usuarioCodigo) {
    final cuantos = _db.waypoints.id.count();
    final consulta = _db.selectOnly(_db.waypoints)
      ..addColumns([cuantos])
      ..where(
        _db.waypoints.usuarioCodigo.equals(usuarioCodigo) &
            _db.waypoints.sincronizado.equals(false),
      );
    return consulta.map((f) => f.read(cuantos) ?? 0).watchSingle();
  }

  /// El backend confirmo el punto.
  Future<void> marcarSubido(String codigo) {
    return (_db.update(_db.waypoints)..where((w) => w.codigo.equals(codigo)))
        .write(const WaypointsCompanion(sincronizado: Value(true)));
  }
}
