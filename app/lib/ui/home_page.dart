import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../camiones/camiones_page.dart';
import '../core/api_client.dart';
import '../core/enlaces.dart';
import '../core/ubicacion.dart';
import '../state/errores.dart';
import '../state/fotos.dart';
import '../state/proyecto_activo.dart';
import '../state/providers.dart';
import '../state/red.dart';
import '../state/sesion.dart';
import '../state/sincronizador.dart';
import '../state/ubicacion_provider.dart';
import 'actualizacion_page.dart';
import 'cerrar_sesion.dart';
import 'descargar_region_page.dart';
import 'login_page.dart';
import 'mapa_guaicaramo.dart';
import 'mapa_page.dart';
import 'proyectos_page.dart';
import 'sincronizacion_page.dart';
import 'theme.dart';

/// La primera pantalla despues de entrar.
///
/// Existe por una razon concreta: antes de caminar un lote hay tres cosas que
/// deciden si se sale o no se sale — si el GPS engancho, si hay senal para
/// bajar lo que falte, y cuantos dias le quedan a la sesion. Abrir directo en
/// el mapa esconde las tres, y el momento de enterarse de que la sesion vence
/// manana no puede ser cuando ya se esta en el potrero.
///
/// Lo segundo que hace es mostrar la app completa, con tarjetas grandes: son
/// las que se aciertan con guantes y con el telefono en una sola mano.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sesion = ref.watch(sesionProvider).sesion;
    // Lo que sube solo al volver la red. Se engancha aca porque el inicio queda
    // debajo de todas las pantallas mientras haya sesion.
    ref.watch(sincronizacionAutomaticaProvider);
    // Y lo que rescata la foto que quedo en el aire si Android cerro la app
    // con la camara abierta.
    ref.watch(fotoPerdidaProvider);
    // Solo pasa durante el parpadeo entre cerrar sesion y que la puerta
    // reemplace esta pantalla por el login.
    if (sesion == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: const Text('GeoMaps'),
        actions: [
          IconButton(
            tooltip: 'Mi cuenta',
            onPressed: () => _mostrarCuenta(context, ref),
            icon: _Avatar(foto: sesion.foto, nombre: sesion.nombre),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Saludo(nombre: sesion.nombre),
            const SizedBox(height: 16),
            const AvisoActualizacion(),
            if (sesion.vencida) const _SesionVencida(),
            const _Estado(),
            const SizedBox(height: 24),
            Text(
              'Que vas a hacer',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            const _Accesos(),
            const SizedBox(height: 24),
            Text(
              'Mapas del predio',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            const MapaGuaicaramo(),
          ],
        ),
      ),
    );
  }

  /// Quien esta conectado y cuanto le queda de sesion.
  ///
  /// Los dias restantes se muestran porque son el dato que decide si alguien
  /// puede salir tranquilo a una semana de campo. Enterarse de que la sesion
  /// vencio estando en el lote es justo lo que hay que evitar.
  void _mostrarCuenta(BuildContext context, WidgetRef ref) {
    final sesion = ref.read(sesionProvider).sesion;
    if (sesion == null) return;

    showModalBottomSheet<void>(
      context: context,
      // Con el telefono acostado la hoja topa en 9/16 del alto, y sin esto
      // "Eliminar mi cuenta" quedaba cortada abajo sin forma de llegar a ella.
      isScrollControlled: true,
      builder: (hoja) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: _Avatar(foto: sesion.foto, nombre: sesion.nombre),
                title: Text(sesion.nombre),
                subtitle: Text(sesion.correo),
              ),
              const Divider(height: 1),
              if (sesion.vencida)
                ListTile(
                  leading: const Icon(Icons.lock_clock),
                  title: const Text('La sesion vencio'),
                  subtitle: const Text(
                    'Podes seguir trabajando en este telefono. Para subir lo '
                    'que hagas, toca aca y entra de nuevo con senal.',
                  ),
                  onTap: () {
                    Navigator.pop(hoja);
                    LoginPage.abrirParaReingresar(context);
                  },
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
                leading: const Icon(Icons.manage_accounts_outlined),
                title: const Text('Actualizar mi cuenta'),
                subtitle: const Text(
                  'Trae los permisos que te hayan asignado. Necesita senal.',
                ),
                onTap: () async {
                  Navigator.pop(hoja);
                  final avisos = ScaffoldMessenger.of(context);
                  final ok = await ref
                      .read(sesionProvider.notifier)
                      .renovar(forzar: true);
                  avisos.showSnackBar(
                    SnackBar(
                      content: Text(
                        ok
                            ? 'Cuenta actualizada.'
                            : 'No se pudo actualizar. Revisa la senal y '
                                  'volve a intentar.',
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Politica de privacidad'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => Enlaces.abrir(Enlaces.privacidad),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Cerrar sesion'),
                onTap: () {
                  Navigator.pop(hoja);
                  cerrarSesion(context, ref);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_forever,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Eliminar mi cuenta',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () {
                  Navigator.pop(hoja);
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const _DialogoBaja(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirmar la baja de la cuenta. Play exige que se pueda hacer desde la app.
///
/// Dice que tambien se pierde lo que no se sincronizo porque es lo que de
/// verdad no se recupera: lo subido se borra igual, pero eso la persona ya lo
/// esta pidiendo.
class _DialogoBaja extends ConsumerStatefulWidget {
  const _DialogoBaja();

  @override
  ConsumerState<_DialogoBaja> createState() => _DialogoBajaState();
}

class _DialogoBajaState extends ConsumerState<_DialogoBaja> {
  bool _borrando = false;
  String? _error;

  Future<void> _eliminar() async {
    setState(() {
      _borrando = true;
      _error = null;
    });
    try {
      final errores = ref.read(registroErroresProvider);
      final archivos = ref.read(archivosRepositoryProvider);
      await ref
          .read(sesionProvider.notifier)
          .eliminarCuenta(ref.read(dbProvider));
      // Lo guardado en el telefono se va con la cuenta, y los informes de
      // error tambien: el servidor ya borro los que habian subido.
      await errores?.vaciar();
      await archivos.borrarArchivosDeFotos();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _borrando = false;
        _error = e is ApiError
            ? e.mensaje
            : 'No se pudo conectar. Busca senal y volve a intentar.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Eliminar tu cuenta'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Se borran tu cuenta y tus recorridos y poligonos, en el servidor '
            'y en este telefono. Lo que todavia no sincronizaste tambien se '
            'pierde. No se puede deshacer.',
          ),
          if (_borrando) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: colores.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _borrando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colores.error,
            foregroundColor: colores.onError,
          ),
          onPressed: _borrando ? null : _eliminar,
          child: const Text('Eliminar'),
        ),
      ],
    );
  }
}

/// El aviso de que la sesion vencio.
///
/// Va arriba y pintado porque cambia lo que la persona puede esperar de la
/// jornada: todo lo que haga queda en el telefono y nada sube. Dice las dos
/// cosas que hay que saber -que puede seguir, y que hace falta para subir- y
/// tiene el boton ahi mismo, porque el rato con senal es corto.
class _SesionVencida extends StatelessWidget {
  const _SesionVencida();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        // Solido y no translucido, como los avisos de estado: se lee al sol.
        color: ColoresEstado.aviso,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.lock_clock, color: Colors.white),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Tu sesion vencio',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Podes seguir trabajando: todo queda guardado en este '
                'telefono. Para subirlo, entra de nuevo cuando tengas senal.',
                style: TextStyle(color: Colors.white, height: 1.35),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: ColoresEstado.aviso,
                  ),
                  onPressed: () => LoginPage.abrirParaReingresar(context),
                  icon: const Icon(Icons.login),
                  label: const Text('Entrar de nuevo'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Saludo extends StatelessWidget {
  const _Saludo({required this.nombre});

  final String nombre;

  @override
  Widget build(BuildContext context) {
    // Solo el primer nombre: "Hola, David Hernandez Ramirez" ocupa dos
    // renglones en un telefono angosto y no dice nada mas.
    final partes = nombre.trim().split(RegExp(r'\s+'));
    final primero = partes.first.isEmpty ? nombre : partes.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hola, $primero',
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          'Tus mapas del predio, sin senal',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// La tira de estado: GPS, red y sesion.
///
/// Los tres a la vista y siempre. Son lo que hay que mirar antes de salir, y un
/// dato que hay que ir a buscar a un menu es un dato que nadie mira.
class _Estado extends ConsumerWidget {
  const _Estado();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posicion = ref.watch(posicionProvider);
    final red = ref.watch(redProvider);
    final sesion = ref.watch(sesionProvider).sesion;

    final gps = posicion.when(
      data: (p) => Ubicacion.esDeCache(p)
          ? _Chip(
              icono: Icons.gps_not_fixed,
              texto: 'GPS: ${Ubicacion.hace(p)}',
              color: ColoresEstado.aviso,
            )
          : _Chip(
              icono: Icons.gps_fixed,
              texto: '+/- ${p.accuracy.toStringAsFixed(0)} m',
              // El umbral no es cosmetico: por encima de 10 m el punto no sirve para
              // marcar un vertice de lindero.
              color: p.accuracy <= 10
                  ? ColoresEstado.bien
                  : ColoresEstado.aviso,
            ),
      loading: () => _Chip(
        icono: Icons.gps_not_fixed,
        texto: 'Buscando GPS',
        color: ColoresEstado.aviso,
      ),
      error: (e, _) => _Chip(
        icono: Icons.gps_off,
        texto: 'GPS sin senal',
        color: ColoresEstado.mal,
      ),
    );

    final estadoRed = red.maybeWhen(
      data: (r) => _Chip(
        icono: r.hayRed ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
        texto: r.etiqueta,
        color: r.hayRed ? ColoresEstado.bien : ColoresEstado.neutro,
      ),
      orElse: () => _Chip(
        icono: Icons.cloud_queue,
        texto: 'Revisando',
        color: ColoresEstado.neutro,
      ),
    );

    final dias = sesion?.diasRestantes ?? 0;
    final estadoSesion = sesion?.vencida ?? false
        ? const _Chip(
            icono: Icons.lock_clock,
            texto: 'Sesion vencida',
            color: ColoresEstado.aviso,
          )
        : _Chip(
            icono: Icons.schedule,
            texto: dias == 1 ? '1 dia' : '$dias dias',
            // Por debajo de una semana hay que avisar, antes de que alguien
            // salga a una semana de campo creyendo que tiene mes.
            color: dias <= 7 ? ColoresEstado.aviso : ColoresEstado.neutro,
          );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [gps, estadoRed, estadoSesion],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icono, required this.texto, required this.color});

  final IconData icono;
  final String texto;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        // Fondo solido y no translucido: la app se usa a pleno sol.
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 20, color: Colors.white),
          const SizedBox(width: 6),
          // Flexible: un aviso largo ("GPS: hace 12 minutos") con la letra
          // agrandada baja de renglon en vez de salirse de la pantalla.
          Flexible(
            child: Text(
              texto,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// La grilla de accesos.
class _Accesos extends ConsumerWidget {
  const _Accesos();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sesion = ref.watch(sesionProvider).sesion;
    final cuantos = sesion == null
        ? const AsyncValue<int>.loading()
        : ref.watch(cantidadProyectosProvider(sesion.authUid));

    // Lo comun (mapa, sincronizar) lo ve todo el mundo; lo de cada modulo,
    // solo quien tiene el perfil. Cada tarjeta nueva decide aca de cual es.
    final plantacion = sesion?.tiene(Perfil.plantacion) ?? true;
    final camiones = sesion?.tiene(Perfil.camiones) ?? false;

    return LayoutBuilder(
      builder: (context, medidas) => GridView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: _separacion,
          crossAxisSpacing: _separacion,
          mainAxisExtent: _altoTarjeta(context, medidas.maxWidth),
        ),
        children: _tarjetas(context, ref, cuantos, plantacion, camiones),
      ),
    );
  }

  static const _separacion = 12.0;

  /// El alto de cada tarjeta.
  ///
  /// Un poco mas altas que anchas, como siempre. Pero el alto no puede salir
  /// solo del ancho: con la letra del telefono agrandada el titulo y el
  /// detalle crecen y el ancho no, y la tarjeta se quedaba corta. Asi que
  /// nunca es menos que lo que ocupa lo que lleva adentro.
  static double _altoTarjeta(BuildContext context, double anchoGrilla) {
    final letra = MediaQuery.textScalerOf(context);
    final ancho = (anchoGrilla - _separacion) / 2;
    final contenido =
        _Tarjeta.relleno * 2 +
        _Tarjeta.ladoIcono +
        12 +
        letra.scale(_Tarjeta.letraTitulo) * 1.35 +
        2 +
        letra.scale(_Tarjeta.letraDetalle) * 1.4 * 2;
    final proporcion = ancho / 0.95;
    return contenido > proporcion ? contenido : proporcion;
  }

  List<Widget> _tarjetas(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<int> cuantos,
    bool plantacion,
    bool camiones,
  ) {
    return [
      _Tarjeta(
        icono: Icons.map,
        titulo: 'Mapa',
        detalle: 'Ver donde estoy',
        destacada: true,
        alTocar: () => _ir(context, const MapaPage()),
      ),
      if (camiones)
        _Tarjeta(
          icono: Icons.local_shipping_outlined,
          titulo: 'Camiones',
          detalle: 'Herramientas de transporte',
          alTocar: () => _ir(context, const CamionesPage()),
        ),
      if (plantacion)
        _Tarjeta(
          icono: Icons.folder_outlined,
          titulo: 'Proyectos',
          // El que esta en uso, si hay: es donde va a caer lo que se
          // levante hoy, y conviene verlo antes de salir.
          detalle:
              ref.watch(proyectoActivoProvider).valueOrNull?.nombre ??
              cuantos.maybeWhen(
                data: (n) => n == 1 ? '1 proyecto' : '$n proyectos',
                orElse: () => 'Abrir',
              ),
          alTocar: () => _ir(context, const ProyectosPage()),
        ),
      if (plantacion)
        _Tarjeta(
          icono: Icons.download_outlined,
          titulo: 'Descargas',
          detalle: 'Mapas sin senal',
          alTocar: () => _ir(context, const DescargarRegionPage()),
        ),
      _Tarjeta(
        icono: Icons.sync,
        titulo: 'Sincronizar',
        detalle: switch (ref.watch(pendientesProvider).valueOrNull ?? 0) {
          0 => 'Todo arriba',
          1 => '1 pendiente',
          final n => '$n pendientes',
        },
        alTocar: () => _ir(context, const SincronizacionPage()),
      ),
    ];
  }

  void _ir(BuildContext context, Widget pagina) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => pagina));
  }
}

