import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/geopdf.dart';
import '../core/importar_geopdf.dart';
import '../data/db/app_database.dart';
import '../data/mapas_repository.dart';
import '../state/providers.dart';

/// Traer un plano de topografia al telefono y dejarlo como capa del mapa.
///
/// Dos caminos, y conviene no mezclarlos en la cabeza del usuario:
///
/// 1. **Importar** un PDF del telefono. Pasa todo aca, sin señal: el plano
///    queda encima del mapa en el momento. Es lo que hace esta pantalla.
/// 2. **Descargar** un mapa que coordinacion ya subio y convirtio con GDAL.
///    Queda nitido a cualquier zoom, pero necesita señal y que alguien lo haya
///    convertido antes. Todavia no existe.
///
/// La pantalla dice cual de los dos esta pasando. Un usuario que cree que
/// importo un plano nitido y en realidad tiene una imagen rasterizada va a
/// acercarse en campo y no entender por que se ve borroso.
class ImportarMapaPage extends ConsumerStatefulWidget {
  const ImportarMapaPage({super.key});

  @override
  ConsumerState<ImportarMapaPage> createState() => _ImportarMapaPageState();
}

class _ImportarMapaPageState extends ConsumerState<ImportarMapaPage> {
  bool _trabajando = false;
  String? _error;

  Future<void> _importar() async {
    // El tipo se declara de las dos formas porque Android no siempre reporta
    // el MIME: un PDF que llego por WhatsApp suele venir sin el, y filtrando
    // solo por MIME queda invisible en el selector.
    const tipo = XTypeGroup(
      label: 'Planos PDF',
      extensions: ['pdf'],
      mimeTypes: ['application/pdf'],
    );

    final elegido = await openFile(acceptedTypeGroups: const [tipo]);
    if (elegido == null || !mounted) return;

    setState(() {
      _trabajando = true;
      _error = null;
    });

    try {
      final carpeta = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/capas',
      );
      if (!carpeta.existsSync()) carpeta.createSync(recursive: true);

      final plano = await ImportadorGeoPdf.importar(
        pdf: File(elegido.path),
        destino: carpeta,
        codigo: const Uuid().v4(),
      );

      await ref
          .read(mapasRepositoryProvider)
          .registrarImportado(
            nombre: _nombreLegible(elegido.name),
            plano: plano,
          );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on GeoPdfInvalido catch (e) {
      // El motivo esta escrito para quien esta en el lote, no para el log.
      if (mounted) setState(() => _error = e.motivo);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'No se pudo importar el plano. ($e)');
      }
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  /// "Acopios Guaicaramo 2026 (1).pdf" -> "Acopios Guaicaramo 2026 (1)".
  String _nombreLegible(String archivo) {
    final sinExtension = archivo.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    return sinExtension.trim().isEmpty ? 'Plano' : sinExtension.trim();
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final capas = ref.watch(capasImportadasProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Capas del mapa')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: colores.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Importar un plano',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'El plano tiene que ser un PDF de topografia con '
                    'coordenadas adentro. Se guarda en el telefono y se '
                    'dibuja encima del mapa, sin señal.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _trabajando ? null : _importar,
                    icon: _trabajando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : const Icon(Icons.add),
                    label: Text(
                      _trabajando ? 'Procesando el plano...' : 'Elegir un PDF',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colores.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: colores.onErrorContainer,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: colores.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          capas.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('No se pudieron leer las capas. $e'),
            data: (lista) => lista.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Todavia no importaste ningun plano.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : Column(
                    children: [
                      for (final capa in lista) _FilaCapa(capa: capa),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Una capa en la lista: encenderla, graduarla o sacarla.
class _FilaCapa extends ConsumerWidget {
  const _FilaCapa({required this.capa});

  final Mapa capa;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(mapasRepositoryProvider);
    final megas = capa.tamanoMb;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        capa.nombre,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        megas == null
                            ? 'Plano importado'
                            : 'Plano importado · ${megas.toStringAsFixed(1)} MB',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: capa.visible,
                  onChanged: (v) => repo.cambiarVisible(capa.codigo, v),
                ),
                IconButton(
                  tooltip: 'Quitar del telefono',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmarBorrado(context, repo),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(Icons.opacity, size: 18),
                Expanded(
                  child: Slider(
                    value: capa.opacidad.clamp(0.1, 1),
                    min: 0.1,
                    // Se gradua para poder ver el satelital **a traves** del
                    // plano: es la unica forma de comparar el lindero dibujado
                    // con lo que hay sembrado.
                    onChanged: (v) => repo.cambiarOpacidad(capa.codigo, v),
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text('${(capa.opacidad * 100).round()}%'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarBorrado(
    BuildContext context,
    MapasRepository repo,
  ) async {
    final seguro = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Quitar "${capa.nombre}"'),
        content: const Text(
          'Se borra del telefono. El PDF original no se toca, asi que se '
          'puede volver a importar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (seguro ?? false) await repo.borrar(capa.codigo);
  }
}
