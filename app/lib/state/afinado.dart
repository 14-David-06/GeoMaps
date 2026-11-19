import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/detalle_plano.dart';
import '../core/importar_geopdf.dart';
import '../core/motor_planos.dart';
import '../data/db/app_database.dart';
import '../ui/capa_pdf.dart';
import 'providers.dart';

/// El motor de PDF del telefono. Es un provider para que las pruebas pongan
/// uno de mentira.
final motorPlanosProvider = Provider<MotorPlanos>((ref) => const MotorPlanos());

/// Quien les dibuja el detalle a los planos grandes, de fondo.
///
/// Importar un plano lo deja en el mapa en segundos, con su imagen entera. El
/// detalle -la hoja mas grande, en cuadros- son decenas de dibujados y puede
/// llevar un par de minutos: no se le puede pedir a nadie que se quede mirando
/// un boton girar en medio del lote. Asi que el plano se entrega ya, y esto
/// sigue trabajando mientras la persona vuelve al mapa. Los cuadros aparecen a
/// medida que se terminan.
///
/// Lo que guarda es el avance de los planos que se estan afinando, por la
/// ruta de su imagen. De ahi lo leen el mapa -para poner los cuadros nuevos-
/// y la lista de planos -para decir cuanto falta-.
///
/// Trabaja de a un plano por vez: el motor de PDF dibuja de a una cosa, y dos
/// trabajos a la vez solo se estorbarian.
class Afinador extends StateNotifier<Map<String, DetallePlano>> {
  Afinador(this._motor, {this.alTerminar}) : super(const {});

  final MotorPlanos _motor;

  /// Se llama cuando un plano termina su detalle -entero o hasta donde se
  /// pudo-, con la ruta de su imagen. Es para volver a contar cuanto ocupa.
  final Future<void> Function(String rutaVista)? alTerminar;

  final _cola = <String>[];
  final _motores = <String, MotorPlanos>{};
  final _olvidados = <String>{};
  bool _corriendo = false;

  /// Los planos se nombran por la ruta de su imagen con papel: es la que no
  /// cambia cuando alguien alterna entre ver la hoja o solo las lineas.
  static String clave(String rutaVista) => ArchivosPlano.conFondo(rutaVista);

  /// Empieza a dibujarle el detalle a un plano recien importado.
  ///
  /// Se queda con el [pdf]: lo muda a la carpeta del detalle, porque la
  /// carpeta temporal donde lo dejo el selector se vacia con la importacion
  /// siguiente, y el trabajo puede seguir todavia. Lo borra al terminar.
  Future<void> empezar({
    required String rutaVista,
    required DetallePlano detalle,
    required File pdf,
    MotorPlanos? motor,
  }) async {
    final k = clave(rutaVista);
    final original = File(DetallePlano.originalDe(k));
    await original.parent.create(recursive: true);
    try {
      await pdf.rename(original.path);
    } on FileSystemException {
      // No estan en el mismo disco: se copia y se suelta la temporal.
      await pdf.copy(original.path);
      try {
        await pdf.delete();
      } on FileSystemException {
        // Android la limpia igual cuando necesita el espacio.
      }
    }
    await detalle.guardar(k);
    if (!mounted) return;

    if (motor != null) _motores[k] = motor;
    _olvidados.remove(k);
    state = {...state, k: detalle};
    _encolar(k);
  }

  /// Sigue con los planos que quedaron a medias: la app se cerro mientras se
  /// afinaban. [rutas] son las imagenes de los planos que hay en el telefono.
  void retomar(Iterable<String> rutas) {
    for (final ruta in rutas) {
      final k = clave(ruta);
      if (state.containsKey(k) || _olvidados.contains(k)) continue;
      final detalle = DetallePlano.leer(k);
      if (detalle == null || detalle.terminado) continue;
      if (!File(DetallePlano.originalDe(k)).existsSync()) {
        // Sin el PDF no hay con que seguir: queda con lo que tiene.
        unawaited(_cerrar(k, detalle));
        continue;
      }
      state = {...state, k: detalle};
      _encolar(k);
    }
  }

