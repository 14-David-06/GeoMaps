import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../camiones/panel_viaje.dart' show terminarViaje;
import '../core/geo.dart';
import '../state/grabacion.dart';
import 'calificar_ruta.dart';
import 'capa_ruta.dart' show formatearDistancia;

/// Empieza a grabar por donde se camina o se maneja.
///
/// Pide un nombre que ya viene escrito con la fecha y la hora: arrancar tiene
/// que poder ser un toque, y el nombre se cambia solo si se quiere. Devuelve si
/// la grabacion arranco.
Future<bool> iniciarRecorrido(BuildContext context, WidgetRef ref) async {
  final ahora = DateTime.now();
  String dos(int n) => n.toString().padLeft(2, '0');
  final texto = TextEditingController(
    text:
        'Recorrido ${dos(ahora.day)}/${dos(ahora.month)} '
        '${dos(ahora.hour)}:${dos(ahora.minute)}',
  );

  final nombre = await showDialog<String>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: const Text('Grabar recorrido'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Se graba por donde vayas, tambien con la pantalla apagada, hasta '
            'que lo termines. Queda en el telefono y sube solo cuando haya '
            'senal.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: texto,
            autofocus: true,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            onSubmitted: (v) => Navigator.pop(dialogo, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogo),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogo, texto.text),
          icon: const Icon(Icons.fiber_manual_record, size: 16),
          label: const Text('Empezar'),
        ),
      ],
    ),
  );
  if (nombre == null) return false;

  final limpio = nombre.trim();
  await ref
      .read(grabadorProvider.notifier)
      .iniciar(nombre: limpio.isEmpty ? 'Recorrido' : limpio);
  return ref.read(grabadorProvider).grabando;
}

/// Pregunta y cierra la grabacion en curso. Devuelve si se cerro.
Future<bool> terminarRecorrido(BuildContext context, WidgetRef ref) async {
  final g = ref.read(grabadorProvider);
  // La vuelta de un camion no se corta como un recorrido cualquiera: se
  // finaliza con sus reglas, se llegue aca desde donde se llegue.
  if (g.esVuelta) return terminarViaje(context, ref);
  // Una ruta iniciada desde el mapa se termina calificandola, se cierre desde
  // donde se cierre.
  if (g.propiedades['tipo'] == 'navegacion') {
    return terminarRutaCalificando(context, ref, llego: false);
  }
  final si = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: const Text('Terminar el recorrido'),
      content: Text(
        g.puntos < 2
            ? 'Todavia no hay nada grabado: el GPS no alcanzo a dar dos '
                  'puntos. Si lo terminas ahora no se guarda nada.'
            : 'Llevas ${formatearDistancia(g.metros)}. Se deja de grabar y el '
                  'recorrido sube a la base cuando haya senal.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogo, false),
          child: const Text('Seguir grabando'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogo, true),
          child: const Text('Terminar'),
        ),
      ],
    ),
  );
  if (si != true) return false;

  final habia = g.puntos >= 2;
  await ref.read(grabadorProvider.notifier).terminar();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          habia
              ? 'Recorrido guardado. Esta en "Lo que levante" y sube solo con '
                    'senal.'
              : 'No habia nada grabado: no se guardo ningun recorrido.',
        ),
      ),
    );
  }
  return true;
}

/// La franja de arriba del mapa mientras se graba un recorrido.
///
/// Dice que se esta grabando -quien graba tiene que saber que la app sigue
/// gastando bateria- y es desde donde se termina. Si la app se cerro a mitad
/// del recorrido, ofrece seguirlo o cerrarlo: una grabacion abierta que nadie
/// ve no sube nunca.
class PanelGrabacion extends ConsumerWidget {
  const PanelGrabacion({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(grabadorProvider);
    if (g.codigo == null) return const SizedBox.shrink();
    final colores = Theme.of(context).colorScheme;
    final precision = g.precisionUltimaM;
    final terminar = TextButton(
      onPressed: () => terminarRecorrido(context, ref),
      child: const Text('Terminar'),
    );

    return Material(
      color: colores.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  g.abiertaSinGrabar
                      ? Icons.pause_circle_outline
                      : Icons.fiber_manual_record,
                  color: g.abiertaSinGrabar
                      ? colores.onSurfaceVariant
                      : Colors.red,
                  size: g.abiertaSinGrabar ? 24 : 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        g.nombre ?? 'Recorrido',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        g.abiertaSinGrabar
                            ? 'Sin terminar · ${formatearDistancia(g.metros)}'
                            : 'Grabando · ${formatearDistancia(g.metros)}'
                                  '${precision == null ? '' : ' · GPS +/- ${precision.round()} m'}',
                        style: TextStyle(
                          fontSize: 15,
                          // Con mas error que el tope del grabador, los puntos
                          // no estan entrando: se dice en rojo, no se calla.
                          color:
                              precision != null &&
                                  precision > Grabador.precisionMaximaM
                              ? colores.error
                              : colores.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Grabando hay un solo boton y entra al lado del texto.
                if (!g.abiertaSinGrabar) terminar,
              ],
            ),
            // Sin terminar son dos, y con la letra agrandada no entran al
            // lado: van en su propio renglon, a la derecha.
            if (g.abiertaSinGrabar)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  children: [
                    TextButton(
                      onPressed: () =>
                          ref.read(grabadorProvider.notifier).reanudar(),
                      child: const Text('Seguir'),
                    ),
                    terminar,
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Por donde se vino: la linea de lo que se lleva grabado.
///
/// Sirve para dos cosas que no se pueden pedir de otra forma estando en el
/// lote: ver que la grabacion de verdad esta andando, y poder volver por donde
/// se entro.
class CapaRecorrido extends StatelessWidget {
  const CapaRecorrido({required this.linea, super.key});

  final List<PuntoGeo> linea;

  @override
  Widget build(BuildContext context) {
    if (linea.length < 2) return const SizedBox.shrink();
    return PolylineLayer(
      polylines: [
        Polyline(
          // Una lista nueva en cada dibujo: la del grabador crece en el lugar,
          // y el mapa no redibuja una linea cuya lista es la misma de antes.
          points: [for (final p in linea) LatLng(p.latitud, p.longitud)],
          color: const Color(0xFFE53935),
          strokeWidth: 4,
          borderColor: Colors.white,
          borderStrokeWidth: 1.5,
        ),
      ],
    );
  }
}
