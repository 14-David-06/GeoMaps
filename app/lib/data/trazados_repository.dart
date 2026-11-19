import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/geo.dart';
import '../core/geojson.dart';
import 'db/app_database.dart';
import 'db/enums.dart';
import 'mapas_repository.dart';

/// Una ruta calculada que alguien guardo desde el mapa, lista para la lista.
class RutaGuardada {
  const RutaGuardada({
    required this.codigo,
    required this.nombre,
    required this.destino,
    required this.metros,
    required this.creadaEn,
    required this.sincronizada,
  });

  final String codigo;
  final String nombre;

  /// A donde lleva: el ultimo punto de la linea. Volver a abrir la ruta es
  /// volver a pedir el camino hasta aca **desde donde se esta parado**, no
  /// redibujar la de aquel dia: una ruta que arranca donde uno estaba la semana
  /// pasada no sirve para llegar.
  final PuntoGeo destino;

  final double? metros;
  final DateTime creadaEn;
  final bool sincronizada;
}

/// Trazados: rutas y poligonos.
///
/// El repositorio es el unico que escribe `areaHa`, `distanciaM`,
/// `precisionMediaM`, `bbox` y el centroide, siempre recalculandolos con
/// `core/geo.dart` al cerrar el trazado. Si esos numeros se calcularan en la
/// pantalla, un trazado editado despues quedaria con el area vieja y nadie lo
/// notaria.
///
/// ## Donde vive la geometria
///
/// En dos sitios, y no es duplicacion:
///
/// - **SQLite local** (`geometria`): completa, y es la fuente de verdad
///   mientras el telefono esta en campo. Sin red no hay otra cosa.
/// - **S3** (`llaveGeometria`): el mismo GeoJSON, subido al sincronizar. Es la
///   copia que consulta el resto del mundo.
///
/// Airtable no guarda ninguna de las dos: guarda la llave, el bbox, el
/// centroide, los numeros y una vista previa de 50 vertices.
///
/// El orden al sincronizar importa: **primero S3, despues Airtable**. Una fila
/// con `Llave geometria` apuntando a un objeto que no existe es un trazado que
/// en la base parece estar y al abrirlo no esta. Ese orden lo cumple el
/// backend; el telefono manda las dos cosas juntas.
class TrazadosRepository {
  TrazadosRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Guarda la ruta que se esta mostrando en el mapa.
  ///
  /// Cae en el proyecto local, como los planos importados: el mapa se abre sin
  /// proyecto. El backend lo traduce a un proyecto por cuenta al subirla.
  ///
  /// La distancia no se recalcula: es la que dio el ruteo, la misma que vio la
  /// persona en la tarjeta antes de guardarla.
  Future<Trazado> guardarRuta({
    required String usuarioCodigo,
    required String nombre,
    required List<PuntoGeo> linea,
    required double metros,
    String proyectoCodigo = MapasRepository.proyectoLocal,
  }) {
    if (linea.length < 2) {
      throw ArgumentError('Una ruta necesita al menos dos puntos.');
    }
    final limpio = nombre.trim();
    final centro = GeoJson.centroide(linea);
    final ahora = DateTime.now();

    return _db
        .into(_db.trazados)
        .insertReturning(
          TrazadosCompanion.insert(
            codigo: _uuid.v4(),
            proyectoCodigo: proyectoCodigo,
            nombre: limpio.isEmpty ? 'Ruta sin nombre' : limpio,
            tipo: TipoTrazado.ruta.name,
            metodo: MetodoCaptura.calculada.name,
            geometria: jsonEncode(
              GeoJson.linea(
                linea,
                propiedades: {
                  'nombre': limpio,
                  'metodo': MetodoCaptura.calculada.name,
                  'distancia_m': metros.roundToDouble(),
                },
              ),
            ),
            bbox: Value(GeoJson.bbox(linea)),
            centroLat: Value(centro.latitud),
            centroLon: Value(centro.longitud),
            puntos: Value(linea.length),
            distanciaM: Value(metros),
            usuarioCodigo: Value(usuarioCodigo),
            creadoEn: ahora,
          ),
        );
  }

