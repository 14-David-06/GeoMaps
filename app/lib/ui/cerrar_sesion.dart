import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/grabacion.dart';
import '../state/red.dart';
import '../state/sesion.dart';
import '../state/sincronizador.dart';

/// Cerrar sesion sin llevarse por delante la jornada de nadie.
///
/// Salir no borra nada del telefono, pero lo que no subio queda atado a la
/// cuenta que lo hizo: solo sube cuando **esa** cuenta vuelve a entrar en
/// **ese** telefono. En un telefono que pasa de mano en mano eso puede ser
/// nunca, y el trabajo de un dia queda guardado donde nadie lo ve.
///
/// Por eso, antes de salir:
///
/// - si hay un recorrido abierto, se dice: un recorrido sin terminar no sube;
/// - si hay registros sin subir, se ofrece subirlos ahi mismo;
/// - y si no hay nada pendiente, sale sin preguntar.
///
/// Salir igual siempre se puede. Un telefono tiene que poder cambiar de
/// cuenta aunque no haya senal: lo que hace falta es que la persona lo sepa.
Future<void> cerrarSesion(BuildContext context, WidgetRef ref) async {
  final grabacion = ref.read(grabadorProvider);
  var pendientes = 0;
  try {
    pendientes = await ref.read(pendientesProvider.future);
  } catch (_) {
    // Sin poder contar, se sale como siempre: no se le niega la salida a
    // nadie por un conteo.
  }
  if (!context.mounted) return;

  if (grabacion.codigo != null || pendientes > 0) {
    final salir = await showDialog<bool>(
      context: context,
      builder: (_) => _DialogoSalir(
        abierto: grabacion.codigo == null ? null : grabacion,
        pendientes: pendientes,
      ),
    );
    if (salir != true) return;
  }
  if (!context.mounted) return;
  // Se anota antes de salir: despues ya no hay sesion, y la pantalla desde la
  // que se pidio puede no estar.
  final navegador = Navigator.of(context);
  await ref.read(sesionProvider.notifier).salir();
  // El ingreso aparece en lugar del inicio, que es la primera pantalla. Si se
  // salio desde el mapa, el mapa quedaba encima tapandolo, sin sesion.
  if (navegador.mounted) navegador.popUntil((ruta) => ruta.isFirst);
}

class _DialogoSalir extends ConsumerStatefulWidget {
  const _DialogoSalir({required this.abierto, required this.pendientes});

  /// El recorrido que quedo sin terminar, si hay uno.
  final EstadoGrabacion? abierto;

  /// Cuantos registros cerrados faltaban subir al abrir el dialogo.
  final int pendientes;

  @override
  ConsumerState<_DialogoSalir> createState() => _DialogoSalirState();
}

class _DialogoSalirState extends ConsumerState<_DialogoSalir> {
  bool _subiendo = false;
  String? _error;

  Future<void> _subir() async {
    setState(() {
      _subiendo = true;
      _error = null;
    });
    await ref.read(sincronizadorProvider.notifier).sincronizar();
    if (!mounted) return;

    var quedan = widget.pendientes;
    try {
      quedan = await ref.read(pendientesProvider.future);
    } catch (_) {}
    if (!mounted) return;

    if (quedan == 0 && widget.abierto == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _subiendo = false;
      _error = quedan == 0
          ? null
          : ref.read(sincronizadorProvider).error ??
                'No subio todo. Busca senal y volve a intentar.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final hayRed = ref.watch(redProvider).valueOrNull?.hayRed ?? false;
    // En vivo: si se sube desde aca, el numero baja a la vista.
    final pendientes =
        ref.watch(pendientesProvider).valueOrNull ?? widget.pendientes;
    final abierto = widget.abierto;

    final String titulo;
    if (abierto != null) {
      titulo = abierto.esVuelta
          ? 'Tenes una vuelta sin finalizar'
          : 'Hay un recorrido sin terminar';
    } else {
      titulo = pendientes == 1
          ? 'Tenes 1 registro sin subir'
          : 'Tenes $pendientes registros sin subir';
    }

    return AlertDialog(
      title: Text(titulo),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (abierto != null)
              Text(
                abierto.esVuelta
                    ? 'Finalizala antes de salir. Si salis ahora queda '
                          'abierta en este telefono, y no se cierra hasta que '
                          'vuelvas a entrar aca con esta cuenta.'
                    : '"${abierto.nombre ?? 'Recorrido'}" sigue abierto. Un '
                          'recorrido sin terminar no sube: terminalo antes '
                          'de salir.',
              ),
            if (abierto != null && pendientes > 0) const SizedBox(height: 12),
            if (pendientes > 0)
              Text(
                '${abierto == null
                    ? 'No se pierden'
                    : pendientes == 1
                    ? 'Ademas hay 1 registro sin subir. No se pierde'
                    : 'Ademas hay $pendientes registros sin subir. No se pierden'}'
                ': quedan guardados en este telefono. Pero solo suben cuando '
                'vuelvas a entrar aca con esta misma cuenta. Si el telefono '
                'lo usa otra persona, quedan esperando.',
              ),
            if (pendientes > 0 && !hayRed) ...[
              const SizedBox(height: 12),
              Text(
                'Ahora no hay conexion para subirlos.',
                style: TextStyle(
                  color: colores.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (_subiendo) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: colores.error)),
            ],
          ],
        ),
      ),
      // Uno debajo del otro y a todo el ancho: son tres, y con la letra
      // agrandada no entran en una fila.
      actionsOverflowButtonSpacing: 4,
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        if (pendientes > 0)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _subiendo || !hayRed ? null : _subir,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Subir ahora'),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _subiendo ? null : () => Navigator.pop(context, false),
            child: const Text('Quedarme'),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: _subiendo ? null : () => Navigator.pop(context, true),
            child: Text(
              pendientes > 0 ? 'Salir sin subir' : 'Salir igual',
              style: TextStyle(color: colores.error),
            ),
          ),
        ),
      ],
    );
  }
}
