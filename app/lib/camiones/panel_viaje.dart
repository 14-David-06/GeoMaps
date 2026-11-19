import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/api_client.dart';
import '../core/geo.dart';
import '../state/gps.dart';
import '../state/grabacion.dart';
import '../state/sesion.dart';
import '../ui/boton_voz.dart';
import '../ui/calificar_ruta.dart';
import '../ui/capa_ruta.dart';
import '../ui/mapa_page.dart';
import '../ui/panel_grabacion.dart';
import 'seguimiento.dart';

/// Lo que un viaje sabe de la vuelta de la planilla que fue a recoger. Sale de
/// las propiedades que se guardaron con el recorrido al tomarla, asi que sigue
/// ahi si la app se cierra a mitad de camino.
extension VueltaDelViaje on EstadoGrabacion {
  /// El renglon de la planilla. Nulo si lo que se graba no es una vuelta.
  String? get vueltaId => propiedades['vuelta_id'] as String?;

  /// Donde dejar el vagon vacio de paso, si despacho lo dijo y el acopio
  /// tiene coordenada.
  LatLng? get entrega {
    final c = propiedades['entrega'];
    if (c is! List || c.length < 2) return null;
    // [lon, lat], como todo en el GeoJSON.
    return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
  }

  String? get entregaNombre => propiedades['entrega_nombre'] as String?;
  String? get vagon => propiedades['vagon'] as String?;

  /// Por donde va la vuelta: si ya llego, si ya volvio.
  SeguimientoVuelta get seguimiento => SeguimientoVuelta.de(propiedades);
}

/// Donde esta el telefono ahora, si el GPS ya dijo algo.
PuntoGeo? _dondeEstoy() {
  final p = Gps.instancia.ultima;
  return p == null ? null : PuntoGeo(p.latitude, p.longitude);
}

/// Abre el mapa del viaje en curso, yendo a donde toca: a los vagones si
/// todavia no llego, al punto de salida si ya esta de vuelta.
void abrirMapaDelViaje(BuildContext context, EstadoGrabacion g) {
  final seg = g.seguimiento;
  final vagones = g.destino;
  final salida = seg.salida?.punto;

  LatLng? destino;
  String? nombre;
  if (seg.etapa == EtapaVuelta.yendo) {
    if (vagones != null) {
      destino = LatLng(vagones.latitud, vagones.longitud);
      nombre = 'Vagones en ${g.destinoNombre ?? ''}';
    }
  } else if (salida != null) {
    destino = LatLng(salida.latitud, salida.longitud);
    nombre = 'Punto de salida';
  }

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MapaPage.guaicaramo(
        destinoInicial: destino,
        nombreDestinoInicial: nombre,
        panelSuperior: const PanelViaje(),
      ),
    ),
  );
}

