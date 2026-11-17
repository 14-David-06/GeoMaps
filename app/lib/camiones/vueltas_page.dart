import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/api_client.dart';
import '../core/geo.dart';
import '../core/ubicacion.dart';
import '../state/gps.dart';
import '../state/grabacion.dart';
import '../state/sesion.dart';
import '../state/sincronizador.dart';
import '../ui/capa_ruta.dart';
import '../ui/mapa_page.dart';
import 'panel_viaje.dart';
import 'seguimiento.dart';
import 'vueltas.dart';

/// Las vueltas pendientes por recoger, con su resumen arriba. Lo que abre el QR.
///
/// El orden es el de la planilla -la mas vieja primero-, no por cercania: el
/// orden de despacho es la prioridad, y una vuelta de ayer que sigue ahi es la
/// que mas urge aunque quede lejos.
///
/// **Una vuelta a la vez.** Si la cuenta ya tiene una sin finalizar -en este
/// telefono o segun el servidor-, la lista se ve pero ninguna se deja tomar, y
/// arriba dice cual es la que falta cerrar.
class VueltasPage extends ConsumerWidget {
  const VueltasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vueltas = ref.watch(vueltasProvider);
    final g = ref.watch(grabadorProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vueltas pendientes'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            iconSize: 28,
            onPressed: () => ref.invalidate(vueltasProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: vueltas.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Error(
          texto: e is ApiError
              ? e.mensaje
              : 'No se pudo traer la lista. Revisa la senal y vuelve a '
                    'intentar.',
          onReintentar: () => ref.invalidate(vueltasProvider),
        ),
        data: (lista) {
          final abierto = lista.viajeAbierto;
          final ocupado = g.codigo != null || abierto != null;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(vueltasProvider.future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
                _Resumen(
                  resumen: ResumenVueltas(lista.vueltas, DateTime.now()),
                ),
                if (g.codigo != null)
                  _EnEsteTelefono(estado: g)
                else if (abierto != null)
                  _VueltaAbierta(viaje: abierto)
                else
                  _QuienToma(conductor: lista.conductor),
                const SizedBox(height: 4),
                if (lista.vueltas.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No hay vueltas pendientes por recoger.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ),
                for (final v in lista.vueltas)
                  _FilaVuelta(
                    vuelta: v,
                    conductor: lista.conductor,
                    bloqueada: ocupado,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A nombre de quien van a quedar las vueltas que se tomen desde este
/// telefono. Va arriba de la lista porque es lo primero que hay que saber: un
/// telefono prestado toma vueltas a nombre de su dueno, no de quien lo tiene.
class _QuienToma extends StatelessWidget {
  const _QuienToma({required this.conductor});

  final Conductor? conductor;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final nombre = conductor?.nombre;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.badge_outlined, size: 22, color: colores.onSurface),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              nombre == null
                  ? 'Las vueltas que tomes quedan a tu nombre.'
                  : 'Las vueltas que tomes quedan a nombre de $nombre.',
              style: TextStyle(fontSize: 16, color: colores.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

/// El cartel de "no puedes tomar otra": dice por que y ofrece la salida.
class _Aviso extends StatelessWidget {
  const _Aviso({
    required this.titulo,
    required this.detalle,
    this.boton,
    this.icono = Icons.local_shipping,
    this.onPressed,
  });

  final String titulo;
  final String detalle;
  final String? boton;
  final IconData icono;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Card(
      color: colores.tertiaryContainer,
      margin: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              titulo,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: colores.onTertiaryContainer,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detalle,
              style: TextStyle(
                fontSize: 17,
                height: 1.3,
                color: colores.onTertiaryContainer,
              ),
            ),
            if (boton != null) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onPressed,
                  style: _botonGrande,
                  icon: Icon(icono),
                  label: Text(boton!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Hay un viaje abierto en este telefono: se va a el, no se toma otro.
class _EnEsteTelefono extends ConsumerWidget {
  const _EnEsteTelefono({required this.estado});

  final EstadoGrabacion estado;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = estado;
    return _Aviso(
      titulo: g.esVuelta
          ? 'Tienes una vuelta sin finalizar'
          : 'Tienes un recorrido grabando',
      detalle: g.esVuelta
          ? '${g.nombre ?? 'La vuelta'}. Finalizala para poder tomar otra.'
          : 'Terminalo desde el mapa para poder tomar una vuelta.',
      boton: g.esVuelta ? 'Ir a mi vuelta' : null,
      icono: Icons.navigation,
      onPressed: () {
        if (g.abiertaSinGrabar) {
          ref.read(grabadorProvider.notifier).reanudar();
        }
        abrirMapaDelViaje(context, ref.read(grabadorProvider));
      },
    );
  }
}

/// Si el recorrido de ese viaje ya esta cerrado en este telefono y todavia no
/// subio. Pasa cuando se finalizo sin senal: el servidor lo sigue viendo
/// abierto hasta que el recorrido llegue.
final _porSubirProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  viaje,
) async {
  final usuario = ref.watch(
    sesionProvider.select((e) => e.sesion?.codigoUsuario),
  );
  if (usuario == null) return false;
  final pendientes = await ref
      .watch(trazadosRepositoryProvider)
      .pendientes(usuario);
  return pendientes.any((t) {
    try {
      final geometria = jsonDecode(t.geometria) as Map<String, dynamic>;
      return (geometria['properties'] as Map?)?['viaje'] == viaje;
    } catch (_) {
      return false;
    }
  });
});

/// El servidor dice que la cuenta tiene una vuelta sin finalizar y este
/// telefono no la tiene abierta.
class _VueltaAbierta extends ConsumerWidget {
  const _VueltaAbierta({required this.viaje});

  final ViajeAbierto viaje;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final porSubir = ref.watch(_porSubirProvider(viaje.codigo)).valueOrNull;
    final subiendo = ref.watch(sincronizadorProvider).subiendo;

    // Ya la finalizo aca, sin senal: falta que el recorrido suba.
    if (porSubir == true) {
      return _Aviso(
        titulo: 'Tu ultima vuelta todavia no sube',
        detalle:
            '${viaje.titulo} ya esta finalizada en este telefono. Cuando '
            'suba vas a poder tomar otra.',
        boton: subiendo ? 'Subiendo...' : 'Subir ahora',
        icono: Icons.cloud_upload,
        onPressed: subiendo
            ? null
            : () async {
                await ref.read(sincronizadorProvider.notifier).sincronizar();
                ref.invalidate(vueltasProvider);
              },
      );
    }

    final vuelta = viaje.vuelta;
    return _Aviso(
      titulo: 'Tienes ${viaje.titulo} sin finalizar',
      detalle: vuelta == null
          ? 'No puedes tomar otra hasta finalizarla. No se pudo leer a donde '
                'era: actualiza la lista con senal.'
          : 'Es la de ${vuelta.origen.largo}. No puedes tomar otra hasta '
                'finalizarla.',
      boton: vuelta == null ? null : 'Continuar esa vuelta',
      icono: Icons.navigation,
      onPressed: vuelta == null ? null : () => _continuar(context, ref, viaje),
    );
  }
}

class _Resumen extends StatelessWidget {
  const _Resumen({required this.resumen});

  final ResumenVueltas resumen;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final r = resumen;
    final vieja = r.masVieja;

    Widget dato(String valor, String etiqueta, {bool alerta = false}) =>
        Expanded(
          child: Column(
            children: [
              Text(
                valor,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: alerta ? colores.error : colores.onSurface,
                ),
              ),
              Text(
                etiqueta,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: colores.onSurface),
              ),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                dato('${r.total}', 'por recoger'),
                dato('${r.comercial}', 'comercial'),
                dato('${r.hibrido}', 'hibrido'),
                dato(
                  '${r.deOtroDia}',
                  'de dias\nanteriores',
                  alerta: r.deOtroDia > 0,
                ),
              ],
            ),
            if (vieja != null || r.sinCoordenada > 0) ...[
              const Divider(height: 20),
              if (vieja != null)
                Text(
                  'La mas vieja se reporto ${_cuando(vieja)}.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: colores.onSurface),
                ),
              if (r.sinCoordenada > 0)
                Text(
                  r.sinCoordenada == 1
                      ? '1 vuelta no tiene coordenada: se puede tomar, pero '
                            'el mapa no traza la ruta.'
                      : '${r.sinCoordenada} vueltas no tienen coordenada: se '
                            'pueden tomar, pero el mapa no traza la ruta.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: colores.error),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilaVuelta extends ConsumerWidget {
  const _FilaVuelta({
    required this.vuelta,
    required this.conductor,
    required this.bloqueada,
  });

  final Vuelta vuelta;
  final Conductor? conductor;

  /// La cuenta ya tiene una vuelta sin finalizar: esta no se deja tomar.
  final bool bloqueada;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colores = Theme.of(context).colorScheme;
    final v = vuelta;
    final otroDia = v.esDeOtroDia(DateTime.now());
    final lejos = _distancia(v);
    final sinPunto = v.origen.punto == null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Vuelta #${v.consecutivo}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: colores.onSurface,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colores.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    v.nombreFruto,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colores.onSurface,
                    ),
                  ),
                ),
                Text(
                  otroDia
                      ? 'del ${_fecha(v.jornada)} · ${_hora(v.reportadoEn)}'
                      : 'reporte ${_hora(v.reportadoEn)}',
                  style: TextStyle(
                    fontSize: 16,
                    color: otroDia ? colores.error : colores.onSurface,
                    fontWeight: otroDia ? FontWeight.w800 : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Vagones llenos en',
              style: TextStyle(fontSize: 15, color: colores.onSurface),
            ),
            Text(
              v.origen.acopio,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                height: 1.15,
                color: colores.onSurface,
              ),
            ),
            if (v.origen.lugar.isNotEmpty)
              Text(
                v.origen.lugar,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  color: colores.onSurface,
                ),
              ),
            if (v.destino != null) ...[
              const SizedBox(height: 8),
              Text(
                'Dejar el vagon${v.vagon == null ? '' : ' ${v.vagon}'} en '
                '${v.destino!.largo}',
                style: TextStyle(fontSize: 17, color: colores.onSurface),
              ),
            ],
            if (v.observaciones != null && v.observaciones!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                v.observaciones!,
                style: TextStyle(fontSize: 16, color: colores.onSurface),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              sinPunto
                  ? 'Sin coordenada: pregunta en despacho donde es.'
                  : lejos == null
                  ? 'El mapa te lleva por las vias.'
                  : 'A ${formatearDistancia(lejos)} en linea recta.',
              style: TextStyle(
                fontSize: 16,
                color: sinPunto ? colores.error : colores.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            // Un boton y no la tarjeta entera: tomar una vuelta la anota en
            // la planilla, y eso no puede pasar por rozar la lista mientras
            // se la recorre con el dedo.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: bloqueada
                    ? null
                    : () => _tomar(context, ref, v, conductor),
                style: _botonGrande,
                icon: const Icon(Icons.local_shipping),
                label: const Text('Tomar esta vuelta'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// En linea recta y no por la via: alcanza para ordenar mentalmente la lista
  /// sin calcular diez rutas. La de verdad la da el mapa al tomarla.
  double? _distancia(Vuelta v) {
    final p = Gps.instancia.ultima;
    final destino = v.origen.punto;
    if (p == null || destino == null) return null;
    return distanciaM(
      PuntoGeo(p.latitude, p.longitude),
      PuntoGeo(destino.latitude, destino.longitude),
    );
  }
}

final _botonGrande = FilledButton.styleFrom(
  minimumSize: const Size.fromHeight(54),
  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
);

/// Donde esta el camion ahora, si el GPS lo sabe bien: el punto de salida de
/// la vuelta. Una posicion vieja o con mucho error no sirve -a ese punto hay
/// que volver-, y en ese caso lo fija el primer fix bueno del viaje.
Movimiento? _puntoDeSalida() {
  final p = Gps.instancia.ultima;
  if (p == null ||
      Ubicacion.esDeCache(p) ||
      p.accuracy > SeguimientoVuelta.precisionMaximaM) {
    return null;
  }
  return Movimiento(
    en: DateTime.now(),
    punto: PuntoGeo(p.latitude, p.longitude),
    precisionM: p.accuracy,
  );
}

/// Tomar una vuelta: firmarla, empezar a grabar y abrir el mapa yendo hacia
/// los vagones.
///
/// Una vuelta sin coordenada tambien se deja tomar: lo que falta ahi es la
/// ruta, no el conductor. Se toma igual, se graba igual, y la llegada la
/// marca el conductor.
Future<void> _tomar(
  BuildContext context,
  WidgetRef ref,
  Vuelta v,
  Conductor? conductor,
) async {
  final sesion = ref.read(sesionProvider).sesion;
  final salida = _puntoDeSalida();
  final respuesta = await showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Confirmar(
      vuelta: v,
      conductor: conductor,
      // Sin el dato del backend se decide con lo que la sesion sabe: las
      // cuentas de Google no tienen clave que pedir.
      pideClave: conductor?.pideClave ?? (sesion?.proveedor != 'Google'),
      salida: salida,
    ),
  );
  if (respuesta == null || !context.mounted) return;

  final nombre = respuesta['conductor'] as String? ?? 'tu nombre';
  await _empezar(
    context,
    ref,
    vuelta: v,
    viaje: respuesta['viaje'] as String?,
    conductor: nombre,
    salida: salida,
    aviso: 'Vuelta #${v.consecutivo} a nombre de $nombre.',
  );
}

/// Retoma en este telefono una vuelta que el servidor tiene abierta: se
/// reinstalo la app, o se tomo desde otro telefono. Sin esto la cuenta
/// quedaba sin poder tomar ninguna otra y sin como cerrar esa.
Future<void> _continuar(
  BuildContext context,
  WidgetRef ref,
  ViajeAbierto viaje,
) async {
  final vuelta = viaje.vuelta;
  if (vuelta == null) return;
  final desde = viaje.salida;
  await _empezar(
    context,
    ref,
    vuelta: vuelta,
    viaje: viaje.codigo,
    salida: desde == null
        ? null
        : Movimiento(
            en: viaje.tomadaEn ?? DateTime.now(),
            punto: PuntoGeo(desde.latitude, desde.longitude),
          ),
    llegada: viaje.llegadaEn == null ? null : Movimiento(en: viaje.llegadaEn!),
    regreso: viaje.regresoEn == null ? null : Movimiento(en: viaje.regresoEn!),
    aviso: 'Sigues con la vuelta #${vuelta.consecutivo}.',
  );
}

/// Empieza a grabar el viaje de una vuelta y abre el mapa.
///
/// Con el recorrido se guarda todo lo que hace falta para seguirla sin senal
/// y aunque la app se cierre: que vuelta es, donde estan los vagones, de
/// donde salio el camion y por donde va.
Future<void> _empezar(
  BuildContext context,
  WidgetRef ref, {
  required Vuelta vuelta,
  required String? viaje,
  String? conductor,
  Movimiento? salida,
  Movimiento? llegada,
  Movimiento? regreso,
  required String aviso,
}) async {
  final v = vuelta;
  final vagones = v.origen.punto;
  final entrega = v.destino?.punto;
  try {
    await ref
        .read(grabadorProvider.notifier)
        .iniciar(
          nombre: v.nombreViaje,
          destino: vagones == null
              ? null
              : PuntoGeo(vagones.latitude, vagones.longitude),
          destinoNombre: v.origen.largo,
          propiedades: {
            'vuelta_id': v.id,
            // El codigo del viaje en el seguimiento del servidor.
            'viaje': ?viaje,
            'consecutivo': v.consecutivo,
            'jornada': v.jornada.toIso8601String().substring(0, 10),
            'origen': v.origen.codigo,
            'conductor': ?conductor,
            // De donde sale el camion: a donde tiene que volver.
            'salida': ?salida?.aJson(),
            'llegada': ?llegada?.aJson(),
            'regreso': ?regreso?.aJson(),
            // Donde dejar el vagon vacio de paso: el otro tramo del viaje.
            if (entrega != null)
              'entrega': [entrega.longitude, entrega.latitude],
            if (v.destino != null) 'entrega_nombre': v.destino!.largo,
            'vagon': v.vagon,
          },
        );
  } catch (_) {
    // La vuelta ya quedo a su nombre en la planilla. Que no arranque la
    // grabacion no puede dejarlo parado frente a la lista: el mapa abre igual.
  }
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso)));

  // Si ya habia llegado, lo que sigue es volver.
  final vuelve = llegada != null && salida?.punto != null;
  final LatLng? destino = vuelve
      ? LatLng(salida!.punto!.latitud, salida.punto!.longitud)
      : vagones;

  // Reemplaza la lista: volver atras desde el mapa no puede mostrar una lista
  // donde la vuelta que se acaba de tomar sigue apareciendo libre.
  await Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => MapaPage.guaicaramo(
        destinoInicial: destino,
        nombreDestinoInicial: destino == null
            ? null
            : vuelve
            ? 'Punto de salida'
            : 'Vagones en ${v.origen.largo}',
        panelSuperior: const PanelViaje(),
      ),
    ),
  );
}

