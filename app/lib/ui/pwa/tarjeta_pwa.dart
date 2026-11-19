import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/pwa.dart';
import '../../state/pwa.dart';
import '../../state/red.dart';
import '../theme.dart';

/// Lo que la app web (la del iPhone) tiene que decir en el inicio, de mayor a
/// menor urgencia: que no se pudo guardar, que se esta guardando, que hay una
/// version nueva, que se esta en Safari y no en la app, o que no hay senal y
/// con que se esta trabajando.
///
/// Solo existe en el navegador: en Android el inicio no cambia.
class TarjetaPwa extends ConsumerStatefulWidget {
  const TarjetaPwa({super.key});

  @override
  ConsumerState<TarjetaPwa> createState() => _TarjetaPwaState();
}

class _TarjetaPwaState extends ConsumerState<TarjetaPwa> {
  /// Se la vio guardarse en esta sesion: al terminar se dice "Listo" una vez,
  /// que es la confirmacion que espera quien la instalo para irse al lote.
  bool _vioGuardar = false;
  bool _listoVisto = false;
  bool _actualizando = false;

  @override
  Widget build(BuildContext context) {
    final pwa = ref.watch(estadoPwaProvider);
    final sinRed = ref
        .watch(redProvider)
        .maybeWhen(data: (r) => !r.hayRed, orElse: () => false);
    if (pwa.guardando) _vioGuardar = true;

    if (pwa.error != null && !pwa.listaSinSenal) {
      return _Aviso(
        color: ColoresEstado.aviso,
        icono: Icons.warning_amber_rounded,
        titulo: 'Todavia no funciona sin senal',
        detalle: pwa.error!,
      );
    }

    if (pwa.guardando && !pwa.listaSinSenal) {
      final porcentaje = (pwa.progreso * 100).clamp(0, 100).round();
      return _Aviso(
        color: ColoresEstado.neutro,
        icono: Icons.downloading,
        titulo: 'Guardando GeoMaps en el telefono: $porcentaje %',
        detalle: 'No cierres la app hasta que termine. Despues abre sin senal.',
        abajo: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pwa.progreso,
              minHeight: 12,
              color: Colors.white,
              backgroundColor: Colors.white24,
            ),
          ),
        ),
      );
    }

    if (pwa.actualizacion) {
      return _Aviso(
        color: ColoresEstado.bien,
        icono: Icons.system_update,
        titulo: 'Hay una version nueva de GeoMaps',
        detalle:
            'Actualiza cuando no estes en un recorrido. Lo que tenes guardado '
            'no se pierde.',
        abajo: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: ColoresEstado.bien,
            ),
            onPressed: _actualizando ? null : _actualizar,
            child: Text(_actualizando ? 'Actualizando...' : 'Actualizar ahora'),
          ),
        ),
      );
    }

    if (pwa.esIphone && !pwa.instalada) {
      return const _Aviso(
        color: ColoresEstado.aviso,
        icono: Icons.ios_share,
        titulo: 'Estas en Safari, no en la app',
        detalle:
            'Lo que hagas aca no queda en la app instalada ni funciona sin '
            'senal. Instalala con Compartir y "Agregar a pantalla de inicio".',
      );
    }

    if (pwa.listaSinSenal && sinRed) {
      final cuando = pwa.guardadaEl;
      return _Aviso(
        color: ColoresEstado.neutro,
        icono: Icons.cloud_off_outlined,
        titulo: 'Sin senal: usando lo guardado en el telefono',
        detalle: cuando == null
            ? 'El mapa, los acopios y las rutas funcionan igual. Lo que '
                  'marques sube solo cuando vuelva la senal.'
            : 'GeoMaps guardada el ${fechaCorta(cuando)}. El mapa, los '
                  'acopios y las rutas funcionan igual; lo que marques sube '
                  'solo cuando vuelva la senal.',
      );
    }

    if (pwa.listaSinSenal && _vioGuardar && !_listoVisto) {
      return _Aviso(
        color: ColoresEstado.bien,
        icono: Icons.offline_pin_outlined,
        titulo: 'Listo. Ya podes usar GeoMaps sin senal',
        detalle:
            'Quedo guardada en el telefono: abrila desde el icono aunque no '
            'haya senal.',
        abajo: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => setState(() => _listoVisto = true),
            child: const Text('Entendido'),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Future<void> _actualizar() async {
    setState(() => _actualizando = true);
    final ok = await Pwa.actualizar();
    // Si se aplico, la pagina se recarga sola y esto no se ve.
    if (!mounted || ok) return;
    setState(() => _actualizando = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No se pudo actualizar ahora. Proba de nuevo con senal.'),
      ),
    );
  }
}

/// "19 de noviembre". Sin depender de que el navegador tenga los nombres de
/// los meses en espanol.
String fechaCorta(DateTime f) {
  const meses = [
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];
  final local = f.toLocal();
  return '${local.day} de ${meses[local.month - 1]}';
}

class _Aviso extends StatelessWidget {
  const _Aviso({
    required this.color,
    required this.icono,
    required this.titulo,
    required this.detalle,
    this.abajo,
  });

  final Color color;
  final IconData icono;
  final String titulo;
  final String detalle;
  final Widget? abajo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        // Solido, como los demas avisos de estado: se lee al sol.
        color: color,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icono, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      titulo,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                detalle,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              ?abajo,
            ],
          ),
        ),
      ),
    );
  }
}
