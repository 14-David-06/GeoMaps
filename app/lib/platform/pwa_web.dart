import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import 'pwa_tipos.dart';

/// La fachada en el navegador. Todo pasa por `window.geomapsPwa`, que define
/// `web/geomaps_pwa.js` antes de que arranque Flutter: ahi vive lo que solo
/// se puede hacer en JavaScript (el service worker, la Cache API, el bloqueo
/// de pantalla). Si el puente no esta -una pagina servida sin el script-, la
/// app abre igual y simplemente no se guarda para usar sin senal.
abstract final class Pwa {
  static final estado = ValueNotifier<EstadoPwa>(const EstadoPwa());

  /// Como abrio drift la base en este navegador: `opfsShared`,
  /// `sharedIndexedDb`, `unsafeIndexedDb`... o `inMemory`, que quiere decir
  /// que lo que se guarde se pierde al cerrar. Lo muestra el diagnostico.
  static String? motorBase;

  static bool _arrancada = false;

  /// Engancha el estado del service worker. Se llama una vez, en `main`.
  static void arrancar() {
    if (_arrancada) return;
    _arrancada = true;
    final p = _puente;
    if (p == null) return;
    p.alCambiar(_refrescar.toJS);
    _refrescar();
  }

  static void _refrescar() {
    final p = _puente;
    if (p == null) return;
    try {
      final e = p.estado();
      final guardada = e.guardadaEl;
      estado.value = EstadoPwa(
        instalada: p.instalada(),
        esIphone: p.esIphone(),
        listaSinSenal: e.listaSinSenal,
        guardando: e.guardando,
        hechos: e.hechos.toInt(),
        total: e.total.toInt(),
        actualizacion: e.actualizacion,
        error: e.error,
        guardadaEl: guardada == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(guardada.toInt()),
      );
    } catch (_) {
      // Un estado ilegible no puede tumbar la app: se queda el anterior.
    }
  }

  /// Roboto, empaquetada en `web/fuentes/`.
  ///
  /// Sin esto Flutter la baja de fonts.gstatic.com la primera vez que pinta
  /// texto, y sin senal la app abre con cuadros vacios en vez de letras. Se
  /// cargan las tres gruesas que usa el tema: con una sola, las negritas de
  /// los avisos -que estan para que se lean al sol- salian finas.
  static Future<void> cargarFuentes() async {
    final base = _puente?.base();
    if (base == null) return;
    for (final archivo in const [
      'roboto-regular.ttf',
      'roboto-medium.ttf',
      'roboto-bold.ttf',
    ]) {
      try {
        final r = await http.get(Uri.parse(base).resolve('fuentes/$archivo'));
        if (r.statusCode != 200) continue;
        await ui.loadFontFromList(r.bodyBytes, fontFamily: 'Roboto');
      } catch (_) {
        // Sin esta gruesa el motor usa la que tenga.
      }
    }
  }

  /// Aplica la version nueva que ya esta bajada y recarga. Falso si no hay
  /// ninguna esperando: la persona lo pidio, pero todavia no se publico.
  static Future<bool> actualizar() async {
    final p = _puente;
    if (p == null) return false;
    try {
      return (await p.actualizar().toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  static Future<EspacioPwa?> espacio() async {
    try {
      final e = await _puente?.espacio().toDart;
      if (e == null) return null;
      return EspacioPwa(usado: e.usado.toInt(), cuota: e.cuota.toInt());
    } catch (_) {
      return null;
    }
  }

  static Future<String?> versionServiceWorker() async {
    try {
      return (await _puente?.versionSw().toDart)?.toDart;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> teselasGuardadas() async {
    try {
      return (await _puente?.contarTeselas().toDart)?.toDartInt;
    } catch (_) {
      return null;
    }
  }

  static final MapCachingProvider _cache = _CacheTeselasWeb();

  /// La cache de las imagenes del mapa base. La de flutter_map
  /// (`BuiltInMapCachingProvider`) no existe en el navegador, y sin una lo que
  /// se miro con senal no se veia despues sin ella.
  static MapCachingProvider? get cacheTeselas =>
      _puente == null ? null : _cache;

  static String get navegador {
    try {
      return _puente?.navegador() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Que la pantalla no se apague sola mientras se mira el mapa. En el iPhone
  /// la ubicacion de una app web se corta con la pantalla bloqueada.
  static Future<void> pantallaEncendida(bool encendida) async {
    try {
      await _puente?.pantallaEncendida(encendida).toDart;
    } catch (_) {
      // Un navegador sin Wake Lock: la pantalla se apaga como siempre.
    }
  }
}

/// Las imagenes del mapa en la Cache API del navegador, en una cache propia
/// (`geomaps-teselas`) que el service worker no borra al actualizar la app.
class _CacheTeselasWeb implements MapCachingProvider {
  @override
  bool get isSupported => _puente != null;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    final p = _puente;
    if (p == null) return null;
    final t = await p.leerTesela(url).toDart;
    if (t == null) return null;
    final modificada = t.modificada;
    return (
      bytes: t.bytes.toDart,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.fromMillisecondsSinceEpoch(
          t.vence.toInt(),
          isUtc: true,
        ),
        lastModified: modificada == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                modificada.toInt(),
                isUtc: true,
              ),
        etag: t.etag,
      ),
    );
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    final p = _puente;
    if (p == null) return;
    await p
        .guardarTesela(
          url,
          bytes?.toJS,
          metadata.staleAt.millisecondsSinceEpoch.toDouble(),
          metadata.lastModified?.millisecondsSinceEpoch.toDouble(),
          metadata.etag,
        )
        .toDart;
  }
}

@JS('geomapsPwa')
external _Puente? get _puente;

extension type _Puente._(JSObject _) implements JSObject {
  external String base();
  external bool instalada();
  external bool esIphone();
  external String navegador();
  external _Estado estado();
  external void alCambiar(JSFunction alCambiar);
  external JSPromise<JSBoolean> actualizar();
  external JSPromise<_Espacio?> espacio();
  external JSPromise<JSString?> versionSw();
  external JSPromise<_Tesela?> leerTesela(String url);
  external JSPromise<JSAny?> guardarTesela(
    String url,
    JSUint8Array? bytes,
    double vence,
    double? modificada,
    String? etag,
  );
  external JSPromise<JSNumber> contarTeselas();
  external JSPromise<JSAny?> pantallaEncendida(bool encendida);
}

extension type _Estado._(JSObject _) implements JSObject {
  external bool get listaSinSenal;
  external bool get guardando;
  external double get hechos;
  external double get total;
  external bool get actualizacion;
  external String? get error;
  external double? get guardadaEl;
}

extension type _Espacio._(JSObject _) implements JSObject {
  external double get usado;
  external double get cuota;
}

extension type _Tesela._(JSObject _) implements JSObject {
  external JSUint8Array get bytes;
  external double get vence;
  external double? get modificada;
  external String? get etag;
}