/// La franja de arriba del mapa durante la vuelta de un camion.
///
/// Dice en que paso va -ir por los vagones, volver, finalizar- y que le falta
/// para el siguiente. El boton de finalizar aparece recien cuando fue y
/// volvio: mostrarlo antes y apagado seria un boton que no se entiende por que
/// no anda.
///
/// Letra grande a proposito: quien lo lee va manejando, y la mayoria de los
/// conductores no ve bien de cerca.
class PanelViaje extends ConsumerWidget {
  const PanelViaje({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(grabadorProvider);
    if (g.codigo == null) return const SizedBox.shrink();
    // Un recorrido cualquiera que quedo grabando: su franja de siempre.
    if (!g.esVuelta) return const PanelGrabacion();

    final colores = Theme.of(context).colorScheme;
    final seg = g.seguimiento;
    final donde = _dondeEstoy();
    final vagones = g.destino;
    final entrega = g.entrega;
    final salida = seg.salida?.punto;

    final String titulo;
    final String detalle;
    switch (seg.etapa) {
      case EtapaVuelta.yendo:
        titulo = '1 de 3 · Ve por los vagones';
        final falta = seg.faltaAlPunto(donde);
        detalle = seg.llegadaAMano
            ? 'Este acopio no tiene coordenada. Marca la llegada cuando '
                  'estes en los vagones.'
            : falta == null
            ? 'Buscando tu ubicacion...'
            : 'Te faltan ${formatearDistancia(falta)} para llegar.';
      case EtapaVuelta.volviendo:
        titulo = '2 de 3 · Vuelve al punto de salida';
        final falta = seg.faltaALaSalida(donde);
        detalle = falta == null
            ? 'Ya estuviste en los vagones.'
            : 'Ya estuviste en los vagones. Te faltan '
                  '${formatearDistancia(falta)} para volver.';
      case EtapaVuelta.deVuelta:
        titulo = '3 de 3 · Ya puedes finalizar';
        detalle = 'Fuiste y volviste: ${formatearDistancia(g.metros)}.';
    }

    return Material(
      color: colores.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.fiber_manual_record,
                  color: g.abiertaSinGrabar ? colores.outline : Colors.red,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    g.nombre ?? 'Vuelta',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colores.onSurfaceVariant,
                    ),
                  ),
                ),
                // El parlante: la vuelta avisa en voz alta cuando llega
                // y cuando vuelve.
                const BotonVoz(),
                // Devolverla solo se puede antes de llegar; despues no hay
                // nada que ofrecer aca.
                if (seg.puedeDevolver)
                  TextButton(
                    onPressed: () => _opciones(context, ref),
                    child: const Text(
                      'Opciones',
                      style: TextStyle(fontSize: 15),
                    ),
                  ),
              ],
            ),
            Text(
              titulo,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: colores.onSurface,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detalle,
              style: TextStyle(
                fontSize: 17,
                color: colores.onSurface,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 10),
            if (g.abiertaSinGrabar)
              _Ancho(
                child: FilledButton.icon(
                  onPressed: () =>
                      ref.read(grabadorProvider.notifier).reanudar(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Seguir la vuelta'),
                ),
              )
            else if (seg.etapa == EtapaVuelta.deVuelta)
              _Ancho(
                child: FilledButton.icon(
                  onPressed: () => terminarViaje(context, ref),
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Finalizar la vuelta'),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (seg.etapa == EtapaVuelta.yendo && vagones != null)
                    _Boton(
                      icono: Icons.inventory_2,
                      texto: 'Ir a los vagones',
                      onPressed: () => MapaPage.irA(
                        context,
                        LatLng(vagones.latitud, vagones.longitud),
                        nombre: 'Vagones en ${g.destinoNombre ?? ''}',
                      ),
                    ),
                  if (seg.llegadaAMano)
                    _Boton(
                      icono: Icons.where_to_vote,
                      texto: 'Ya llegue a los vagones',
                      onPressed: () => _marcarLlegada(context, ref),
                    ),
                  if (seg.etapa == EtapaVuelta.volviendo && salida != null)
                    _Boton(
                      icono: Icons.u_turn_left,
                      texto: 'Camino de vuelta',
                      onPressed: () => MapaPage.irA(
                        context,
                        LatLng(salida.latitud, salida.longitud),
                        nombre: 'Punto de salida',
                      ),
                    ),
                  if (entrega != null)
                    _Boton(
                      icono: Icons.flag,
                      texto:
                          'Dejar el vagon'
                          '${g.vagon == null ? '' : ' ${g.vagon}'}',
                      onPressed: () => MapaPage.irA(
                        context,
                        entrega,
                        nombre: 'Dejar el vagon en ${g.entregaNombre ?? ''}',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Un boton a todo el ancho y alto para un dedo: es la accion del momento.
class _Ancho extends StatelessWidget {
  const _Ancho({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButtonTheme(
      data: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      child: child,
    ),
  );
}

class _Boton extends StatelessWidget {
  const _Boton({
    required this.icono,
    required this.texto,
    required this.onPressed,
  });

  final IconData icono;
  final String texto;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
    icon: Icon(icono, size: 20),
    label: Text(texto),
  );
}

const _textoDialogo = TextStyle(fontSize: 17, height: 1.3);
const _tituloDialogo = TextStyle(fontSize: 22, fontWeight: FontWeight.w800);

ButtonStyle get _botonDialogo => FilledButton.styleFrom(
  minimumSize: const Size(0, 50),
  textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
);

ButtonStyle get _botonDialogoSuave => TextButton.styleFrom(
  minimumSize: const Size(0, 50),
  textStyle: const TextStyle(fontSize: 17),
);

/// Lo unico que se puede hacer con una vuelta antes de llegar: devolverla.
Future<void> _opciones(BuildContext context, WidgetRef ref) async {
  final vueltaId = ref.read(grabadorProvider).vueltaId;
  if (vueltaId == null) return;
  final devolver = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: const Text('Esta vuelta', style: _tituloDialogo),
      content: const Text(
        'Para finalizarla tienes que llegar a los vagones y volver al punto '
        'de salida.\n\nSi la tomaste por error o no la vas a recoger, '
        'devuelvela para que la tome otro camion.',
        style: _textoDialogo,
      ),
      actions: [
        TextButton(
          style: _botonDialogoSuave,
          onPressed: () => Navigator.pop(dialogo, true),
          child: const Text('Devolver la vuelta'),
        ),
        FilledButton(
          style: _botonDialogo,
          onPressed: () => Navigator.pop(dialogo, false),
          child: const Text('Seguir'),
        ),
      ],
    ),
  );
  if (devolver == true && context.mounted) {
    await _soltar(context, ref, vueltaId);
  }
}

/// Finaliza la vuelta, si ya fue y volvio. Devuelve si quedo finalizada.
///
/// Es la unica puerta para cerrar el viaje de un camion, se llame desde
/// donde se llame. Si todavia no llego a los vagones o no volvio, no cierra
/// nada: dice que falta. Asi una vuelta no queda "hecha" sin haberse hecho, y
/// como no se puede tomar otra hasta finalizarla, tampoco se acumulan.
Future<bool> terminarViaje(BuildContext context, WidgetRef ref) async {
  final g = ref.read(grabadorProvider);
  if (!g.esVuelta) return terminarRecorrido(context, ref);

  final seg = g.seguimiento;
  final donde = _dondeEstoy();
  if (!seg.puedeFinalizar) {
    await _decirQueFalta(context, ref, seg, donde);
    return false;
  }

  final si = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: const Text('Finalizar la vuelta', style: _tituloDialogo),
      content: const Text(
        'Se deja de grabar el recorrido y quedas libre para tomar otra '
        'vuelta.',
        style: _textoDialogo,
      ),
      actions: [
        TextButton(
          style: _botonDialogoSuave,
          onPressed: () => Navigator.pop(dialogo, false),
          child: const Text('Todavia no'),
        ),
        FilledButton(
          style: _botonDialogo,
          onPressed: () => Navigator.pop(dialogo, true),
          child: const Text('Finalizar'),
        ),
      ],
    ),
  );
  if (si != true || !context.mounted) return false;

  final avisos = ScaffoldMessenger.of(context);
  final grabador = ref.read(grabadorProvider.notifier);
  final api = ref.read(apiProvider);

  // Quien acaba de hacer el viaje es quien sabe como estaba la via: se le
  // pregunta antes de cerrar, y la respuesta queda con el recorrido.
  final calificacion = await pedirCalificacion(
    context,
    titulo: 'Vuelta finalizada',
    detalle: g.metros < 20 ? null : 'Recorriste ${formatearDistancia(g.metros)}.',
  );

  final fin = seg.fin(
    donde: _dondeEstoy(),
    precisionM: Gps.instancia.ultima?.accuracy,
    hora: DateTime.now(),
  );
  final cierre = <String, Object?>{
    ...?calificacion?.aPropiedades(),
    'fin': fin.aJson(),
  };

  // El aviso directo es para que la vuelta quede cerrada ya si hay senal. No
  // se espera: lo que de verdad la cierra viaja con el recorrido, que sube
  // solo y reintenta.
  unawaited(
    avisarSeguimiento(
      api,
      {...g.propiedades, ...cierre},
      recorridoM: g.metros,
      trazado: g.codigo,
    ),
  );
  await grabador.terminar(propiedades: cierre);
  avisos.showSnackBar(
    const SnackBar(
      content: Text(
        'Vuelta finalizada. El recorrido sube solo cuando haya senal.',
      ),
    ),
  );
  return true;
}

/// Por que no se puede finalizar todavia, con lo que le falta.
Future<void> _decirQueFalta(
  BuildContext context,
  WidgetRef ref,
  SeguimientoVuelta seg,
  PuntoGeo? donde,
) async {
  final vueltaId = ref.read(grabadorProvider).vueltaId;
  final yendo = seg.etapa == EtapaVuelta.yendo;
  final falta = yendo ? seg.faltaAlPunto(donde) : seg.faltaALaSalida(donde);
  final cuanto = falta == null ? '' : ' Te faltan ${formatearDistancia(falta)}.';

  final devolver = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: Text(
        yendo ? 'Todavia no llegas a los vagones' : 'Te falta volver',
        style: _tituloDialogo,
      ),
      content: Text(
        yendo
            ? 'Para finalizar la vuelta tienes que llegar a los vagones y '
                  'volver al punto de salida.$cuanto'
            : 'Ya estuviste en los vagones. Vuelve al punto de salida para '
                  'finalizar la vuelta.$cuanto',
        style: _textoDialogo,
      ),
      actions: [
        if (seg.puedeDevolver && vueltaId != null)
          TextButton(
            style: _botonDialogoSuave,
            onPressed: () => Navigator.pop(dialogo, true),
            child: const Text('No la voy a recoger'),
          ),
        FilledButton(
          style: _botonDialogo,
          onPressed: () => Navigator.pop(dialogo, false),
          child: const Text('Entendido'),
        ),
      ],
    ),
  );
  if (devolver == true && vueltaId != null && context.mounted) {
    await _soltar(context, ref, vueltaId);
  }
}