/// La firma: la clave de GeoMaps, si la cuenta tiene una. Una cuenta de
/// Google confirma con un toque. La cedula no se pide.
///
/// Devuelve lo que respondio el backend -a nombre de quien quedo y el codigo
/// del viaje-, o nulo si se cancelo.
class _Confirmar extends ConsumerStatefulWidget {
  const _Confirmar({
    required this.vuelta,
    required this.conductor,
    required this.pideClave,
    required this.salida,
  });

  final Vuelta vuelta;
  final Conductor? conductor;
  final bool pideClave;

  /// Donde esta el camion ahora. Nulo si el GPS todavia no lo sabe.
  final Movimiento? salida;

  @override
  ConsumerState<_Confirmar> createState() => _ConfirmarState();
}

class _ConfirmarState extends ConsumerState<_Confirmar> {
  final _clave = TextEditingController();
  bool _enviando = false;
  bool _verClave = false;
  String? _error;

  @override
  void dispose() {
    _clave.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    if (widget.pideClave && _clave.text.isEmpty) {
      setState(() => _error = 'Escribe tu clave de GeoMaps.');
      return;
    }
    setState(() {
      _enviando = true;
      _error = null;
    });
    final donde = widget.salida?.punto;
    try {
      final r = await ref
          .read(apiProvider)
          .confirmarVuelta(
            widget.vuelta.id,
            clave: widget.pideClave ? _clave.text : null,
            salida: donde == null
                ? null
                : {
                    'lat': donde.latitud,
                    'lon': donde.longitud,
                    'precision_m': ?widget.salida?.precisionM,
                  },
          );
      if (mounted) Navigator.pop(context, r);
    } on ApiError catch (e) {
      // La tomo otro, o esta cuenta ya tiene una abierta: la lista que se
      // esta viendo ya no sirve.
      if (e.codigo == 409 || e.codigo == 423) ref.invalidate(vueltasProvider);
      if (mounted) {
        setState(
          () => _error = e.codigo == 422
              // Un servidor anterior, que todavia exige la cedula.
              ? 'El servidor todavia no esta actualizado para tomar vueltas '
                    'sin cedula. Avisale a soporte.'
              : e.mensaje,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Sin conexion con el servidor. Tomar una vuelta necesita '
              'senal: busca donde haya y vuelve a intentar.',
        );
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vuelta;
    final nombre = widget.conductor?.nombre;
    final colores = Theme.of(context).colorScheme;
    const texto = TextStyle(fontSize: 17, height: 1.3);

    return AlertDialog(
      title: Text(
        'Tomar la vuelta #${v.consecutivo}',
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vas por los vagones de', style: texto),
            Text(
              v.origen.acopio,
              style: const TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w900,
                height: 1.2,
              ),
            ),
            if (v.origen.lugar.isNotEmpty)
              Text(
                v.origen.lugar,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Queda ${nombre == null ? 'a tu nombre' : 'a nombre de $nombre'}'
              '. Sales desde donde estas ahora: para finalizarla tienes que '
              'llegar a los vagones y volver aqui.',
              style: texto,
            ),
            if (v.origen.punto == null) ...[
              const SizedBox(height: 10),
              Text(
                'Este acopio no tiene coordenada: el mapa no traza la ruta. '
                'Pregunta en despacho donde es.',
                style: texto.copyWith(color: colores.error),
              ),
            ],
            if (widget.salida == null) ...[
              const SizedBox(height: 10),
              Text(
                'El GPS todavia no da tu posicion: el punto de salida se '
                'toma apenas la tenga.',
                style: texto.copyWith(color: colores.onSurfaceVariant),
              ),
            ],
            if (widget.pideClave) ...[
              const SizedBox(height: 18),
              const Text(
                'Tu clave de GeoMaps',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _clave,
                enabled: !_enviando,
                autofocus: true,
                obscureText: !_verClave,
                onSubmitted: (_) => _enviar(),
                style: const TextStyle(fontSize: 22),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 16,
                  ),
                  suffixIcon: IconButton(
                    tooltip: _verClave ? 'Ocultar la clave' : 'Ver la clave',
                    iconSize: 28,
                    onPressed: () => setState(() => _verClave = !_verClave),
                    icon: Icon(
                      _verClave ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // Aparte y no como ayuda del campo: ahi se cortaba con puntos
              // suspensivos y no se alcanzaba a leer.
              Text(
                'Es la misma con la que entras a la app.',
                style: TextStyle(fontSize: 15, color: colores.onSurfaceVariant),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: colores.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 52),
            textStyle: const TextStyle(fontSize: 18),
          ),
          onPressed: _enviando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            textStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          onPressed: _enviando ? null : _enviar,
          child: _enviando
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Text('Tomar la vuelta'),
        ),
      ],
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.texto, required this.onReintentar});

  final String texto;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              texto,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onReintentar,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 52),
                textStyle: const TextStyle(fontSize: 18),
              ),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

String _dos(int n) => n.toString().padLeft(2, '0');
String _hora(DateTime f) => '${_dos(f.hour)}:${_dos(f.minute)}';
String _fecha(DateTime f) => '${_dos(f.day)}/${_dos(f.month)}';

String _cuando(DateTime f) {
  final hoy = DateTime.now();
  final mismoDia =
      f.year == hoy.year && f.month == hoy.month && f.day == hoy.day;
  return mismoDia
      ? 'hoy a las ${_hora(f)}'
      : 'el ${_fecha(f)} a las ${_hora(f)}';
}
