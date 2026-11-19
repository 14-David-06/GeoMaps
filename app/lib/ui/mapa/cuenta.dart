import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/sesion.dart';
import '../cerrar_sesion.dart';

/// Quien esta conectado y cuanto le queda de sesion, sin salir del mapa.
///
/// Los dias restantes se muestran porque son el dato que decide si alguien
/// puede salir tranquilo a una semana de campo. Enterarse de que la sesion
/// vencio estando en el lote es justo lo que hay que evitar.
void mostrarCuentaDelMapa(BuildContext context, WidgetRef ref) {
  final sesion = ref.read(sesionProvider).sesion;
  if (sesion == null) return;

  showModalBottomSheet<void>(
    context: context,
    // Con la letra agrandada y un nombre largo no entra en media pantalla,
    // que es lo que da una hoja comun: que crezca, y que se pueda bajar.
    isScrollControlled: true,
    builder: (hoja) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              // La foto va encima del icono: sin senal no baja, y queda
              // el icono en vez de un circulo vacio.
              leading: CircleAvatar(
                foregroundImage: sesion.foto == null
                    ? null
                    : NetworkImage(sesion.foto!),
                onForegroundImageError: sesion.foto == null ? null : (_, _) {},
                child: const Icon(Icons.person),
              ),
              title: Text(sesion.nombre),
              subtitle: Text(sesion.correo),
            ),
            const Divider(height: 1),
            if (sesion.vencida)
              const ListTile(
                leading: Icon(Icons.lock_clock),
                title: Text('La sesion vencio'),
                subtitle: Text(
                  'Podes seguir trabajando en este telefono. Para subir lo '
                  'que hagas, entra de nuevo desde el inicio, con senal.',
                ),
              )
            else
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text('Sesion valida ${sesion.diasRestantes} dias mas'),
                subtitle: const Text(
                  'Podes trabajar sin senal durante ese plazo.',
                ),
              ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesion'),
              onTap: () {
                Navigator.pop(hoja);
                cerrarSesion(context, ref);
              },
            ),
          ],
        ),
      ),
    ),
  );
}