/// Marca la llegada a mano, para un acopio que no tiene coordenada. El GPS no
/// puede comprobarla, asi que queda anotada como marcada por la persona -con
/// donde estaba al marcarla- y no se deja marcar desde el patio.
Future<void> _marcarLlegada(BuildContext context, WidgetRef ref) async {
  final g = ref.read(grabadorProvider);
  final seg = g.seguimiento;
  final donde = _dondeEstoy();

  final motivo = seg.porQueNoMarcar(donde);
  if (motivo != null || donde == null) {
    await showDialog<void>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('Todavia no', style: _tituloDialogo),
        content: Text(motivo ?? '', style: _textoDialogo),
        actions: [
          FilledButton(
            style: _botonDialogo,
            onPressed: () => Navigator.pop(dialogo),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
    return;
  }

  final si = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: const Text('Ya llegue a los vagones', style: _tituloDialogo),
      content: const Text(
        'Queda anotado que llegaste, con el lugar donde estas ahora. '
        'Despues vuelve al punto de salida para finalizar.',
        style: _textoDialogo,
      ),
      actions: [
        TextButton(
          style: _botonDialogoSuave,
          onPressed: () => Navigator.pop(dialogo, false),
          child: const Text('Todavia no'),
        ),
        FilledButton(
          style: _botonDialogo,
          onPressed: () => Navigator.pop(dialogo, true),
          child: const Text('Si, llegue'),
        ),
      ],
    ),
  );
  if (si != true) return;

  final cambios = seg.marcarLlegada(
    donde: donde,
    precisionM: Gps.instancia.ultima?.accuracy,
    hora: DateTime.now(),
  );
  final api = ref.read(apiProvider);
  await ref.read(grabadorProvider.notifier).anotar(cambios);
  unawaited(avisarSeguimiento(api, {...g.propiedades, ...cambios}));
}

