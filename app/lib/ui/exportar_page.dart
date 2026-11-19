import 'package:flutter/material.dart';

import '../core/exportador.dart';

/// Elegir en que formato sale lo que se comparte.
///
/// KML para Google Earth, GPX para un GPS de mano o para topografia, GeoJSON
/// para QGIS. Sale por `share_plus`, asi que en el telefono se puede mandar por
/// WhatsApp sin pasar por el backend: en campo eso es lo que de verdad ocurre.
///
/// Con [conInforme] ofrece ademas el informe en PDF, que es de un
/// levantamiento -un area, un recorrido- y no de una lista de puntos sueltos.
///
/// Devuelve el formato elegido, o nulo si se cerro la hoja.
Future<FormatoEntrega?> elegirFormato(
  BuildContext context, {
  String? titulo,
  bool conInforme = false,
}) {
  return showModalBottomSheet<FormatoEntrega>(
    context: context,
    showDragHandle: true,
    // Con la letra agrandada son cuatro renglones altos: que se pueda bajar.
    isScrollControlled: true,
    builder: (hoja) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                titulo ?? 'Compartir como',
                style: Theme.of(hoja).textTheme.titleMedium,
              ),
            ),
            for (final f in FormatoEntrega.values)
              if (f != FormatoEntrega.pdf || conInforme)
                ListTile(
                  leading: Icon(switch (f) {
                    FormatoEntrega.kml => Icons.public,
                    FormatoEntrega.gpx => Icons.satellite_alt,
                    FormatoEntrega.geojson => Icons.data_object,
                    FormatoEntrega.pdf => Icons.picture_as_pdf_outlined,
                  }),
                  title: Text(f.titulo),
                  subtitle: Text(switch (f) {
                    FormatoEntrega.kml => 'Google Earth y QGIS',
                    FormatoEntrega.gpx => 'GPS de mano y topografia',
                    FormatoEntrega.geojson => 'QGIS, PostGIS y scripts',
                    FormatoEntrega.pdf =>
                      'Una hoja para imprimir o mandar a quien no usa mapas',
                  }),
                  onTap: () => Navigator.pop(hoja, f),
                ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
