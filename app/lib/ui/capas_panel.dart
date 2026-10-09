import 'package:flutter/material.dart';

import 'capa_acopios.dart' show colorAcopio;
import 'capa_vias.dart' show LeyendaVias;
import 'mapa_page.dart' show CapaBase;

/// Las capas del predio que se encienden y apagan desde el panel.
///
/// Agregar una capa nueva es agregar un valor aca y su dibujo en `MapaPage`:
/// el panel se arma solo con lo que haya, y la pantalla del mapa no suma un
/// boton flotante por capa. Con tres capas la columna de botones ya tapaba
/// medio costado del mapa, y no se sabia cual era cual sin leer el tooltip.
enum CapaPredio {
  lotes('Lotes', 'Bloques y parcelas', Icons.grid_on),
  vias('Vias', 'Pavimentadas, balastradas y proyectadas', Icons.route),
  acopios(
    'Acopios',
    'Tocalos en el mapa para trazar la ruta',
    Icons.inventory_2,
  );

  const CapaPredio(this.titulo, this.detalle, this.icono);

  final String titulo;
  final String detalle;
  final IconData icono;
}

/// El panel de capas: el mapa de fondo, las capas del predio y los planos.
///
/// Es una hoja que sube desde abajo y no una pantalla aparte: se abre, se
/// apaga algo y se ve el efecto en el mapa de atras sin perder el lugar.
///
/// Lo que cambia se avisa con callbacks y el panel se redibuja con lo que le
/// pase quien lo abrio: el estado de las capas vive en el mapa, no aca.
class PanelCapas extends StatelessWidget {
  const PanelCapas({
    required this.base,
    required this.onBase,
    required this.capas,
    required this.visibles,
    required this.onCapa,
    required this.cuantos,
    required this.planos,
    required this.verPlanos,
    required this.onPlanos,
    required this.onAdministrarPlanos,
    this.onBuscarAcopio,
    super.key,
  });

  final CapaBase base;
  final ValueChanged<CapaBase> onBase;

  /// Las capas que tiene este predio. Un mapa sin predio no tiene ninguna.
  final List<CapaPredio> capas;
  final Set<CapaPredio> visibles;
  final void Function(CapaPredio capa, bool ver) onCapa;

  /// Cuantos elementos tiene cada capa, para el subtitulo.
  final Map<CapaPredio, int> cuantos;

  /// Cuantos planos importados hay encendidos en la pantalla de planos.
  final int planos;
  final bool verPlanos;
  final ValueChanged<bool> onPlanos;
  final VoidCallback onAdministrarPlanos;

  /// Nulo si el predio no tiene acopios.
  final VoidCallback? onBuscarAcopio;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Titulo('Mapa de fondo'),
            SegmentedButton<CapaBase>(
              segments: [
                for (final c in CapaBase.values)
                  ButtonSegment(
                    value: c,
                    icon: Icon(c.icono),
                    label: Text(c.titulo),
                  ),
              ],
              selected: {base},
              showSelectedIcon: false,
              onSelectionChanged: (s) => onBase(s.first),
            ),
            if (capas.isNotEmpty) ...[
              const SizedBox(height: 12),
              const _Titulo('Capas del predio'),
              for (final capa in capas) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    capa.icono,
                    color: capa == CapaPredio.acopios ? colorAcopio : null,
                  ),
                  title: Text(
                    cuantos[capa] == null
                        ? capa.titulo
                        : '${capa.titulo} (${cuantos[capa]})',
                  ),
                  subtitle: Text(capa.detalle),
                  value: visibles.contains(capa),
                  onChanged: (v) => onCapa(capa, v),
                ),
                // La leyenda de las vias va pegada a su interruptor: es donde
                // se mira al preguntarse que es la linea gris punteada.
                if (capa == CapaPredio.vias && visibles.contains(capa))
                  const Padding(
                    padding: EdgeInsets.only(left: 40, bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: LeyendaVias(),
                    ),
                  ),
                if (capa == CapaPredio.acopios && onBuscarAcopio != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 40, bottom: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: onBuscarAcopio,
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('Buscar un acopio'),
                      ),
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 12),
            const _Titulo('Planos importados'),
            if (planos > 0)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.map),
                title: Text('Ver los planos ($planos)'),
                subtitle: const Text('Se apagan todos juntos'),
                value: verPlanos,
                onChanged: onPlanos,
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.upload_file),
              title: Text(
                planos > 0 ? 'Administrar planos' : 'Importar un plano',
              ),
              subtitle: Text(
                'PDF de topografia encima del mapa',
                style: TextStyle(color: colores.outline),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: onAdministrarPlanos,
            ),
          ],
        ),
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        texto.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