/// Devuelve la vuelta a la lista y tira lo grabado.
///
/// En ese orden: primero la planilla, que necesita senal. Si no hay, no se
/// toca nada -el viaje sigue grabando- y se puede reintentar; al reves quedaria
/// la vuelta a su nombre y sin el recorrido que lo respalda.
Future<bool> _soltar(
  BuildContext context,
  WidgetRef ref,
  String vueltaId,
) async {
  final seguro = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: const Text('Devolver la vuelta', style: _tituloDialogo),
      content: const Text(
        'La vuelta vuelve a la lista de pendientes para que la tome otro '
        'camion, y lo grabado de este viaje se descarta.',
        style: _textoDialogo,
      ),
      actions: [
        TextButton(
          style: _botonDialogoSuave,
          onPressed: () => Navigator.pop(dialogo, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: _botonDialogo,
          onPressed: () => Navigator.pop(dialogo, true),
          child: const Text('Devolverla'),
        ),
      ],
    ),
  );
  if (seguro != true || !context.mounted) return false;

  final avisos = ScaffoldMessenger.of(context);
  final grabador = ref.read(grabadorProvider.notifier);
  try {
    await ref.read(apiProvider).soltarVuelta(vueltaId);
  } on ApiError catch (e) {
    avisos.showSnackBar(SnackBar(content: Text(e.mensaje)));
    return false;
  } catch (_) {
    avisos.showSnackBar(
      const SnackBar(
        content: Text(
          'Sin conexion: devolver la vuelta necesita senal. El viaje sigue '
          'grabando.',
        ),
      ),
    );
    return false;
  }

  await grabador.descartar();
  avisos.showSnackBar(
    const SnackBar(content: Text('La vuelta volvio a la lista de pendientes.')),
  );
  return true;
}
