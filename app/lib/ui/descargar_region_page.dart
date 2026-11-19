import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/teselas.dart';
import '../state/descarga.dart';
import '../state/gps.dart';
import '../state/red.dart';
import '../state/zona_guaicaramo.dart';
import 'mapa/capa_base.dart';
import 'proveedor_teselas.dart';
import 'theme.dart';

/// Bajar una zona del satelite para usarla sin senal.
///
/// Se encuadra la zona moviendo el mapa -lo que se ve es lo que se baja- y se
/// elige hasta que detalle. No hay recuadro que dibujar: en un telefono, con
/// guantes, arrastrar esquinas es lo primero que sale mal.
///
/// La pantalla dice cuanto pesa **antes** de empezar. La cuenta crece por
/// cuatro con cada nivel de detalle, y una zona que en un nivel pesa 20 MB dos
/// niveles despues pesa 320. Sin el numero a la vista, alguien llena el
/// telefono.
///
/// Solo se baja el satelite. El mapa de calles sale del servidor publico de
/// OpenStreetMap, que prohibe bajar zonas enteras; ese se guarda solo, de a
/// poco, con lo que se va mirando.
class DescargarRegionPage extends ConsumerStatefulWidget {
  const DescargarRegionPage({super.key});

  @override
  ConsumerState<DescargarRegionPage> createState() =>
      _DescargarRegionPageState();
}

class _DescargarRegionPageState extends ConsumerState<DescargarRegionPage> {
  final _mapa = MapController();

  /// Desde donde se baja. Fijo: los niveles de arriba son un punado de
  /// imagenes y son las que dejan ver la zona entera al alejarse.
  static const _zMin = 12;

  int _zMax = 17;
  ZonaTeselas? _zona;

  static const _detalles = {
    14: 'Vista general',
    15: 'Bloques',
    16: 'Lotes',
    17: 'Vias y linderos',
    18: 'Caminos y arboles',
    19: 'Maximo detalle',
  };

  void _alMover(MapCamera camara) {
    final v = camara.visibleBounds;
    final zona = ZonaTeselas(
      sur: v.south,
      oeste: v.west,
      norte: v.north,
      este: v.east,
    );
    // Solo se redibuja si cambia la cuenta: mover el mapa unos pixeles no
    // cambia lo que hay que bajar.
    if (_zona?.contar(_zMin, _zMax) == zona.contar(_zMin, _zMax)) {
      _zona = zona;
      return;
    }
    setState(() => _zona = zona);
  }

  void _encuadrarPredio() {
    final caja = ref.read(zonaGuaicaramoProvider).valueOrNull?.bbox;
    if (caja == null) return;
    _mapa.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
          LatLng(caja.latMin, caja.lonMin),
          LatLng(caja.latMax, caja.lonMax),
        ),
        padding: const EdgeInsets.all(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final descarga = ref.watch(descargadorProvider);
    final hayRed = ref.watch(redProvider).valueOrNull?.hayRed ?? true;
    final predio = ref.watch(zonaGuaicaramoProvider).valueOrNull;

    final zona = _zona;
    final cuantas = zona?.contar(_zMin, _zMax) ?? 0;
    final megas = megasEstimadas(cuantas);
    final demasiado = cuantas > Descargador.maximoTeselas;

    final ultima = Gps.instancia.ultima;
    final centro = ultima != null
        ? LatLng(ultima.latitude, ultima.longitude)
        : predio != null
        ? LatLng(
            (predio.bbox.latMin + predio.bbox.latMax) / 2,
            (predio.bbox.lonMin + predio.bbox.lonMax) / 2,
          )
        : const LatLng(4.28, -72.89);

    return Scaffold(
      appBar: AppBar(title: const Text('Mapas sin senal')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapa,
                  options: MapOptions(
                    initialCenter: centro,
                    initialZoom: 14,
                    // Sin girar: lo que se baja es un rectangulo norte-sur, y
                    // un mapa girado muestra otra cosa que la que se baja.
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onMapReady: () => _alMover(_mapa.camera),
                    onPositionChanged: (camara, _) => _alMover(camara),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: CapaBase.satelite.url,
                      userAgentPackageName: CapaBase.satelite.paquete,
                      maxNativeZoom: CapaBase.satelite.zoomMax,
                      tileProvider: proveedorDe(
                        plantilla: CapaBase.satelite.url,
                        paquete: CapaBase.satelite.paquete,
                      ),
                      tileDisplay: apareceTesela,
                    ),
                  ],
                ),
                // El marco: lo que queda adentro es lo que se baja.
                IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: Material(
                    color: colores.surface,
                    elevation: 3,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Mueve y acerca el mapa: lo que se ve aca es lo '
                              'que se baja.',
                              style: TextStyle(fontSize: 15),
                            ),
                          ),
                          if (predio != null)
                            TextButton(
                              onPressed: _encuadrarPredio,
                              child: Text('Todo ${predio.nombre}'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Detalle',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _detalles[_zMax] ?? '',
                          style: TextStyle(color: colores.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _zMax.toDouble(),
                    min: 14,
                    max: 19,
                    divisions: 5,
                    label: _detalles[_zMax],
                    onChanged: descarga.corriendo
                        ? null
                        : (v) => setState(() => _zMax = v.round()),
                  ),
                  Text(
                    zona == null
                        ? 'Calculando...'
                        : '$cuantas imagenes · unos '
                              '${megas < 10 ? megas.toStringAsFixed(1).replaceAll('.', ',') : megas.round()} MB',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: demasiado ? colores.error : colores.onSurface,
                    ),
                  ),
                  if (demasiado)
                    Text(
                      'Es demasiado para bajar de una vez (el tope son '
                      '${Descargador.maximoTeselas} imagenes). Acerca el mapa '
                      'o baja el detalle.',
                      style: TextStyle(color: colores.error, fontSize: 15),
                    )
                  else if (!hayRed)
                    Text(
                      'Sin conexion: bajar la zona necesita senal o wifi.',
                      style: TextStyle(color: colores.error, fontSize: 15),
                    ),
                  const SizedBox(height: 10),
                  if (descarga.corriendo) ...[
                    LinearProgressIndicator(value: descarga.progreso),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${descarga.hechas} de ${descarga.total}'
                            '${descarga.fallidas == 0 ? '' : ' · ${descarga.fallidas} fallaron'}'
                            '${descarga.sinImagen == 0 ? '' : ' · ${descarga.sinImagen} sin imagen'}',
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              ref.read(descargadorProvider.notifier).cancelar(),
                          child: const Text('Cancelar'),
                        ),
                      ],
                    ),
                  ] else ...[
                    if (descarga.aviso != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              descarga.completa
                                  ? Icons.check_circle
                                  : Icons.info_outline,
                              size: 18,
                              color: descarga.completa
                                  ? ColoresEstado.bien
                                  : colores.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${descarga.aviso}'
                                '${descarga.bajadas == 0 ? '' : ' (${(descarga.bytes / 1048576).toStringAsFixed(1).replaceAll('.', ',')} MB nuevos)'}',
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                          ],
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: zona == null || demasiado || cuantas == 0
                          ? null
                          : () => ref
                                .read(descargadorProvider.notifier)
                                .bajar(
                                  zona: zona,
                                  zMin: _zMin,
                                  zMax: _zMax,
                                  plantilla: CapaBase.satelite.url,
                                  paquete: CapaBase.satelite.paquete,
                                ),
                      icon: const Icon(Icons.download),
                      label: const Text('Bajar esta zona'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