  /// Las rutas guardadas de una cuenta, la mas nueva arriba, en vivo.
  ///
  /// Filtra por usuario siempre: un mismo telefono pasa por varias cuentas.
  Stream<List<RutaGuardada>> observarRutas(String usuarioCodigo) {
    final consulta = _db.select(_db.trazados)
      ..where(
        (t) =>
            t.usuarioCodigo.equals(usuarioCodigo) &
            t.metodo.equals(MetodoCaptura.calculada.name),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.creadoEn)]);

    return consulta.watch().map(
      (filas) => [
        for (final t in filas)
          RutaGuardada(
            codigo: t.codigo,
            nombre: t.nombre,
            destino: GeoJson.puntosDeLinea(
              jsonDecode(t.geometria) as Map<String, dynamic>,
            ).last,
            metros: t.distanciaM,
            creadaEn: t.creadoEn,
            sincronizada: t.sincronizado,
          ),
      ],
    );
  }

  /// Guarda un area medida en el mapa: el lote que alguien marco esquina por
  /// esquina con el dedo.
  ///
  /// Es `manual` y no `automatico` porque nadie camino ese lindero: no tiene
  /// precision de GPS, y por eso no puede pasar por un levantamiento.
  ///
  /// La geometria se guarda como **linea cerrada** -el primer vertice repetido
  /// al final- y no como `Polygon`: es lo que el backend ya sabe recibir, y el
  /// `tipo` dice que es un poligono. Al exportar a KML sale como `Polygon`.
  Future<Trazado> guardarPoligono({
    required String usuarioCodigo,
    required String nombre,
    required List<PuntoGeo> vertices,
    String proyectoCodigo = MapasRepository.proyectoLocal,
  }) {
    if (vertices.length < 3) {
      throw ArgumentError('Un poligono necesita al menos tres vertices.');
    }
    final limpio = nombre.trim();
    final anillo = [...vertices, vertices.first];
    final centro = GeoJson.centroide(vertices);
    final hectareas = areaHa(vertices);
    final perimetro = perimetroM(vertices);
    final ahora = DateTime.now();

    return _db
        .into(_db.trazados)
        .insertReturning(
          TrazadosCompanion.insert(
            codigo: _uuid.v4(),
            proyectoCodigo: proyectoCodigo,
            nombre: limpio.isEmpty ? 'Area sin nombre' : limpio,
            tipo: TipoTrazado.poligono.name,
            metodo: MetodoCaptura.manual.name,
            geometria: jsonEncode(
              GeoJson.linea(
                anillo,
                propiedades: {
                  'nombre': limpio,
                  'metodo': MetodoCaptura.manual.name,
                  'area_ha': double.parse(hectareas.toStringAsFixed(4)),
                  'perimetro_m': perimetro.roundToDouble(),
                },
              ),
            ),
            bbox: Value(GeoJson.bbox(vertices)),
            centroLat: Value(centro.latitud),
            centroLon: Value(centro.longitud),
            puntos: Value(vertices.length),
            distanciaM: Value(perimetro),
            areaHa: Value(hectareas),
            usuarioCodigo: Value(usuarioCodigo),
            iniciadoEn: Value(ahora),
            terminadoEn: Value(ahora),
            creadoEn: ahora,
          ),
        );
  }

  /// Lo que la cuenta levanto en campo: recorridos grabados y areas medidas,
  /// lo mas nuevo arriba, en vivo. Las rutas calculadas no van aca -tienen su
  /// lista-, ni la grabacion que todavia esta en curso.
  Stream<List<Trazado>> observarLevantados(String usuarioCodigo) {
    final consulta = _db.select(_db.trazados)
      ..where(
        (t) =>
            t.usuarioCodigo.equals(usuarioCodigo) &
            t.metodo.equals(MetodoCaptura.calculada.name).not() &
            t.terminadoEn.isNotNull(),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.creadoEn)]);
    return consulta.watch();
  }

  /// Le cambia el nombre. Vuelve a quedar pendiente de subir: el nombre es lo
  /// que se lee en Airtable.
  Future<void> renombrar(String codigo, String nombre) {
    final limpio = nombre.trim();
    if (limpio.isEmpty) return Future.value();
    return (_db.update(
      _db.trazados,
    )..where((t) => t.codigo.equals(codigo))).write(
      TrazadosCompanion(
        nombre: Value(limpio),
        sincronizado: const Value(false),
        actualizadoEn: Value(DateTime.now()),
      ),
    );
  }

  /// La saca del telefono. Si ya subio, la fila de Airtable y el GeoJSON de S3
  /// se quedan: borrar del lado del servidor no existe todavia.
  Future<void> borrar(String codigo) {
    return (_db.delete(
      _db.trazados,
    )..where((t) => t.codigo.equals(codigo))).go();
  }

  /// Lo que falta subir, lo mas viejo primero: si la tanda se corta, que lo
  /// que lleva mas tiempo esperando sea lo que ya quedo.
  ///
  /// Una grabacion en curso no cuenta: su linea todavia crece, y subirla a
  /// medias dejaria en la base un viaje cortado que parece completo.
  Future<List<Trazado>> pendientes(String usuarioCodigo) {
    final consulta = _db.select(_db.trazados)
      ..where(
        (t) =>
            t.usuarioCodigo.equals(usuarioCodigo) &
            t.sincronizado.equals(false) &
            _cerrado(t),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.creadoEn)]);
    return consulta.get();
  }

  /// Cuantos faltan por subir. Lo muestra la tarjeta de sincronizar.
  Stream<int> contarPendientes(String usuarioCodigo) {
    final cuantos = _db.trazados.id.count();
    final consulta = _db.selectOnly(_db.trazados)
      ..addColumns([cuantos])
      ..where(
        _db.trazados.usuarioCodigo.equals(usuarioCodigo) &
            _db.trazados.sincronizado.equals(false) &
            _cerrado(_db.trazados),
      );
    return consulta.map((f) => f.read(cuantos) ?? 0).watchSingle();
  }

  /// El backend confirmo el trazado: queda subido y con su llave de S3.
  Future<void> marcarSubido(String codigo, String llaveGeometria) {
    return (_db.update(
      _db.trazados,
    )..where((t) => t.codigo.equals(codigo))).write(
      TrazadosCompanion(
        sincronizado: const Value(true),
        llaveGeometria: Value(llaveGeometria),
      ),
    );
  }

  /// Terminado, o una ruta calculada, que nace terminada.
  Expression<bool> _cerrado($TrazadosTable t) =>
      t.metodo.equals(MetodoCaptura.calculada.name) | t.terminadoEn.isNotNull();

  // ------------------------------ Grabacion ------------------------------

  /// Abre la grabacion de un recorrido. La fila existe desde el primer
  /// segundo, con la linea vacia: si Android mata la app a mitad del viaje, lo
  /// grabado hasta el ultimo guardado sigue en la base.
  ///
  /// [propiedades] va al GeoJSON: lo que hace util el archivo suelto, como la
  /// vuelta de la planilla que se fue a recoger.
  Future<Trazado> abrirGrabacion({
    required String usuarioCodigo,
    required String nombre,
    Map<String, Object?> propiedades = const {},
    String proyectoCodigo = MapasRepository.proyectoLocal,
  }) {
    final ahora = DateTime.now();
    return _db
        .into(_db.trazados)
        .insertReturning(
          TrazadosCompanion.insert(
            codigo: _uuid.v4(),
            proyectoCodigo: proyectoCodigo,
            nombre: nombre,
            tipo: TipoTrazado.ruta.name,
            metodo: MetodoCaptura.automatico.name,
            geometria: jsonEncode(
              GeoJson.linea(const [], propiedades: propiedades),
            ),
            usuarioCodigo: Value(usuarioCodigo),
            iniciadoEn: Value(ahora),
            creadoEn: ahora,
          ),
        );
  }

  /// La grabacion que quedo abierta, si la hay: la app se cerro o la mato
  /// Android a mitad del viaje.
  Future<Trazado?> grabacionAbierta(String usuarioCodigo) {
    final consulta = _db.select(_db.trazados)
      ..where(
        (t) =>
            t.usuarioCodigo.equals(usuarioCodigo) &
            t.metodo.equals(MetodoCaptura.automatico.name) &
            t.terminadoEn.isNull(),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.creadoEn)])
      ..limit(1);
    return consulta.getSingleOrNull();
  }

  /// Guarda la linea grabada hasta ahora. Se llama cada tantos puntos, no por
  /// cada fix: reescribir la fila una vez por segundo durante dos horas es
  /// gastar disco y bateria en algo que no se mira.
  ///
  /// [propiedades] se suma a las que el recorrido ya tenia: es por donde
  /// entra lo que pasa a mitad de camino, como haber llegado a los vagones.
  Future<void> guardarAvance(
    String codigo,
    List<PuntoGeo> puntos, {
    Map<String, Object?> propiedades = const {},
  }) async {
    final fila = await _fila(codigo);
    if (fila == null) return;
    await (_db.update(
      _db.trazados,
    )..where((t) => t.codigo.equals(codigo))).write(
      TrazadosCompanion(
        geometria: Value(
          _conPuntos(fila.geometria, puntos, extra: propiedades),
        ),
        puntos: Value(puntos.length),
      ),
    );
  }

  /// Cierra la grabacion y calcula sus numeros. Queda lista para subir.
  ///
  /// Con menos de dos puntos no hay recorrido que guardar -el GPS nunca
  /// engancho, o se termino al arrancar- y la fila se borra en vez de dejar
  /// una linea vacia que el backend rechazaria para siempre.
  Future<Trazado?> cerrarGrabacion(
    String codigo,
    List<PuntoGeo> puntos, {
    double? precisionMediaM,
    Map<String, Object?> propiedades = const {},
  }) async {
    final fila = await _fila(codigo);
    if (fila == null) return null;
    if (puntos.length < 2) {
      await borrar(codigo);
      return null;
    }
    final centro = GeoJson.centroide(puntos);
    final distancia = longitudRutaM(puntos);
    final ahora = DateTime.now();
    await (_db.update(
      _db.trazados,
    )..where((t) => t.codigo.equals(codigo))).write(
      TrazadosCompanion(
        geometria: Value(
          _conPuntos(
            fila.geometria,
            puntos,
            distanciaM: distancia,
            extra: propiedades,
          ),
        ),
        puntos: Value(puntos.length),
        distanciaM: Value(distancia),
        precisionMediaM: Value(precisionMediaM),
        bbox: Value(GeoJson.bbox(puntos)),
        centroLat: Value(centro.latitud),
        centroLon: Value(centro.longitud),
        terminadoEn: Value(ahora),
        actualizadoEn: Value(ahora),
        sincronizado: const Value(false),
      ),
    );
    return _fila(codigo);
  }

  /// Los puntos ya guardados de un trazado, para seguir grabando donde quedo.
  static List<PuntoGeo> puntosDe(Trazado t) =>
      GeoJson.puntosDeLinea(jsonDecode(t.geometria) as Map<String, dynamic>);

  Future<Trazado?> _fila(String codigo) => (_db.select(
    _db.trazados,
  )..where((t) => t.codigo.equals(codigo))).getSingleOrNull();

  /// La misma geometria con otros puntos, conservando sus propiedades.
  static String _conPuntos(
    String geometria,
    List<PuntoGeo> puntos, {
    double? distanciaM,
    Map<String, Object?> extra = const {},
  }) {
    final anterior = jsonDecode(geometria) as Map<String, dynamic>;
    final propiedades = Map<String, Object?>.from(
      anterior['properties'] as Map? ?? const {},
    )..addAll(extra);
    if (distanciaM != null) propiedades['distancia_m'] = distanciaM.round();
    return jsonEncode(GeoJson.linea(puntos, propiedades: propiedades));
  }
}
