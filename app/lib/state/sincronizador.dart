import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../camiones/seguimiento.dart';
import '../core/api_client.dart';
import '../data/archivos_repository.dart';
import '../data/db/app_database.dart';
import '../data/db/enums.dart';
import '../data/proyectos_repository.dart';
import '../data/trazados_repository.dart';
import '../data/waypoints_repository.dart';
import '../ui/proveedor_teselas.dart' show reanudarTeselas;
import 'errores.dart';
import 'providers.dart';
import 'red.dart';
import 'sesion.dart';

/// Lo que la pantalla necesita saber de la subida.
class EstadoSincronizacion {
  const EstadoSincronizacion({
    this.subiendo = false,
    this.ultimaVez,
    this.subidos = 0,
    this.fallidos = 0,
    this.error,
  });

  final bool subiendo;

  /// Cuando termino el ultimo intento, haya salido bien o no.
  final DateTime? ultimaVez;

  final int subidos;
  final int fallidos;

  /// Por que fallo el ultimo intento, en palabras para alguien en el lote.
  final String? error;
}

/// Sube a Airtable lo que se hizo sin senal.
///
/// Corre cuando hay red y hay filas con `sincronizado = false`. El orden no es
/// arbitrario: Airtable necesita los enlaces resueltos, asi que un waypoint no
/// puede subir antes que su proyecto.
///
///   Proyectos -> Mapas -> Trazados -> Waypoints -> Archivos -> Sincronizaciones
///
/// Hoy sube los proyectos, los trazados, los puntos marcados y las fotos de
/// los puntos, en ese orden. Cada paso es un upsert por UUID: si una tanda se corta, la
/// siguiente no duplica lo que ya quedo. Las fotos no pasan por el backend:
/// se le pide a donde subirlas y van directo al bucket. Cada intento deja una fila en `Sincronizaciones` local, y el backend
/// deja otra en Airtable: entre las dos se explica un dato que alguien dice que
/// no aparece.
class Sincronizador extends StateNotifier<EstadoSincronizacion> {
  Sincronizador(
    this._db,
    this._trazados,
    this._api,
    this._usuario, {
    ArchivosRepository? archivos,
    this._authUid,
  }) : _waypoints = WaypointsRepository(_db),
       _archivos = archivos ?? ArchivosRepository(_db),
       _proyectos = ProyectosRepository(_db),
       super(const EstadoSincronizacion());

  final AppDatabase _db;
  final TrazadosRepository _trazados;
  final WaypointsRepository _waypoints;
  final ArchivosRepository _archivos;
  final ProyectosRepository _proyectos;

  /// De quien son los proyectos: en el telefono van por `Auth UID`, no por el
  /// codigo de usuario. Nulo en las pruebas que no tocan proyectos.
  final String? _authUid;
  final ApiClient _api;
  final String? _usuario;

  /// Aparte de `state.subiendo` porque se marca antes del primer `await`: dos
  /// llamadas en el mismo cuadro -guardar y volver la red- verian las dos
  /// `subiendo` en falso y mandarian la misma tanda dos veces.
  bool _corriendo = false;

  /// Cuantos trazados por request. Del otro lado es una funcion serverless con
  /// tiempo limitado y Airtable a cinco escrituras por segundo: una tanda chica
  /// que se corta pierde poco.
  static const tanda = 5;

  /// Los puntos entran de a mas: del otro lado son dos llamadas y ninguna a
  /// S3. El tope lo fija el backend en `SyncRequest`.
  static const tandaPuntos = 20;

  /// Sube todo lo pendiente. Llamarlo dos veces seguidas no sube dos veces:
  /// mientras corre, la segunda llamada vuelve sin hacer nada.
  Future<void> sincronizar() async {
    final usuario = _usuario;
    if (_corriendo || usuario == null || usuario.isEmpty) return;
    if (_api.token == null) return; // Sin sesion no hay a nombre de quien.

    _corriendo = true;
    try {
      await _subir(usuario);
    } finally {
      _corriendo = false;
    }
  }

