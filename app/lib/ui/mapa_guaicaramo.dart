import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/zona_guaicaramo.dart';
import 'mapa_page.dart';

/// El acceso al mapa de la plantacion de Guaicaramo.
///
/// **Se habilita solo estando adentro del predio.** La regla no es un permiso
/// ni una licencia: es que el mapa de un predio no sirve para nada fuera de el,
/// y mostrarlo abierto desde cualquier lado hace que alguien se lo baje -son
/// cientos de MB- en un telefono que nunca va a pisar Guaicaramo.
///
/// Lo que decide es la posicion del GPS contra el perimetro real de la
/// plantacion, que viaja adentro del APK. **No necesita red**: el predio esta a
/// una hora de la ultima antena y la respuesta tiene que llegar igual.
///
/// La tarjeta no se esconde cuando esta bloqueada. Esconderla haria que quien
/// esta llegando al predio crea que la app no tiene el mapa; deshabilitada y
/// diciendo cuanto falta, la persona sabe que existe y que le falta acercarse.
class MapaGuaicaramo extends ConsumerWidget {
  const MapaGuaicaramo({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(estadoGuaicaramoProvider);
    final colores = Theme.of(context).colorScheme;
    final abierto = estado.habilitado;

    return Material(
      color: abierto
          ? colores.primaryContainer
          : colores.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: abierto
            ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MapaPage(
                    archivoVias: 'guaicaramo-vias.json',
                    archivoParcelas: 'guaicaramo-parcelas.json',
                    archivoAcopios: 'guaicaramo-acopios.json',
                  ),
                ),
              )
            : () => _explicar(context, estado),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              _Icono(estado: estado),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mapa Guaicaramo',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: abierto
                            ? colores.onPrimaryContainer
                            : colores.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      estado.explicacion,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: abierto
                            ? colores.onPrimaryContainer.withValues(alpha: 0.8)
                            : colores.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                abierto ? Icons.chevron_right : Icons.lock_outline,
                color: abierto ? colores.onPrimaryContainer : colores.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Por que esta bloqueado, al tocarlo.
  ///
  /// Un toque en algo apagado tiene que responder algo. Si no, la persona
  /// vuelve a tocar tres veces y concluye que la app se colgo.
  void _explicar(BuildContext context, EstadoZona estado) {
    final String texto;
    switch (estado.motivo) {
      case MotivoZona.fuera:
        texto =
            'Este mapa se abre estando adentro de la plantacion. '
            '${estado.explicacion}.';
      case MotivoZona.buscandoGps:
        texto =
            'Todavia no hay senal de GPS. A cielo abierto tarda menos; '
            'bajo el dosel o adentro de un galpon puede no llegar nunca.';
      case MotivoZona.sinUbicacion:
        texto = estado.explicacion;
      case MotivoZona.sinDatos:
        texto =
            'Este APK se compilo sin los datos del predio, que son '
            'confidenciales y se piden a coordinacion. No es algo que se '
            'arregle desde el telefono.';
      case MotivoZona.dentro:
        return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(texto), duration: const Duration(seconds: 5)),
    );
  }
}

class _Icono extends StatelessWidget {
  const _Icono({required this.estado});

  final EstadoZona estado;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;

    // Mientras busca el GPS, girar. Es la unica espera de las cuatro: las otras
    // tres no se resuelven solas y un indicador ahi seria mentir.
    if (estado.motivo == MotivoZona.buscandoGps) {
      return SizedBox(
        width: 34,
        height: 34,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: colores.outline,
          ),
        ),
      );
    }

    return Icon(
      switch (estado.motivo) {
        MotivoZona.dentro => Icons.layers,
        MotivoZona.fuera => Icons.wrong_location_outlined,
        MotivoZona.sinUbicacion => Icons.gps_off,
        MotivoZona.sinDatos => Icons.layers_clear,
        MotivoZona.buscandoGps => Icons.gps_not_fixed,
      },
      size: 34,
      color: estado.habilitado ? colores.onPrimaryContainer : colores.outline,
    );
  }
}
