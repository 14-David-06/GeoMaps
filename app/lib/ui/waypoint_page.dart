import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../data/db/app_database.dart';
import '../data/db/enums.dart';
import '../state/captura.dart';
import '../state/proyecto_activo.dart';
import '../state/sesion.dart';
import 'capa_ruta.dart' show formatearDistancia;
import 'fotos_punto.dart';

/// Marcar un punto: nombre, simbolo y nota.
///
/// Las coordenadas se muestran con su precision al lado. Un waypoint tomado
/// con 25 m de error no se puede usar para volver al mismo arbol, y quien lo
/// marca tiene que verlo en el momento, no descubrirlo despues en la oficina.

/// Como se ve y como se llama cada simbolo. Son pocos a proposito.
extension SimboloVisible on SimboloWaypoint {
  String get titulo => switch (this) {
    SimboloWaypoint.generico => 'Punto',
    SimboloWaypoint.muestra => 'Muestra',
    SimboloWaypoint.arbol => 'Arbol',
    SimboloWaypoint.fuenteDeAgua => 'Agua',
    SimboloWaypoint.infraestructura => 'Obra',
    SimboloWaypoint.riesgo => 'Riesgo',
  };

  IconData get icono => switch (this) {
    SimboloWaypoint.generico => Icons.place,
    SimboloWaypoint.muestra => Icons.science,
    SimboloWaypoint.arbol => Icons.park,
    SimboloWaypoint.fuenteDeAgua => Icons.water_drop,
    SimboloWaypoint.infraestructura => Icons.construction,
    SimboloWaypoint.riesgo => Icons.warning_amber_rounded,
  };

  Color get color => switch (this) {
    SimboloWaypoint.generico => const Color(0xFF6A1B9A),
    SimboloWaypoint.muestra => const Color(0xFF00838F),
    SimboloWaypoint.arbol => const Color(0xFF2E7D32),
    SimboloWaypoint.fuenteDeAgua => const Color(0xFF1565C0),
    SimboloWaypoint.infraestructura => const Color(0xFF5D4037),
    SimboloWaypoint.riesgo => const Color(0xFFC62828),
  };
}

/// El simbolo de un punto guardado. Uno que este APK no conoce -lo guardo una
/// version mas nueva- cae en generico en vez de romper la lista.
SimboloWaypoint simboloDe(Waypoint w) => SimboloWaypoint.values.firstWhere(
  (s) => s.name == w.simbolo,
  orElse: () => SimboloWaypoint.generico,
);

/// Pide los datos del punto y lo guarda. Devuelve el punto guardado, o nulo si
/// se cancelo.
///
/// [precisionM] es la del GPS si el punto se marca **donde uno esta parado**;
/// nulo si se eligio con el dedo sobre el mapa. La diferencia se dice en el
/// dialogo y queda guardada: un punto puesto a ojo no vale lo que uno tomado
/// con el GPS encima.
Future<Waypoint?> marcarPunto(
  BuildContext context,
  WidgetRef ref, {
  required LatLng punto,
  double? precisionM,
  double? altitudM,
  String? trazadoCodigo,
}) async {
  final usuario = ref.read(sesionProvider).sesion?.codigoUsuario;
  if (usuario == null || usuario.isEmpty) return null;

  final cuantos = ref.read(puntosProvider).valueOrNull?.length ?? 0;
  final datos = await showDialog<_DatosPunto>(
    context: context,
    builder: (_) => _DialogoPunto(
      punto: punto,
      precisionM: precisionM,
      sugerido: 'Punto ${cuantos + 1}',
    ),
  );
  if (datos == null) return null;

  final guardado = await ref
      .read(waypointsRepositoryProvider)
      .marcar(
        usuarioCodigo: usuario,
        nombre: datos.nombre,
        punto: PuntoGeo(punto.latitude, punto.longitude),
        simbolo: datos.simbolo,
        nota: datos.nota,
        precisionM: precisionM,
        altitudM: altitudM,
        trazadoCodigo: trazadoCodigo,
        proyectoCodigo: await ref.read(proyectoParaGuardarProvider.future),
      );
  // La foto se toma con el punto ya guardado: si la camara falla, o Android
  // cierra la app mientras esta abierta, el punto no se pierde con ella.
  if (datos.conFoto && context.mounted) {
    await agregarFoto(context, ref, guardado);
  }
  return guardado;
}

class _DatosPunto {
  const _DatosPunto(
    this.nombre,
    this.simbolo,
    this.nota, {
    this.conFoto = false,
  });

  final String nombre;
  final SimboloWaypoint simbolo;
  final String nota;

  /// Si despues de guardarlo hay que abrir la camara.
  final bool conFoto;
}

class _DialogoPunto extends StatefulWidget {
  const _DialogoPunto({
    required this.punto,
    required this.precisionM,
    required this.sugerido,
  });

  final LatLng punto;
  final double? precisionM;
  final String sugerido;

  @override
  State<_DialogoPunto> createState() => _DialogoPuntoState();
}

class _DialogoPuntoState extends State<_DialogoPunto> {
  late final _nombre = TextEditingController(text: widget.sugerido);
  final _nota = TextEditingController();
  SimboloWaypoint _simbolo = SimboloWaypoint.generico;

  @override
  void dispose() {
    _nombre.dispose();
    _nota.dispose();
    super.dispose();
  }