class _Tarjeta extends StatelessWidget {
  const _Tarjeta({
    required this.icono,
    required this.titulo,
    required this.detalle,
    required this.alTocar,
    this.destacada = false,
  });

  final IconData icono;
  final String titulo;
  final String detalle;
  final VoidCallback alTocar;

  /// La accion principal va pintada. En una grilla de cuatro iguales todas
  /// pesan lo mismo, y la que se usa el noventa por ciento de las veces se
  /// pierde entre las otras tres.
  final bool destacada;

  // Las medidas de la tarjeta, que tambien usa la grilla para darle el alto.
  static const relleno = 18.0;
  static const ladoIcono = 36.0;
  static const letraTitulo = 20.0;
  static const letraDetalle = 15.0;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final fondo = destacada
        ? colores.primaryContainer
        : colores.surfaceContainerHighest;
    final tinta = destacada ? colores.onPrimaryContainer : colores.onSurface;

    return Material(
      color: fondo,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: alTocar,
        child: Padding(
          padding: const EdgeInsets.all(relleno),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icono, size: ladoIcono, color: tinta),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // El titulo es una sola palabra: si con la letra agrandada
                  // no entra, se achica hasta entrar en vez de partirse en
                  // "Sincroniza" y "r".
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      titulo,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: letraTitulo,
                        fontWeight: FontWeight.w700,
                        color: tinta,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Dos renglones: "Herramientas de transporte" no entra en
                  // uno y cortado con puntos no dice nada.
                  Text(
                    detalle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: letraDetalle,
                      height: 1.25,
                      color: tinta,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.foto, required this.nombre});

  final String? foto;
  final String nombre;

  @override
  Widget build(BuildContext context) {
    // La inicial va siempre, y la foto encima cuando carga. La foto es la de
    // Google y vive en internet: sin senal no llega, y un circulo vacio no
    // dice de quien es la cuenta. Un icono generico tampoco: hace que todas
    // se vean iguales en un telefono que pasa de mano en mano.
    final limpio = nombre.trim();
    final inicial = limpio.isEmpty ? '?' : limpio[0].toUpperCase();
    final foto = this.foto;
    return CircleAvatar(
      radius: 16,
      foregroundImage: foto == null ? null : NetworkImage(foto),
      // Que la foto no baje no es un error: queda la inicial.
      onForegroundImageError: foto == null ? null : (_, _) {},
      child: Text(inicial),
    );
  }
}

/// Cuantos proyectos activos tiene la cuenta, para el contador de la tarjeta.
final cantidadProyectosProvider = StreamProvider.autoDispose
    .family<int, String>((ref, authUid) {
      return ref.watch(proyectosRepositoryProvider).contarActivos(authUid);
    });
