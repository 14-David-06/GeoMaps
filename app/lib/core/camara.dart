import 'dart:io';

import 'package:image_picker/image_picker.dart';

/// La camara del telefono, para la foto de un punto marcado.
///
/// Es una interfaz para que las pantallas -y las pruebas- no sepan como se
/// abre: piden una foto y reciben un archivo, o nada si la persona cancelo.
abstract class Camara {
  /// Abre la camara y devuelve la foto, o nulo si no se tomo ninguna.
  Future<File?> tomar();

  /// La foto que quedo en el aire: en telefonos con poca memoria Android
  /// cierra la app mientras la camara esta abierta, y al volver la app
  /// arranca de cero. La foto no se pierde: se pide aca, una vez, al abrir.
  Future<File?> recuperarPerdida();
}

/// La camara de verdad, con la app de camara que traiga el telefono.
///
/// La foto se achica al tomarla: 1600 px del lado largo y calidad 80 dan
/// unos 300 a 600 KB, que es lo que una red rural sube en un tiempo
/// razonable. Tal como sale de un telefono de hoy son 5 a 12 MB, y esa foto
/// en un lote no sube nunca.
class CamaraDelTelefono implements Camara {
  const CamaraDelTelefono();

  static const ladoMaximo = 1600.0;
  static const calidad = 80;

  @override
  Future<File?> tomar() async {
    final foto = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: ladoMaximo,
      maxHeight: ladoMaximo,
      imageQuality: calidad,
      // Sin la ubicacion ni los demas datos de la foto: el punto ya dice
      // donde es, y lo que no se necesita no se guarda ni se sube.
      requestFullMetadata: false,
    );
    return foto == null ? null : File(foto.path);
  }

  @override
  Future<File?> recuperarPerdida() async {
    final perdida = await ImagePicker().retrieveLostData();
    final foto = perdida.file;
    if (perdida.isEmpty || foto == null) return null;
    return File(foto.path);
  }
}
