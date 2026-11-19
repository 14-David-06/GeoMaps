import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/exportador.dart';
import '../core/geojson.dart';
import '../data/db/app_database.dart';
import '../data/db/enums.dart';
import '../state/captura.dart';
import '../state/fotos.dart';
import '../state/providers.dart';
import '../state/sesion.dart';
import '../state/sincronizador.dart';
import 'calificar_ruta.dart';
import 'capa_ruta.dart' show formatearDistancia;
import 'exportar_page.dart';
import 'waypoint_page.dart';

/// Lo que se levanto en campo: recorridos grabados, areas medidas y puntos.
///
/// Es una hoja sobre el mapa y no una pantalla aparte por lo mismo que las
/// capas: se elige algo y se lo ve dibujado atras, sin perder el lugar. Desde
/// aca tambien se comparte como KML o GPX, sin red.

/// Lo que se eligio de la lista para verlo en el mapa.
class Levantado {
  const Levantado.trazado(Trazado this.trazado) : punto = null;
  const Levantado.punto(Waypoint this.punto) : trazado = null;

  final Trazado? trazado;
  final Waypoint? punto;
}

/// Abre la lista. Devuelve lo que se toco, para mostrarlo en el mapa.
Future<Levantado?> elegirLevantado(BuildContext context) {
  return showModalBottomSheet<Levantado>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (hoja) => SizedBox(
      height: MediaQuery.sizeOf(hoja).height * 0.72,
      child: const _Lista(),
    ),
  );
}

class _Lista extends ConsumerWidget {
  const _Lista();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trazados = ref.watch(levantadosProvider).valueOrNull ?? const [];
    final puntos = ref.watch(puntosProvider).valueOrNull ?? const [];

