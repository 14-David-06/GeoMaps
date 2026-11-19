import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/app_database.dart';
import '../state/fotos.dart';

/// Las fotos de un punto marcado, y el boton para agregar otra.
///
/// Un punto dice "alcantarilla tapada"; la foto dice cuanto. Van en la
/// tarjeta del punto, a la vista: miniaturas que se tocan para verlas
/// grandes, y un boton con nombre -no un icono suelto- para tomar otra.
class FotosDelPunto extends ConsumerWidget {
  const FotosDelPunto({required this.punto, super.key});

  final Waypoint punto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fotos =
        ref.watch(fotosDelPuntoProvider(punto.codigo)).valueOrNull ?? const [];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final foto in fotos)
          _Miniatura(
            foto: foto,
            alTocar: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _VerFoto(foto: foto, punto: punto.nombre),
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => agregarFoto(context, ref, punto),
          icon: const Icon(Icons.photo_camera_outlined),
          label: Text(fotos.isEmpty ? 'Tomar foto' : 'Otra foto'),
        ),
      ],
    );
  }
}

/// Abre la camara y guarda la foto en el punto. Si la camara no abre, lo dice.
Future<void> agregarFoto(
  BuildContext context,
  WidgetRef ref,
  Waypoint punto,
) async {
  final avisos = ScaffoldMessenger.of(context);
  try {
    final foto = await ref.read(fotosProvider).tomar(punto.codigo);
    if (foto == null) return;
    avisos.showSnackBar(
      SnackBar(content: Text('Foto guardada en "${punto.nombre}".')),
    );
  } catch (_) {
    avisos.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 7),
        content: Text(
          'No se pudo abrir la camara. Revisa que GeoMaps tenga permiso de '
          'camara en los ajustes del telefono.',
        ),
      ),
    );
  }
}

class _Miniatura extends StatelessWidget {
  const _Miniatura({required this.foto, required this.alTocar});

  final Archivo foto;
  final VoidCallback alTocar;

  static const lado = 64.0;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Ver la foto',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Material(
          color: colores.surfaceContainerHighest,
          child: InkWell(
            onTap: alTocar,
            child: Stack(
              children: [
                Image.file(
                  File(foto.rutaLocal),
                  width: lado,
                  height: lado,
                  fit: BoxFit.cover,
                  // Se decodifica chica: es una miniatura, no hace falta
                  // tener en memoria la foto entera por cada una.
                  cacheWidth: 192,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: lado,
                    height: lado,
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
                // Todavia no subio: se nota sin tener que ir a Sincronizar.
                if (!foto.sincronizado)
                  Positioned(
                    right: 3,
                    bottom: 3,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.black87,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.cloud_off,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// La foto a pantalla entera, para acercarla con los dedos.
class _VerFoto extends ConsumerWidget {
  const _VerFoto({required this.foto, required this.punto});

  final Archivo foto;
  final String punto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(punto, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Borrar la foto',
            iconSize: 28,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _borrar(context, ref),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.file(
            File(foto.rutaLocal),
            errorBuilder: (_, _, _) => const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'La foto ya no esta en este telefono.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _borrar(BuildContext context, WidgetRef ref) async {
    final seguro = await showDialog<bool>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('Borrar la foto'),
        content: Text(
          foto.sincronizado
              ? 'Se borra de este telefono. La copia que ya subio queda en '
                    'la base.'
              : 'Todavia no subio, asi que no queda copia en ningun lado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogo, false),
            child: const Text('Dejarla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogo, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (seguro != true || !context.mounted) return;
    await ref.read(fotosProvider).borrar(foto.codigo);
    if (context.mounted) Navigator.pop(context);
  }
}
