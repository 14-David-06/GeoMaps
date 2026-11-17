import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/geopdf.dart';
import '../core/importar_geopdf.dart';
import '../core/motor_planos.dart';
import '../data/db/app_database.dart';
import '../data/mapas_repository.dart';
import '../state/providers.dart';

/// Traer un plano en PDF al telefono y dejarlo como capa del mapa.
///
/// Sirve cualquier PDF **georreferenciado**: el plano de topografia del
/// predio, una plancha cartografica, el mapa vial del municipio. Lo que no
/// sirve es un PDF sin coordenadas adentro, y la pantalla lo dice.
///
/// Dos caminos, y conviene no mezclarlos en la cabeza del usuario:
///
/// 1. **Importar** un PDF del telefono. Pasa todo aca, sin señal: el plano
///    queda encima del mapa en el momento. Es lo que hace esta pantalla.
/// 2. **Descargar** un mapa que coordinacion ya subio y convirtio con GDAL.
///    Queda nitido a cualquier zoom, pero necesita señal y que alguien lo haya
///    convertido antes. Todavia no existe.
///
/// La pantalla se cierra devolviendo las esquinas del plano que hay que
/// mostrar, para que el mapa se encuadre sobre el.
class ImportarMapaPage extends ConsumerStatefulWidget {
  const ImportarMapaPage({this.motor = const MotorPlanos(), super.key});

  /// El lado nativo. Se puede cambiar en las pruebas.
  final MotorPlanos motor;

  @override
  ConsumerState<ImportarMapaPage> createState() => _ImportarMapaPageState();
}

class _ImportarMapaPageState extends ConsumerState<ImportarMapaPage> {
  PasoImportacion? _paso;
  bool _eligiendo = false;
  String? _error;

  bool get _trabajando => _eligiendo || _paso != null;

  Future<void> _importar() async {
    setState(() {
      _eligiendo = true;
      _error = null;
    });

    PdfElegido? elegido;
    try {
      elegido = await widget.motor.elegir();
      if (elegido == null || !mounted) return;

      final carpeta = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/capas',
      );
      if (!carpeta.existsSync()) carpeta.createSync(recursive: true);

      final plano = await ImportadorGeoPdf.importar(
        pdf: File(elegido.ruta),
        destino: carpeta,
        codigo: const Uuid().v4(),
        motor: widget.motor,
        alAvanzar: (paso) {
          if (mounted) setState(() => _paso = paso);
        },
      );

      await ref
          .read(mapasRepositoryProvider)
          .registrarImportado(
            nombre: _nombreLegible(elegido.nombre),
            plano: plano,
          );

      if (!mounted) return;
      final aviso = plano.aviso;
      if (aviso != null) await _avisar(aviso);
      if (!mounted) return;
      Navigator.of(context).pop(plano.esquinas);
    } on GeoPdfInvalido catch (e) {
      // El motivo esta escrito para quien esta en el lote, no para el log.
      if (mounted) setState(() => _error = e.motivo);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'No se pudo importar el plano. ($e)');
      }
    } finally {
      // La copia temporal del PDF ya cumplio: el plano quedo como imagen.
      final ruta = elegido?.ruta;
      if (ruta != null) {
        try {
          File(ruta).deleteSync();
        } on FileSystemException {
          // Android la limpia igual cuando necesita el espacio.
        }
      }
      if (mounted) {
        setState(() {
          _eligiendo = false;
          _paso = null;
        });
      }
    }
  }

  /// El plano entro, pero hay algo que la persona tiene que saber antes de
  /// confiar en el: se dice una vez, y hay que tocar para seguir.
  Future<void> _avisar(String aviso) {
    return showDialog<void>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('El plano quedo cargado'),
        content: Text(aviso, style: const TextStyle(fontSize: 17)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogo).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  /// "Acopios Guaicaramo 2026 (1).pdf" -> "Acopios Guaicaramo 2026 (1)".
  String _nombreLegible(String archivo) {
    final sinExtension = archivo.replaceAll(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    return sinExtension.trim().isEmpty ? 'Plano' : sinExtension.trim();
  }

  String get _rotuloBoton => switch (_paso) {
    PasoImportacion.leyendo => 'Leyendo las coordenadas...',
    PasoImportacion.dibujando => 'Dibujando el plano...',
    null => _eligiendo ? 'Abriendo el archivo...' : 'Elegir un PDF',
  };

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final capas = ref.watch(capasImportadasProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Planos del mapa')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: colores.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Importar un plano',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sirve un PDF de topografia o cartografico -vias, '
                    'planchas, linderos- que traiga las coordenadas adentro. '
                    'Se guarda en el telefono y se dibuja encima del mapa, '
                    'sin señal. La hoja blanca se quita: quedan solo las '
                    'lineas.',
                    style: TextStyle(fontSize: 16, height: 1.35),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      textStyle: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: _trabajando ? null : _importar,
                    icon: _trabajando
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.6),
                          )
                        : const Icon(Icons.upload_file),
                    label: Text(_rotuloBoton),
                  ),
                  if (_paso != null) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'Un plano grande puede tardar un minuto. No cierres '
                      'la aplicacion.',
                      style: TextStyle(fontSize: 15),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colores.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: colores.onErrorContainer,
                            size: 26,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: colores.onErrorContainer,
                                fontSize: 16,
                                height: 1.35,
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
                      style: TextStyle(fontSize: 16),
                    ),
                  )
                : Column(
                    children: [for (final capa in lista) _FilaCapa(capa: capa)],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Una capa en la lista: verla, encenderla, graduarla o sacarla.
class _FilaCapa extends ConsumerWidget {
  const _FilaCapa({required this.capa});

  final Mapa capa;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(mapasRepositoryProvider);
    final megas = capa.tamanoMb;
    final esquinas = capa.esquinas;
    final ruta = capa.rutaLocal;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
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
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        megas == null
                            ? 'Plano importado'
                            : 'Plano importado · ${megas.toStringAsFixed(1)} MB',
                        style: const TextStyle(fontSize: 15),
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
                const Icon(Icons.opacity, size: 20),
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
                  width: 50,
                  child: Text(
                    '${(capa.opacidad * 100).round()}%',
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
              ],
            ),
            // Solo las lineas, o la hoja entera. Aparece cuando el plano trajo
            // un papel que quitar; una ortofoto no lo tiene y no hay que elegir.
            if (ruta != null && MapasRepository.sePuedeQuitarElFondo(ruta))
              SwitchListTile(
                contentPadding: const EdgeInsets.only(right: 4),
                title: const Text(
                  'Quitar el fondo blanco',
                  style: TextStyle(fontSize: 17),
                ),
                subtitle: const Text(
                  'Deja solo las lineas del plano sobre el mapa',
                  style: TextStyle(fontSize: 15),
                ),
                value: ArchivosPlano.esSinFondo(ruta),
                onChanged: (v) => repo.cambiarFondo(capa.codigo, quitar: v),
              ),
            if (esquinas != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                  // Un plano encendido que no se ve casi siempre esta lejos
                  // de lo que se mira: esto lleva el mapa hasta el.
                  onPressed: () async {
                    if (!capa.visible) {
                      await repo.cambiarVisible(capa.codigo, true);
                    }
                    if (!context.mounted) return;
                    Navigator.of(
                      context,
                    ).pop<List<LatLng>>(PlanoImportado.esquinasDeTexto(esquinas));
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Ver en el mapa'),
                ),
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
          style: TextStyle(fontSize: 16),
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