    return DefaultTabController(
      length: 2,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Lo que levante',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (puntos.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _compartirPuntos(context, puntos),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('Puntos'),
                    ),
                ],
              ),
            ),
            TabBar(
              tabs: [
                Tab(text: 'Recorridos y areas (${trazados.length})'),
                Tab(text: 'Puntos (${puntos.length})'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  trazados.isEmpty
                      ? const _Vacio(
                          icono: Icons.timeline,
                          titulo: 'Todavia no hay recorridos',
                          detalle:
                              'Graba por donde caminas con el boton rojo del '
                              'mapa, o mide un lote con la regla y guardalo.',
                        )
                      : ListView.builder(
                          itemCount: trazados.length,
                          itemBuilder: (_, i) =>
                              _FilaTrazado(trazado: trazados[i]),
                        ),
                  puntos.isEmpty
                      ? const _Vacio(
                          icono: Icons.add_location_alt_outlined,
                          titulo: 'Todavia no hay puntos',
                          detalle:
                              'Marca donde estas parado con el boton del '
                              'alfiler en el mapa.',
                        )
                      : ListView.builder(
                          itemCount: puntos.length,
                          itemBuilder: (_, i) => _FilaPunto(punto: puntos[i]),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _compartirPuntos(
    BuildContext context,
    List<Waypoint> puntos,
  ) async {
    final formato = await elegirFormato(
      context,
      titulo: 'Compartir los ${puntos.length} puntos como',
    );
    if (formato == null || !context.mounted) return;
    await _intentar(context, () => Exportador.compartirPuntos(puntos, formato));
  }
}

/// Compartir puede fallar -sin espacio, sin ninguna app que reciba el
/// archivo- y eso no puede pasar callado.
/// Pregunta en que formato y comparte un recorrido o un area, con los
/// puntos que se marcaron mientras se lo levantaba.
///
/// Al informe PDF le pasa ademas el nombre del proyecto y de quien lo
/// levanto, que son lo primero que busca quien recibe el papel.
Future<void> compartirTrazado(
  BuildContext context,
  WidgetRef ref,
  Trazado trazado,
) async {
  final formato = await elegirFormato(context, conInforme: true);
  if (formato == null || !context.mounted) return;
  await _intentar(context, () async {
    final marcas = await ref
        .read(waypointsRepositoryProvider)
        .delTrazado(trazado.codigo);
    final proyecto = await ref
        .read(proyectosRepositoryProvider)
        .observarUno(trazado.proyectoCodigo)
        .first;
    await Exportador.compartir(
      trazado,
      formato,
      marcas: marcas,
      proyecto: proyecto?.nombre,
      autor: ref.read(sesionProvider).sesion?.nombre,
    );
  });
}

Future<void> _intentar(
  BuildContext context,
  Future<void> Function() accion,
) async {
  final avisos = ScaffoldMessenger.of(context);
  try {
    await accion();
  } catch (_) {
    avisos.showSnackBar(
      const SnackBar(
        content: Text('No se pudo armar el archivo para compartir.'),
      ),
    );
  }
}

class _Vacio extends StatelessWidget {
  const _Vacio({
    required this.icono,
    required this.titulo,
    required this.detalle,
  });

  final IconData icono;
  final String titulo;
  final String detalle;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 44, color: colores.outline),
            const SizedBox(height: 14),
            Text(titulo, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              detalle,
              textAlign: TextAlign.center,
              style: TextStyle(color: colores.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilaTrazado extends ConsumerWidget {
  const _FilaTrazado({required this.trazado});

  final Trazado trazado;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colores = Theme.of(context).colorScheme;
    final t = trazado;
    final esArea = t.tipo == TipoTrazado.poligono.name;
    final estrellas = CalificacionRuta.estrellasDe(t.geometria);

    return ListTile(
      leading: Icon(
        esArea ? Icons.crop_square : Icons.timeline,
        color: esArea ? const Color(0xFFFF6F00) : const Color(0xFFE53935),
      ),
      title: Text(t.nombre, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Icon(
            t.sincronizado
                ? Icons.cloud_done_outlined
                : Icons.cloud_upload_outlined,
            size: 15,
            color: t.sincronizado ? colores.primary : colores.outline,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              [
                if (estrellas != null) '★ $estrellas',
                if (t.areaHa != null) resumenArea(t.areaHa!),
                if (!esArea && t.distanciaM != null)
                  formatearDistancia(t.distanciaM!),
                fechaCorta(t.creadoEn),
                if (!t.sincronizado) 'sin subir',
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Mas',
        onSelected: (que) => switch (que) {
          'compartir' => _compartir(context, ref),
          'renombrar' => _renombrar(context, ref),
          _ => _borrar(context, ref),
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'compartir',
            child: ListTile(
              leading: Icon(Icons.ios_share),
              title: Text('Compartir'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'renombrar',
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('Cambiar nombre'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'borrar',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Borrar'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
      onTap: () => Navigator.pop(context, Levantado.trazado(t)),
    );
  }

  Future<void> _compartir(BuildContext context, WidgetRef ref) =>
      compartirTrazado(context, ref, trazado);

  Future<void> _renombrar(BuildContext context, WidgetRef ref) async {
    final texto = TextEditingController(text: trazado.nombre);
    final nombre = await showDialog<String>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('Cambiar nombre'),
        content: TextField(
          controller: texto,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Nombre'),
          onSubmitted: (v) => Navigator.pop(dialogo, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogo),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogo, texto.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (nombre == null || nombre.trim().isEmpty) return;
    await ref
        .read(trazadosRepositoryProvider)
        .renombrar(trazado.codigo, nombre);
    ref.read(sincronizadorProvider.notifier).sincronizar();
  }

  Future<void> _borrar(BuildContext context, WidgetRef ref) async {
    final si = await showDialog<bool>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('Borrar'),
        content: Text(
          trazado.sincronizado
              ? 'Se borra "${trazado.nombre}" de este telefono. La copia que '
                    'ya subio a la base se queda.'
              : 'Se borra "${trazado.nombre}". Todavia no subio, asi que no '
                    'queda copia en ningun lado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogo, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogo, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (si != true) return;
    await ref.read(trazadosRepositoryProvider).borrar(trazado.codigo);
  }
}

class _FilaPunto extends ConsumerWidget {
  const _FilaPunto({required this.punto});

  final Waypoint punto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = punto;
    final simbolo = simboloDe(w);
    return ListTile(
      leading: Icon(simbolo.icono, color: simbolo.color),
      title: Text(w.nombre, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          simbolo.titulo,
          fechaCorta(w.marcadoEn),
          w.precisionM == null ? 'a mano' : '+/- ${w.precisionM!.round()} m',
          if (w.nota != null) w.nota!,
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Borrar',
        onPressed: () => ref.read(fotosProvider).borrarPunto(w.codigo),
      ),
      onTap: () => Navigator.pop(context, Levantado.punto(w)),
    );
  }
}

String fechaCorta(DateTime f) {
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(f.day)}/${dos(f.month)}/${f.year} ${dos(f.hour)}:${dos(f.minute)}';
}

/// El area como se la dice: metros cuadrados si es chica, hectareas si no.
String resumenArea(double hectareas) {
  final m2 = hectareas * 10000;
  if (m2 < 10000) return '${m2.round()} m2';
  return '${hectareas.toStringAsFixed(2).replaceAll('.', ',')} ha';
}

/// Los vertices de un trazado guardado, para dibujarlo.
List<LatLng> verticesDe(Trazado t) => [
  for (final p in GeoJson.puntosDeLinea(
    jsonDecode(t.geometria) as Map<String, dynamic>,
  ))
    LatLng(p.latitud, p.longitud),
];

/// Un trazado guardado, dibujado para mirarlo: el recorrido de ayer, o el
/// lote que se midio.
class CapaTrazadoVisto extends StatelessWidget {
  const CapaTrazadoVisto({
    required this.vertices,
    required this.esArea,
    super.key,
  });

  final List<LatLng> vertices;
  final bool esArea;

  static const _color = Color(0xFF8E24AA);

  @override
  Widget build(BuildContext context) {
    if (vertices.length < 2) return const SizedBox.shrink();
    return Stack(
      children: [
        if (esArea)
          PolygonLayer(
            polygons: [
              Polygon(
                points: vertices,
                color: _color.withValues(alpha: 0.22),
                borderStrokeWidth: 0,
              ),
            ],
          ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: vertices,
              color: _color,
              strokeWidth: 4,
              borderColor: Colors.white,
              borderStrokeWidth: 1.5,
            ),
          ],
        ),
      ],
    );
  }
}

/// La tarjeta del trazado que se esta mirando.
class FichaTrazado extends ConsumerWidget {
  const FichaTrazado({
    required this.trazado,
    required this.onCerrar,
    super.key,
  });

  final Trazado trazado;
  final VoidCallback onCerrar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colores = Theme.of(context).colorScheme;
    final t = trazado;
    final esArea = t.tipo == TipoTrazado.poligono.name;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        child: Row(
          children: [
            Icon(
              esArea ? Icons.crop_square : Icons.timeline,
              color: CapaTrazadoVisto._color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    [
                      if (CalificacionRuta.estrellasDe(t.geometria)
                          case final estrellas?)
                        '★ $estrellas',
                      if (t.areaHa != null) resumenArea(t.areaHa!),
                      if (t.distanciaM != null)
                        '${esArea ? 'perimetro ' : ''}'
                            '${formatearDistancia(t.distanciaM!)}',
                      if (t.precisionMediaM != null)
                        'GPS +/- ${t.precisionMediaM!.round()} m',
                      if (t.metodo == MetodoCaptura.manual.name) 'a mano',
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 15,
                      color: colores.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Compartir',
              icon: const Icon(Icons.ios_share),
              onPressed: () => compartirTrazado(context, ref, t),
            ),
            IconButton(
              tooltip: 'Cerrar',
              icon: const Icon(Icons.close),
              onPressed: onCerrar,
            ),
          ],
        ),
      ),
    );
  }
}
