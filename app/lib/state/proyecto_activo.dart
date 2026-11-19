import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db/app_database.dart';
import '../data/mapas_repository.dart';
import 'providers.dart';
import 'sesion.dart';

/// El proyecto en el que se esta trabajando: bajo el se guarda todo lo que se
/// levante de aca en mas -recorridos, areas, puntos y sus fotos-.
///
/// Sin elegir ninguno todo cae en "Sin proyecto", como siempre. Elegir uno es
/// lo que le da orden al trabajo de campo: lo de la finca de hoy no queda
/// mezclado con lo de la de ayer, ni en el telefono ni en la base.
///
/// Se guarda por cuenta, no por telefono: un aparato pasa por varias manos, y
/// quien entra despues no tiene que heredar el proyecto del anterior -que
/// ademas no es suyo y ni siquiera lo ve en su lista-.
class ProyectoActivo extends StateNotifier<String?> {
  ProyectoActivo(this._authUid) : super(null) {
    _leer();
  }

  final String? _authUid;

  String? get _llave => _authUid == null ? null : 'proyecto_activo_$_authUid';

  Future<void> _leer() async {
    final llave = _llave;
    if (llave == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final guardado = prefs.getString(llave);
      if (guardado != null && mounted) state = guardado;
    } catch (_) {
      // Sin preferencias queda sin proyecto, que es donde caia todo antes.
    }
  }

  /// Elige el proyecto en el que se trabaja, o ninguno con null.
  Future<void> elegir(String? codigo) async {
    state = codigo;
    final llave = _llave;
    if (llave == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (codigo == null) {
        await prefs.remove(llave);
      } else {
        await prefs.setString(llave, codigo);
      }
    } catch (_) {}
  }
}

/// El codigo del proyecto elegido, tal como quedo guardado. Para saber si de
/// verdad se puede usar -existe, es de esta cuenta, no se archivo- esta
/// [proyectoActivoProvider].
final proyectoElegidoProvider = StateNotifierProvider<ProyectoActivo, String?>(
  (ref) => ProyectoActivo(
    ref.watch(sesionProvider.select((e) => e.sesion?.authUid)),
  ),
);

/// El proyecto en el que se esta trabajando, o nulo si no hay.
///
/// Es nulo tambien si el elegido se archivo o ya no esta: no se guarda trabajo
/// nuevo en un proyecto que la persona saco de su lista.
final proyectoActivoProvider = StreamProvider<Proyecto?>((ref) {
  final codigo = ref.watch(proyectoElegidoProvider);
  final authUid = ref.watch(sesionProvider.select((e) => e.sesion?.authUid));
  if (codigo == null || authUid == null) return Stream.value(null);
  return ref
      .watch(proyectosRepositoryProvider)
      .observarUno(codigo)
      .map(
        (p) => p != null && p.activo && p.duenoAuthUid == authUid ? p : null,
      );
});

/// El codigo bajo el que se guarda lo que se levante ahora: el del proyecto
/// activo, o el de "sin proyecto".
///
/// Es un futuro y no un valor porque el proyecto activo se lee de la base, y
/// quien va a guardar no puede quedarse con "sin proyecto" solo porque
/// pregunto antes de que la base contestara.
final proyectoParaGuardarProvider = FutureProvider<String>((ref) async {
  final proyecto = await ref.watch(proyectoActivoProvider.future);
  return proyecto?.codigo ?? MapasRepository.proyectoLocal;
});