  Future<void> _subir(String usuario) async {
    final pendientes = await _trazados.pendientes(usuario);
    final hayPuntos = (await _waypoints.pendientes(usuario)).isNotEmpty;
    final hayFotos = (await _archivos.fotosParaSubir(usuario)).isNotEmpty;
    final authUid = _authUid;
    final proyectos = authUid == null
        ? const <Proyecto>[]
        : await _proyectos.pendientes(authUid);
    if ((pendientes.isEmpty && !hayPuntos && !hayFotos && proyectos.isEmpty) ||
        !mounted) {
      return;
    }

    state = EstadoSincronizacion(subiendo: true, ultimaVez: state.ultimaVez);
    final inicio = DateTime.now();
    var subidos = 0;
    var enviados = pendientes.length + proyectos.length;
    final errores = <String>[];

    try {
      // Los proyectos primero: lo que sigue se cuelga de ellos, y un recorrido
      // cuyo proyecto todavia no esta arriba se rechaza.
      for (var i = 0; i < proyectos.length; i += tandaPuntos) {
        final parte = proyectos.skip(i).take(tandaPuntos).toList();
        final respuesta = await _api.sincronizar({
          'proyectos': [
            for (final p in parte)
              {
                'codigo': p.codigo,
                'nombre': p.nombre,
                'cliente': p.cliente,
                'municipio': p.municipio,
                'activo': p.activo,
              },
          ],
        });
        final resultados = respuesta['proyectos'] as List<dynamic>?;
        if (resultados == null || resultados.isEmpty) {
          // Un backend anterior a los proyectos: acepta la llamada y no dice
          // nada de ellos. Lo demas sube igual.
          errores.add(
            'El servidor todavia no recibe proyectos. Quedan guardados en el '
            'telefono, con lo que se levanto en ellos, y suben cuando se '
            'actualice.',
          );
          break;
        }
        for (final r in resultados.cast<Map<String, dynamic>>()) {
          if (r['ok'] == true) {
            await _proyectos.marcarSubido(r['codigo'] as String);
            subidos++;
          } else {
            final nombre =
                parte
                    .where((p) => p.codigo == r['codigo'])
                    .firstOrNull
                    ?.nombre ??
                '${r['codigo']}';
            errores.add('Proyecto $nombre: ${r['error']}');
          }
        }
      }

      for (var i = 0; i < pendientes.length; i += tanda) {
        final parte = pendientes.skip(i).take(tanda).toList();
        final respuesta = await _api.sincronizar({
          'trazados': [for (final t in parte) _aJson(t)],
        });
        for (final r
            in (respuesta['trazados'] as List<dynamic>)
                .cast<Map<String, dynamic>>()) {
          if (r['ok'] == true) {
            await _trazados.marcarSubido(
              r['codigo'] as String,
              r['llave_geometria'] as String,
            );
            subidos++;
          } else {
            errores.add('${_nombre(parte, r['codigo'])}: ${r['error']}');
          }
        }
      }

      // Los puntos se leen recien aca: los que esperaban a su recorrido ya
      // pueden subir si el recorrido acaba de quedar arriba.
      final puntos = await _waypoints.pendientes(usuario);
      enviados += puntos.length;
      for (var i = 0; i < puntos.length; i += tandaPuntos) {
        final parte = puntos.skip(i).take(tandaPuntos).toList();
        final respuesta = await _api.sincronizar({
          'waypoints': [for (final w in parte) _puntoAJson(w)],
        });
        final resultados = respuesta['waypoints'] as List<dynamic>?;
        if (resultados == null) {
          // Un backend anterior a los puntos: acepta la llamada y no dice
          // nada de ellos. No es un error del telefono ni se arregla
          // reintentando ahora.
          errores.add(
            'El servidor todavia no recibe puntos marcados. Quedan guardados '
            'en el telefono y suben cuando se actualice.',
          );
          break;
        }
        for (final r in resultados.cast<Map<String, dynamic>>()) {
          if (r['ok'] == true) {
            await _waypoints.marcarSubido(r['codigo'] as String);
            subidos++;
          } else {
            final nombre =
                parte
                    .where((w) => w.codigo == r['codigo'])
                    .firstOrNull
                    ?.nombre ??
                '${r['codigo']}';
            errores.add('$nombre: ${r['error']}');
          }
        }
      }

      // Las fotos van al final: cada una se enlaza a su punto, y para eso el
      // punto tiene que haber subido. Las de puntos que acaban de subir en
      // esta misma pasada ya entran.
      final fotos = await _archivos.fotosParaSubir(usuario);
      enviados += fotos.length;
      for (final foto in fotos) {
        final archivo = File(foto.rutaLocal);
        if (!await archivo.exists()) {
          // El archivo ya no esta en el telefono: no hay nada que subir, y
          // una fila sola quedaria como "1 pendiente" para siempre.
          await _archivos.borrarFoto(foto.codigo);
          enviados--;
          continue;
        }
        try {
          final donde = await _api.pedirSubidaFoto({
            'codigo': foto.codigo,
            'waypoint_codigo': foto.waypointCodigo,
            'proyecto_codigo': foto.proyectoCodigo,
            'tamano_bytes': await archivo.length(),
          });
          await _api.subirArchivo(
            donde['url'] as String,
            await archivo.readAsBytes(),
            donde['content_type'] as String? ?? 'image/jpeg',
          );
          final confirmada = await _api.confirmarFoto(foto.codigo, {
            'waypoint_codigo': foto.waypointCodigo,
            'proyecto_codigo': foto.proyectoCodigo,
            'tomada_en': foto.creadoEn.toUtc().toIso8601String(),
          });
          await _archivos.marcarSubida(
            foto.codigo,
            confirmada['llave'] as String,
          );
          subidos++;
        } on ApiError catch (e) {
          if (e.sesionInvalida) rethrow;
          if (e.codigo == 404 || e.codigo == 405) {
            // Un backend anterior a las fotos. No se arregla reintentando
            // ahora: se corta aca y se dice una sola vez.
            errores.add(
              'El servidor todavia no recibe fotos. Quedan guardadas en el '
              'telefono y suben cuando se actualice.',
            );
            break;
          }
          errores.add('Una foto no subio: ${e.mensaje}');
        }
      }
    } on ApiError catch (e) {
      errores.add(
        e.sesionInvalida
            ? 'La sesion vencio. Volve a entrar con senal; lo guardado no se '
                  'pierde.'
            : e.mensaje,
      );
    } on TimeoutException {
      errores.add('El servidor no contesto a tiempo. Se reintenta solo.');
    } on SocketException {
      errores.add('Sin conexion con el servidor. Se reintenta con senal.');
    } on Exception catch (e) {
      errores.add('$e');
    }

    final fallidos = enviados - subidos;
    await _anotar(inicio, enviados, subidos, errores);
    // Cerrar sesion a mitad de la subida descarta este notifier.
    if (!mounted) return;
    state = EstadoSincronizacion(
      ultimaVez: DateTime.now(),
      subidos: subidos,
      fallidos: fallidos,
      error: errores.isEmpty ? null : errores.join('\n'),
    );
  }

