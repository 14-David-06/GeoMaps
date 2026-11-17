import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/version_app.dart';
import '../state/actualizacion.dart';
import '../state/providers.dart';
import 'theme.dart';

/// La pantalla que reemplaza a toda la app cuando la version ya no sirve.
///
/// No tiene salida a proposito: no hay volver ni "mas tarde". Lo unico que
/// ofrece es actualizar, y dice en claro lo que mas preocupa en ese momento —
/// que lo guardado en el telefono no se pierde.
class ActualizacionPage extends ConsumerWidget {
  const ActualizacionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(actualizacionProvider);
    final local = ref.watch(versionLocalProvider);
    final p = estado.publicada;
    final colores = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
          children: [
            Icon(Icons.system_update, size: 64, color: colores.primary),
            const SizedBox(height: 20),
            Text(
              'Hay que actualizar GeoMaps',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              p == null
                  ? 'Esta version ya no se puede usar.'
                  : 'Tenes la ${local?.nombre ?? 'anterior'} y la vigente es '
                        'la ${p.versionNombre}.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colores.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            _Tranquilidad(colores: colores),
            if (p != null && p.notas.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Que trae', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(p.notas, style: const TextStyle(height: 1.4)),
            ],
            const SizedBox(height: 32),
            const BotonActualizar(),
          ],
        ),
      ),
    );
  }
}

class _Tranquilidad extends StatelessWidget {
  const _Tranquilidad({required this.colores});

  final ColorScheme colores;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colores.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.verified_user_outlined,
            color: colores.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Tus trazados, puntos y fotos se quedan en el telefono. La '
              'version nueva se instala encima y los encuentra ahi, incluso '
              'lo que todavia no subiste.',
              style: TextStyle(
                color: colores.onSecondaryContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// El boton con su progreso y sus errores. Lo usan la pantalla de bloqueo y
/// el aviso del inicio.
class BotonActualizar extends ConsumerWidget {
  const BotonActualizar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(actualizacionProvider);
    final notifier = ref.read(actualizacionProvider.notifier);
    final desdePlay = ref.watch(versionLocalProvider)?.desdePlay ?? false;
    // El tamano es el del APK del bucket; Play baja otra cosa, mas chica.
    final tamano = desdePlay ? '' : estado.publicada?.tamanoLegible ?? '';
    final colores = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (estado.descargando) ...[
          LinearProgressIndicator(
            value: estado.progreso == null ? null : estado.progreso! / 100,
          ),
          const SizedBox(height: 8),
          Text(
            'Descargando${estado.progreso == null ? '' : ' ${estado.progreso}%'}'
            '${tamano.isEmpty ? '' : ' de $tamano'}',
            textAlign: TextAlign.center,
          ),
        ] else
          FilledButton.icon(
            onPressed: estado.verificando ? null : notifier.actualizar,
            icon: Icon(desdePlay ? Icons.shop : Icons.download),
            label: Text(
              desdePlay
                  ? 'Actualizar en Play Store'
                  : tamano.isEmpty
                  ? 'Actualizar'
                  : 'Actualizar ($tamano)',
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        if (estado.instalando && !estado.descargando) ...[
          const SizedBox(height: 8),
          Text(
            'Si cerraste el instalador sin terminar, toca Actualizar otra vez.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colores.onSurfaceVariant),
          ),
        ],
        if (estado.error != null) ...[
          const SizedBox(height: 12),
          Text(
            estado.error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: colores.error),
          ),
        ],
      ],
    );
  }
}

/// El aviso del inicio durante los dias de gracia.
///
/// Dice cuantos dias quedan porque es lo que decide si se actualiza ahora, con
/// el wifi de la oficina, o se sale al campo y se bloquea alla sin senal.
class AvisoActualizacion extends ConsumerWidget {
  const AvisoActualizacion({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(actualizacionProvider);
    final p = estado.publicada;
    if (estado.estado != EstadoVersion.desactualizada || p == null) {
      return const SizedBox.shrink();
    }

    final dias = estado.diasParaBloqueo;
    final plazo = dias <= 1 ? 'en menos de un dia' : 'en $dias dias';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        // Solido y no translucido, como los chips de estado: se lee a pleno
        // sol.
        color: ColoresEstado.aviso,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Version ${p.versionNombre} disponible',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Esta version deja de funcionar $plazo. Actualiza antes de '
                'salir al campo; no se pierde nada de lo guardado.',
                style: const TextStyle(color: Colors.white, height: 1.35),
              ),
              const SizedBox(height: 12),
              Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: Theme.of(context).colorScheme.copyWith(
                    primary: Colors.white,
                    onPrimary: ColoresEstado.aviso,
                    error: Colors.white,
                    onSurfaceVariant: Colors.white,
                  ),
                ),
                child: const DefaultTextStyle(
                  style: TextStyle(color: Colors.white),
                  child: BotonActualizar(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
