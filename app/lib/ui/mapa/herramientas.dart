import 'package:flutter/material.dart';

import '../../data/db/app_database.dart';
import '../../state/grabacion.dart';

/// Lo que se puede pedir desde el boton de herramientas del mapa.
enum HerramientaMapa {
  /// Cambiar el proyecto en el que queda lo que se levante.
  proyecto,
  grabarRecorrido,
  terminarRecorrido,
  marcarAqui,
  medir,
  levantados,
  rutasGuardadas,
  cuenta,
}

/// El menu de herramientas del mapa. Un solo boton para todas: con uno por
/// herramienta la columna de botones tapaba medio costado del mapa.
///
/// Devuelve lo que se eligio, o nulo si se cerro la hoja. No hace nada mas:
/// quien sabe grabar, medir o marcar es la pantalla del mapa.
///
/// [grabacion] decide si se ofrece grabar o terminar, [proyecto] es el que
/// esta en uso -nulo si no hay ninguno- y [conRutasGuardadas] es si el mapa
/// abrio un predio con vias: sin ellas no hay rutas que guardar.
Future<HerramientaMapa?> elegirHerramienta(
  BuildContext context, {
  required EstadoGrabacion grabacion,
  required Proyecto? proyecto,
  required bool conRutasGuardadas,
}) {
  final g = grabacion;
  return showModalBottomSheet<HerramientaMapa>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (hoja) {
      void elegir(HerramientaMapa h) => Navigator.pop(hoja, h);

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Donde va a quedar lo que se levante. Va primero porque es
              // lo que hay que mirar antes de grabar o marcar nada.
              ListTile(
                leading: Icon(
                  proyecto == null ? Icons.folder_off_outlined : Icons.folder,
                  color: Theme.of(hoja).colorScheme.primary,
                ),
                title: Text(
                  proyecto == null
                      ? 'Sin proyecto'
                      : 'Proyecto: ${proyecto.nombre}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'Lo que levantes se guarda aca. Toca para cambiarlo',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => elegir(HerramientaMapa.proyecto),
              ),
              const Divider(height: 1),
              // Con la vuelta de un camion en curso la grabacion es de la
              // vuelta: se finaliza desde su franja, no desde aca.
              if (g.codigo == null)
                ListTile(
                  leading: const Icon(
                    Icons.fiber_manual_record,
                    color: Colors.red,
                  ),
                  title: const Text('Grabar recorrido'),
                  subtitle: const Text(
                    'Por donde camines o manejes, tambien con la pantalla '
                    'apagada',
                  ),
                  onTap: () => elegir(HerramientaMapa.grabarRecorrido),
                )
              else if (!g.esVuelta)
                ListTile(
                  leading: const Icon(Icons.stop_circle_outlined),
                  title: const Text('Terminar el recorrido'),
                  subtitle: Text(g.nombre ?? ''),
                  onTap: () => elegir(HerramientaMapa.terminarRecorrido),
                ),
              ListTile(
                leading: const Icon(Icons.add_location_alt_outlined),
                title: const Text('Marcar un punto aqui'),
                subtitle: const Text(
                  'Donde estas parado, con la precision del GPS',
                ),
                onTap: () => elegir(HerramientaMapa.marcarAqui),
              ),
              ListTile(
                leading: const Icon(Icons.straighten),
                title: const Text('Medir distancia o area'),
                subtitle: const Text('Tocando puntos sobre el mapa'),
                onTap: () => elegir(HerramientaMapa.medir),
              ),
              ListTile(
                leading: const Icon(Icons.folder_special_outlined),
                title: const Text('Lo que levante'),
                subtitle: const Text(
                  'Recorridos, areas y puntos. Para verlos y compartirlos',
                ),
                onTap: () => elegir(HerramientaMapa.levantados),
              ),
              if (conRutasGuardadas)
                ListTile(
                  leading: const Icon(Icons.bookmarks_outlined),
                  title: const Text('Rutas guardadas'),
                  onTap: () => elegir(HerramientaMapa.rutasGuardadas),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Mi cuenta'),
                onTap: () => elegir(HerramientaMapa.cuenta),
              ),
            ],
          ),
        ),
      );
    },
  );
}