  Map<String, dynamic> _aJson(Trazado t) {
    final geometria = jsonDecode(t.geometria) as Map<String, dynamic>;
    // La calificacion vive en las propiedades del GeoJSON. Se manda tambien
    // aparte para que el backend la ponga en la fila de Airtable, donde se
    // puede filtrar sin bajar el archivo.
    final propiedades =
        geometria['properties'] as Map<String, dynamic>? ?? const {};
    // Si es la vuelta de un camion, su seguimiento viaja con el recorrido:
    // es lo que la cierra en el servidor cuando se finalizo sin senal.
    final viaje = SeguimientoVuelta.cuerpo(
      propiedades,
      recorridoM: t.distanciaM,
    );
    return {
      'codigo': t.codigo,
      'proyecto_codigo': t.proyectoCodigo,
      'nombre': t.nombre,
      'tipo': t.tipo,
      'metodo': t.metodo,
      'geometria': geometria,
      if (propiedades['calificacion'] is int)
        'calificacion': propiedades['calificacion'],
      if (propiedades['calificacion_motivos'] is List)
        'calificacion_motivos': propiedades['calificacion_motivos'],
      if (propiedades['calificacion_comentario'] is String)
        'calificacion_comentario': propiedades['calificacion_comentario'],
      if (viaje != null) 'viaje': {'codigo': propiedades['viaje'], ...viaje},
      'distancia_m': t.distanciaM,
      'area_ha': t.areaHa,
      'precision_media_m': t.precisionMediaM,
      'bbox': t.bbox,
      'centro_lat': t.centroLat,
      'centro_lon': t.centroLon,
      'iniciado_en': t.iniciadoEn?.toUtc().toIso8601String(),
      'terminado_en': t.terminadoEn?.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> _puntoAJson(Waypoint w) => {
    'codigo': w.codigo,
    'proyecto_codigo': w.proyectoCodigo,
    'trazado_codigo': w.trazadoCodigo,
    'nombre': w.nombre,
    'latitud': w.latitud,
    'longitud': w.longitud,
    'altitud_m': w.altitudM,
    'precision_m': w.precisionM,
    'simbolo': w.simbolo,
    'nota': w.nota,
    'marcado_en': w.marcadoEn.toUtc().toIso8601String(),
  };

  String _nombre(List<Trazado> parte, Object? codigo) =>
      parte.where((t) => t.codigo == codigo).firstOrNull?.nombre ?? '$codigo';

  Future<void> _anotar(
    DateTime inicio,
    int enviados,
    int subidos,
    List<String> errores,
  ) async {
    final resultado = subidos == enviados
        ? ResultadoSync.ok
        : (subidos == 0 ? ResultadoSync.fallida : ResultadoSync.parcial);
    try {
      await _db
          .into(_db.sincronizaciones)
          .insert(
            SincronizacionesCompanion.insert(
              codigo: const Uuid().v4(),
              inicio: inicio,
              fin: Value(DateTime.now()),
              enviados: Value(enviados),
              fallidos: Value(enviados - subidos),
              estado: resultado.name,
              detalle: Value(errores.isEmpty ? null : errores.join('\n')),
            ),
          );
    } catch (_) {
      // El log no puede tumbar la subida: lo que subio, subio.
    }
  }
}

final trazadosRepositoryProvider = Provider<TrazadosRepository>(
  (ref) => TrazadosRepository(ref.watch(dbProvider)),
);

final sincronizadorProvider =
    StateNotifierProvider<Sincronizador, EstadoSincronizacion>(
      (ref) => Sincronizador(
        ref.watch(dbProvider),
        ref.watch(trazadosRepositoryProvider),
        ref.watch(apiProvider),
        ref.watch(sesionProvider.select((e) => e.sesion?.codigoUsuario)),
        archivos: ref.watch(archivosRepositoryProvider),
        authUid: ref.watch(sesionProvider.select((e) => e.sesion?.authUid)),
      ),
    );

/// Las rutas guardadas de la cuenta que esta adentro.
final rutasGuardadasProvider = StreamProvider<List<RutaGuardada>>((ref) {
  final usuario = ref.watch(
    sesionProvider.select((e) => e.sesion?.codigoUsuario),
  );
  if (usuario == null) return Stream.value(const []);
  return ref.watch(trazadosRepositoryProvider).observarRutas(usuario);
});

/// Cuanto falta por subir: proyectos, trazados, puntos marcados y fotos.
final pendientesProvider = StreamProvider<int>((ref) {
  final usuario = ref.watch(
    sesionProvider.select((e) => e.sesion?.codigoUsuario),
  );
  final authUid = ref.watch(sesionProvider.select((e) => e.sesion?.authUid));
  if (usuario == null) return Stream.value(0);
  final deLaCuenta = sumarConteos(
    sumarConteos(
      ref.watch(trazadosRepositoryProvider).contarPendientes(usuario),
      WaypointsRepository(ref.watch(dbProvider)).contarPendientes(usuario),
    ),
    ref.watch(archivosRepositoryProvider).contarPendientes(usuario),
  );
  if (authUid == null) return deLaCuenta;
  return sumarConteos(
    deLaCuenta,
    ref.watch(proyectosRepositoryProvider).contarPendientes(authUid),
  );
});

/// La suma de dos conteos en vivo. Emite en cuanto los dos dieron su primer
/// valor, y de ahi en mas cada vez que cambia cualquiera.
Stream<int> sumarConteos(Stream<int> a, Stream<int> b) {
  late final StreamController<int> salida;
  StreamSubscription<int>? subA;
  StreamSubscription<int>? subB;
  int? ultimoA;
  int? ultimoB;

  void emitir() {
    final x = ultimoA;
    final y = ultimoB;
    if (x != null && y != null) salida.add(x + y);
  }

  salida = StreamController<int>(
    onListen: () {
      subA = a.listen((v) {
        ultimoA = v;
        emitir();
      }, onError: salida.addError);
      subB = b.listen((v) {
        ultimoB = v;
        emitir();
      }, onError: salida.addError);
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );
  return salida.stream;
}

/// Dispara la subida cuando vuelve la red, y una vez al arrancar.
///
/// No hace falta que nadie se acuerde de sincronizar: el que guardo una ruta en
/// el lote y volvio al pueblo la tiene arriba en cuanto el telefono engancha.
/// Lo mantiene vivo la pantalla de inicio, que esta debajo de todas las demas.
final sincronizacionAutomaticaProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<RedState>>(redProvider, (antes, ahora) {
    final habia = antes?.valueOrNull?.hayRed ?? false;
    if (ahora.valueOrNull?.hayRed == true && !habia) {
      // El mapa deja de esperar su pausa: lo que quedo borroso por falta de
      // senal se vuelve a pedir ya.
      reanudarTeselas();
      ref.read(sincronizadorProvider.notifier).sincronizar();
      // Con senal, de paso se refresca la cuenta: es como le llega al
      // telefono un perfil que se asigno en Airtable. Se limita sola.
      ref.read(sesionProvider.notifier).renovar();
      // Y suben los fallos que la app anoto estando sin senal.
      unawaited(
        subirErrores(ref.read(registroErroresProvider), ref.read(apiProvider)),
      );
    }
  }, fireImmediately: true);
});
