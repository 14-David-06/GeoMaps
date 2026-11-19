import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enlaces.dart';
import '../../state/pwa.dart';

/// En el iPhone, GeoMaps abierta en una pestana de Safari y no desde su icono.
///
/// Va antes del login a proposito. Safari y la app instalada guardan cada una
/// en su propio almacen: lo que se haga en la pestana -la sesion, los puntos,
/// las imagenes del mapa- no aparece despues en la app, y alguien que se fue
/// al lote creyendo que tenia todo guardado se encuentra con la app vacia y
/// sin senal para arreglarlo.
class AvisoInstalarPage extends ConsumerWidget {
  const AvisoInstalarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texto = Theme.of(context).textTheme;
    final colores = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text(
              'Instala GeoMaps en tu iPhone',
              style: texto.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'Asi abre sin senal en el lote, como cualquier app. Desde esta '
              'pestana de Safari no queda nada guardado para usar sin senal.',
              style: texto.bodyLarge,
            ),
            const SizedBox(height: 24),
            const _Paso(
              numero: 1,
              icono: Icons.ios_share,
              titulo: 'Toca el boton Compartir',
              detalle:
                  'Es el cuadrito con una flecha hacia arriba, abajo en el '
                  'centro de Safari.',
            ),
            const _Paso(
              numero: 2,
              icono: Icons.add_box_outlined,
              titulo: 'Elige "Agregar a pantalla de inicio"',
              detalle: 'Si no la ves, desliza la lista hacia arriba.',
            ),
            const _Paso(
              numero: 3,
              icono: Icons.check_circle_outline,
              titulo: 'Toca "Agregar"',
              detalle: 'Arriba a la derecha.',
            ),
            const _Paso(
              numero: 4,
              icono: Icons.touch_app_outlined,
              titulo: 'Abre GeoMaps desde el icono nuevo',
              detalle:
                  'La primera vez necesita senal para guardarse en el '
                  'telefono. Despues abre sin senal.',
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    Enlaces.abrir(Uri.base.resolve('instalar.html')),
                icon: const Icon(Icons.help_outline),
                label: const Text('Ver los pasos con dibujos'),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Si solo queres mirar algo rapido, podes seguir en Safari. Lo '
              'que hagas aca no pasa a la app instalada.',
              style: texto.bodyMedium?.copyWith(
                color: colores.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () =>
                    ref.read(seguirEnNavegadorProvider.notifier).state = true,
                child: const Text('Seguir en Safari sin instalar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Paso extends StatelessWidget {
  const _Paso({
    required this.numero,
    required this.icono,
    required this.titulo,
    required this.detalle,
  });

  final int numero;
  final IconData icono;
  final String titulo;
  final String detalle;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final texto = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: colores.primary,
            child: Text(
              '$numero',
              style: TextStyle(
                color: colores.onPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icono, size: 26, color: colores.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        titulo,
                        style: texto.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(detalle, style: texto.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
