import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/camara.dart';
import '../data/db/app_database.dart';
import 'captura.dart';
import 'providers.dart';
import 'sesion.dart';
import 'sincronizador.dart';

final camaraProvider = Provider<Camara>((ref) => const CamaraDelTelefono());

/// Las fotos de un punto, en vivo: la tarjeta del punto se actualiza sola
/// cuando se agrega o se borra una.
final fotosDelPuntoProvider = StreamProvider.autoDispose
    .family<List<Archivo>, String>(
      (ref, waypointCodigo) =>
          ref.watch(archivosRepositoryProvider).observarFotos(waypointCodigo),
    );

/// Lo que las pantallas hacen con las fotos de los puntos: tomarlas,
/// rescatarlas y borrarlas con su punto.
class Fotos {
  Fotos(this._ref);

  final Ref _ref;

  /// Para que punto era la foto que se esta tomando. Se anota antes de abrir
  /// la camara porque Android puede cerrar la app mientras la camara esta
  /// abierta; al volver, es lo unico que dice de quien es la foto que quedo
  /// en el aire.
  static const _llavePuntoEnEspera = 'foto_para_el_punto';

  /// Toma una foto y la guarda como foto de [waypointCodigo]. Devuelve la
  /// foto guardada, o nulo si la persona no tomo ninguna.
  ///
  /// Puede lanzar si la camara no abre -sin permiso, sin app de camara-:
  /// quien la llama lo dice en la pantalla.
  Future<Archivo?> tomar(String waypointCodigo) async {
    final usuario = _ref.read(sesionProvider).sesion?.codigoUsuario;
    if (usuario == null || usuario.isEmpty) return null;

    final prefs = await _preferencias();
    await prefs?.setString(_llavePuntoEnEspera, waypointCodigo);
    final File? archivo;
    try {
      archivo = await _ref.read(camaraProvider).tomar();
    } finally {
      await prefs?.remove(_llavePuntoEnEspera);
    }
    if (archivo == null) return null;

    final foto = await _ref
        .read(archivosRepositoryProvider)
        .guardarFoto(
          origen: archivo,
          waypointCodigo: waypointCodigo,
          usuarioCodigo: usuario,
        );
    // Si hay senal, sube ya; si no, cuando vuelva.
    unawaited(_ref.read(sincronizadorProvider.notifier).sincronizar());
    return foto;
  }

  /// Rescata la foto que quedo en el aire si Android cerro la app con la
  /// camara abierta. Callada: si no hay nada que rescatar, o no se puede, no
  /// pasa nada.
  Future<void> rescatarPerdida() async {
    try {
      final usuario = _ref.read(sesionProvider).sesion?.codigoUsuario;
      final prefs = await _preferencias();
      final punto = prefs?.getString(_llavePuntoEnEspera);
      if (usuario == null || punto == null) return;

      final archivo = await _ref.read(camaraProvider).recuperarPerdida();
      await prefs?.remove(_llavePuntoEnEspera);
      if (archivo == null) return;
      await _ref
          .read(archivosRepositoryProvider)
          .guardarFoto(
            origen: archivo,
            waypointCodigo: punto,
            usuarioCodigo: usuario,
          );
    } catch (_) {
      // Una foto que no se pudo rescatar no puede frenar el arranque.
    }
  }

  /// Borra un punto con sus fotos. Va junto porque una foto sin punto no se
  /// puede ver desde ningun lado y no sube nunca.
  Future<void> borrarPunto(String waypointCodigo) async {
    await _ref.read(archivosRepositoryProvider).borrarDelPunto(waypointCodigo);
    await _ref.read(waypointsRepositoryProvider).borrar(waypointCodigo);
  }

  Future<void> borrar(String codigoFoto) =>
      _ref.read(archivosRepositoryProvider).borrarFoto(codigoFoto);

  Future<SharedPreferences?> _preferencias() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }
}

final fotosProvider = Provider<Fotos>(Fotos.new);

/// El rescate de la foto perdida, una vez por arranque. Lo engancha el
/// inicio, que es lo primero que se ve con la sesion abierta.
final fotoPerdidaProvider = FutureProvider<void>(
  (ref) => ref.watch(fotosProvider).rescatarPerdida(),
);