  void _guardar({bool conFoto = false}) => Navigator.pop(
    context,
    _DatosPunto(_nombre.text, _simbolo, _nota.text, conFoto: conFoto),
  );

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final precision = widget.precisionM;
    final mala = precision != null && precision > 10;

    return AlertDialog(
      title: const Text('Marcar punto'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.punto.latitude.toStringAsFixed(6)}, '
              '${widget.punto.longitude.toStringAsFixed(6)}',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              precision == null
                  ? 'Elegido con el dedo sobre el mapa, sin GPS.'
                  : mala
                  ? 'GPS +/- ${precision.round()} m: sirve para ubicarse, '
                        'no para volver al mismo sitio exacto.'
                  : 'GPS +/- ${precision.round()} m',
              style: TextStyle(
                fontSize: 15,
                color: mala ? colores.error : colores.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nombre,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in SimboloWaypoint.values)
                  ChoiceChip(
                    avatar: Icon(
                      s.icono,
                      size: 18,
                      color: _simbolo == s ? colores.onPrimary : s.color,
                    ),
                    label: Text(s.titulo),
                    selected: _simbolo == s,
                    showCheckmark: false,
                    selectedColor: colores.primary,
                    labelStyle: TextStyle(
                      color: _simbolo == s ? colores.onPrimary : null,
                    ),
                    onSelected: (_) => setState(() => _simbolo = s),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nota,
              maxLines: 2,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nota (opcional)',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ],
        ),
      ),
      // Tres botones: con la letra agrandada no entran en una fila, y la
      // barra de acciones los apila sola.
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        OutlinedButton.icon(
          onPressed: () => _guardar(conFoto: true),
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Guardar con foto'),
        ),
        FilledButton(onPressed: _guardar, child: const Text('Guardar')),
      ],
    );
  }
}

/// Los puntos marcados, sobre el mapa.
class CapaPuntos extends StatelessWidget {
  const CapaPuntos({required this.puntos, this.seleccionado, super.key});

  final List<Waypoint> puntos;
  final Waypoint? seleccionado;

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: [
        for (final w in puntos)
          Marker(
            point: LatLng(w.latitud, w.longitud),
            width: 34,
            height: 34,
            child: _Pin(
              simbolo: simboloDe(w),
              elegido: w.codigo == seleccionado?.codigo,
            ),
          ),
      ],
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.simbolo, required this.elegido});

  final SimboloWaypoint simbolo;
  final bool elegido;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: simbolo.color,
        shape: BoxShape.circle,
        border: Border.all(
          color: elegido ? Colors.yellowAccent : Colors.white,
          width: elegido ? 3.5 : 2,
        ),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black45)],
      ),
      child: Icon(simbolo.icono, size: 18, color: Colors.white),
    );
  }
}

/// El punto marcado que quedo debajo del dedo, o nulo.
///
/// Se mide en pantalla y no en metros: el dedo tapa lo mismo en cualquier zoom.
Waypoint? puntoCercano({
  required List<Waypoint> puntos,
  required MapCamera camara,
  required Offset toque,
  double radio = 26,
}) {
  Waypoint? mejor;
  var mejorDistancia = radio;
  for (final w in puntos) {
    final en = camara.latLngToScreenOffset(LatLng(w.latitud, w.longitud));
    final d = (en - toque).distance;
    if (d <= mejorDistancia) {
      mejor = w;
      mejorDistancia = d;
    }
  }
  return mejor;
}

/// La tarjeta de un punto elegido en el mapa.
class FichaPunto extends StatelessWidget {
  const FichaPunto({
    required this.punto,
    required this.onCerrar,
    required this.onBorrar,
    this.desde,
    this.onIr,
    super.key,
  });

  final Waypoint punto;
  final VoidCallback onCerrar;
  final VoidCallback onBorrar;

  /// Donde esta la persona, para decir que tan lejos queda.
  final LatLng? desde;

  /// Trazar la ruta hasta el. Nulo donde no hay vias por donde ir.
  final VoidCallback? onIr;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final w = punto;
    final simbolo = simboloDe(w);
    final lejos = desde == null
        ? null
        : distanciaM(
            PuntoGeo(desde!.latitude, desde!.longitude),
            PuntoGeo(w.latitud, w.longitud),
          );

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(simbolo.icono, color: simbolo.color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.nombre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          simbolo.titulo,
                          if (lejos != null)
                            'a ${formatearDistancia(lejos)} en linea recta',
                          w.precisionM == null
                              ? 'puesto a mano'
                              : 'GPS +/- ${w.precisionM!.round()} m',
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
                  onPressed: onCerrar,
                  tooltip: 'Cerrar',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (w.nota != null) ...[
              const SizedBox(height: 4),
              Text(w.nota!, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: FotosDelPunto(punto: w),
            ),
            // Un Wrap y no una fila: con la letra agrandada los dos botones no
            // entran lado a lado, y el segundo baja en vez de salirse.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: onBorrar,
                      icon: const Icon(Icons.delete_outline, size: 20),
                      label: const Text('Borrar'),
                    ),
                    if (onIr != null)
                      FilledButton.icon(
                        onPressed: onIr,
                        icon: const Icon(Icons.directions, size: 20),
                        label: const Text('Como llegar'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