  /// El plano se borro: lo que se le estuviera dibujando se corta.
  void olvidar(String rutaVista) {
    final k = clave(rutaVista);
    _olvidados.add(k);
    _cola.remove(k);
    _motores.remove(k);
    if (state.containsKey(k)) state = {...state}..remove(k);
  }

  void _encolar(String k) {
    if (!_cola.contains(k)) _cola.add(k);
    unawaited(_trabajar());
  }

  Future<void> _trabajar() async {
    if (_corriendo) return;
    _corriendo = true;
    try {
      while (_cola.isNotEmpty && mounted) {
        final k = _cola.removeAt(0);
        final detalle = state[k];
        if (detalle == null) continue;
        await _afinar(k, detalle);
      }
    } finally {
      _corriendo = false;
    }
  }

  bool _sigue(String k) => mounted && !_olvidados.contains(k);

  Future<void> _afinar(String k, DetallePlano detalle) async {
    DetallePlano quedo;
    try {
      quedo = await ImportadorGeoPdf.afinar(
        rutaVista: k,
        detalle: detalle,
        pdf: File(DetallePlano.originalDe(k)),
        motor: _motores[k] ?? _motor,
        seguir: () => _sigue(k),
        alAvanzar: (d) {
          if (_sigue(k)) state = {...state, k: d};
        },
      );
    } catch (_) {
      // Un cuadro que no se pudo dibujar ahora tampoco se va a poder despues:
      // el plano se queda con los que tiene, que ya estan guardados.
      if (!_sigue(k)) return;
      await _cerrar(k, DetallePlano.leer(k) ?? detalle);
      return;
    }
    // Cortado a medias -la app se cierra- se deja como esta, con su PDF, para
    // seguir la proxima vez.
    if (!quedo.terminado) return;
    await _soltar(k);
  }

  /// Deja el detalle como terminado con lo que tenga hecho.
  Future<void> _cerrar(String k, DetallePlano detalle) async {
    final cerrado = detalle.conTrabajo(null);
    try {
      await cerrado.guardar(k);
    } catch (_) {
      // Si el indice no se puede escribir, el mapa usa la imagen de siempre.
    }
    if (mounted && state.containsKey(k)) state = {...state, k: cerrado};
    await _soltar(k);
  }

  /// El trabajo termino: se borra el PDF y se avisa.
  Future<void> _soltar(String k) async {
    _motores.remove(k);
    try {
      await File(DetallePlano.originalDe(k)).delete();
    } on FileSystemException {
      // Ya no estaba.
    }
    try {
      await alTerminar?.call(k);
    } catch (_) {
      // Lo que ocupa el plano es un dato de la lista: que no se pueda
      // actualizar no deshace el detalle.
    }
  }
}

final afinadorProvider =
    StateNotifierProvider<Afinador, Map<String, DetallePlano>>((ref) {
      final repo = ref.watch(mapasRepositoryProvider);
      final afinador = Afinador(
        ref.watch(motorPlanosProvider),
        alTerminar: repo.recontarPeso,
      );
      // Con la lista de planos a la vista se retoma lo que haya quedado a
      // medias de la vez anterior.
      ref.listen(capasImportadasProvider, (_, capas) {
        afinador.retomar([
          for (final c in capas.valueOrNull ?? const <Mapa>[])
            if (c.rutaLocal != null) c.rutaLocal!,
        ]);
      }, fireImmediately: true);
      return afinador;
    });

/// Los planos encendidos, cada uno con su detalle si lo tiene. Es lo que
/// dibuja el mapa.
///
/// El detalle sale del [Afinador] si el plano se esta afinando ahora -para
/// que los cuadros aparezcan a medida que se terminan- y si no, del indice
/// que quedo en el telefono.
final planosEnMapaProvider = Provider<List<PlanoEnMapa>>((ref) {
  final planos =
      ref.watch(capasVisiblesProvider).valueOrNull ?? const <PlanoEnMapa>[];
  if (planos.isEmpty) return planos;
  final enCurso = ref.watch(afinadorProvider);
  return [
    for (final p in planos)
      p.conDetalle(
        enCurso[Afinador.clave(p.ruta)] ?? DetallePlano.leer(p.ruta),
      ),
  ];
});
