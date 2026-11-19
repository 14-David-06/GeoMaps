import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import '../core/fuente_teselas.dart';
import '../core/teselas.dart';

/// Como aparece cada imagen del mapa: con un fundido corto la primera vez, y
/// **sin fundido cuando se reemplaza**. Lo usan todos los mapas de la app.
///
/// Lo segundo importa porque cada tesela puede dibujarse dos veces -primero
/// con lo guardado, despues con la que llego de la red-, y con el fundido de
/// fabrica el cambio se veria como un parpadeo de todo el mapa.
const apareceTesela = TileDisplay.fadeIn(reloadStartOpacity: 1);

/// El proveedor de imagenes del mapa base.
///
/// Reemplaza al de `flutter_map` por dos razones. Aquel pide la tesela y, si
/// no hay, deja el hueco -o muestra el cartel de "Map data not yet available"
/// que manda el satelite-; este le pide la imagen a [FuenteTeselas], que
/// cuando no existe la del nivel pedido trae la del nivel de arriba, y aca se
/// recorta el pedazo que corresponde y se lo estira. Y aquel espera a la red
/// antes de mostrar nada; este muestra primero lo que el telefono ya tiene
/// (ver [ImagenTesela]).
///
/// Usa la misma cache que antes, bajo las mismas direcciones: lo que el
/// telefono ya tenia guardado sigue sirviendo.
class ProveedorTeselas extends TileProvider {
  ProveedorTeselas(this.fuente);

  final FuenteTeselas fuente;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final imagen = ImagenTesela(
      Tesela(coordinates.z, coordinates.x, coordinates.y),
      fuente,
    );
    // Una tesela que se resolvio a medias por falta de red queda en la
    // memoria de imagenes de Flutter como si fuera la buena. Se la saca para
    // que este pedido vuelva a preguntar: si ya hay senal, ahora si llega.
    // Con la red cortada la fuente contesta que no y se sigue viendo la que
    // esta, sin rehacer nada.
    if (fuente.fueProvisional(imagen.tesela)) {
      PaintingBinding.instance.imageCache.evict(imagen);
    }
    return imagen;
  }
}

/// La imagen de una tesela, propia o prestada del nivel de arriba.
///
/// Se dibuja en dos pasos. Primero, en el acto, lo que el telefono tenga
/// guardado -la tesela aunque este vencida, o la de mas arriba estirada-; y
/// despues, si hace falta y cuando la red conteste, la de verdad. Sin senal
/// el mapa aparece igual de rapido que con senal; lo que cambia es la nitidez.
@immutable
class ImagenTesela extends ImageProvider<ImagenTesela> {
  const ImagenTesela(this.tesela, this.fuente);

  final Tesela tesela;
  final FuenteTeselas fuente;

  @override
  Future<ImagenTesela> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    ImagenTesela key,
    ImageDecoderCallback decode,
  ) => _CargaTesela(key, decode);

  /// La imagen de [cargada], lista para pintar: entera si es la de esta
  /// tesela, o el pedazo que le toca si es una de mas arriba.
  Future<ui.Image> _dibujar(
    TeselaCargada cargada,
    ImageDecoderCallback decode,
  ) async {
    if (cargada.origen == tesela) return _decodificar(cargada.bytes, decode);

    // La madre se comparte: las cuatro hijas -o las dieciseis nietas- piden
    // el mismo archivo, y decodificarlo una vez por cada una era el grueso
    // del trabajo al acercar el mapa mas alla de lo que hay guardado.
    final madre = await _madres.de(cargada.origen, cargada.bytes, decode);
    final ui.Image mia;
    try {
      mia = madre.clone();
    } catch (_) {
      // La soltaron justo ahora: se decodifica aparte y listo.
      final propia = await _decodificar(cargada.bytes, decode);
      try {
        return await _recortar(propia, cargada.origen);
      } finally {
        propia.dispose();
      }
    }
    try {
      return await _recortar(mia, cargada.origen);
    } finally {
      mia.dispose();
    }
  }

  /// El pedazo de [ancestro] que corresponde a esta tesela, estirado al
  /// tamano de una tesela.
  Future<ui.Image> _recortar(ui.Image imagen, Tesela ancestro) async {
    final lado = imagen.width.toDouble();
    final (x, y, tamano) = tesela.recorteEn(ancestro, lado: lado);
    final grabadora = ui.PictureRecorder();
    ui.Canvas(grabadora).drawImageRect(
      imagen,
      ui.Rect.fromLTWH(x, y, tamano, tamano),
      ui.Rect.fromLTWH(0, 0, lado, lado),
      // Suavizado: estirada a lo bruto, la imagen sale en cuadros y distrae
      // mas de lo que informa.
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final dibujo = grabadora.endRecording();
    try {
      return await dibujo.toImage(imagen.width, imagen.height);
    } finally {
      dibujo.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ImagenTesela &&
      other.tesela == tesela &&
      identical(other.fuente, fuente);

  @override
  int get hashCode => Object.hash(tesela, identityHashCode(fuente));
}

Future<ui.Image> _decodificar(
  Uint8List bytes,
  ImageDecoderCallback decode,
) async {
  final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// La carga de una tesela: hasta dos imagenes, la guardada y la de la red.
class _CargaTesela extends ImageStreamCompleter {
  _CargaTesela(this._llave, this._decode) {
    _correr();
  }

  final ImagenTesela _llave;
  final ImageDecoderCallback _decode;

  Future<void> _correr() async {
    final fuente = _llave.fuente;
    final tesela = _llave.tesela;

    // Paso uno: lo que hay en el telefono. No espera a nadie.
    TeselaCargada? local;
    try {
      local = await fuente.guardada(tesela);
      if (local != null && !await _mostrar(local)) return;
    } catch (_) {
      // Una copia que no se pudo leer o dibujar es como no tenerla.
      local = null;
    }
    if (local != null && !local.provisional) return;

    // Paso dos: la de verdad. Tarda lo que tarde la red, y ya no frena nada.
    await _deLaRed(local);
  }

  /// Sale a buscar la imagen de verdad. [mostrada] es la que ya se ve, si hay
  /// alguna. Si la red no alcanza, deja pedido que le avisen cuando vuelva.
  Future<void> _deLaRed(TeselaCargada? mostrada) async {
    final fuente = _llave.fuente;
    final tesela = _llave.tesela;
    try {
      final deLaRed = await fuente.cargar(tesela);
      final esLaMisma =
          mostrada != null &&
          deLaRed.origen == mostrada.origen &&
          identical(deLaRed.bytes, mostrada.bytes);
      if (!esLaMisma && !await _mostrar(deLaRed)) return;
      if (deLaRed.provisional) _esperarLaRed(deLaRed);
    } catch (error, traza) {
      // Si ya se esta viendo algo, que la red no haya contestado no es un
      // error para nadie.
      if (mostrada != null) {
        _esperarLaRed(mostrada);
        return;
      }
      reportError(
        context: ErrorDescription('al cargar una imagen del mapa'),
        exception: error,
        stack: traza,
        silent: true,
        informationCollector: () => [
          DiagnosticsProperty('Tesela', tesela),
          DiagnosticsProperty('Plantilla', fuente.plantilla),
        ],
      );
      // El hueco tambien se llena solo cuando vuelve la red, si fue por eso.
      if (fuente.quedoPendiente(tesela)) _esperarLaRed(null);
    }
  }

  /// Quedo borrosa por falta de red: cuando vuelva, se busca de nuevo. Solo
  /// si para entonces sigue en pantalla; bajar imagenes que ya nadie mira es
  /// gastarle los datos a quien esta en el lote.
  void _esperarLaRed(TeselaCargada? mostrada) {
    _llave.fuente.avisarAlVolver(_llave.tesela, () {
      if (hasListeners) _deLaRed(mostrada);
    });
  }

  /// Dibuja [cargada] y la entrega. Devuelve falso si ya nadie la espera -el
  /// mapa se movio y la tesela se descarto-: no hay para que seguir.
  Future<bool> _mostrar(TeselaCargada cargada) async {
    final imagen = await _llave._dibujar(cargada, _decode);
    try {
      setImage(ImageInfo(image: imagen));
      return true;
    } on StateError {
      imagen.dispose();
      return false;
    }
  }
}

/// Las teselas de mas arriba ya decodificadas, para no decodificar la misma
/// una vez por cada hija. Pocas: cada una son 256 KB en memoria.
class _Madres {
  static const _maximo = 12;

  final _mapa = <Tesela, _Madre>{};

  Future<ui.Image> de(
    Tesela origen,
    Uint8List bytes,
    ImageDecoderCallback decode,
  ) {
    final guardada = _mapa.remove(origen);
    if (guardada != null && identical(guardada.bytes, bytes)) {
      // Se vuelve a poner para que quede como la mas reciente.
      _mapa[origen] = guardada;
      return guardada.imagen;
    }
    // Otra version de la misma tesela (se renovo): la vieja no sirve mas.
    guardada?.soltar();

    final nueva = _Madre(bytes, _decodificar(bytes, decode));
    _mapa[origen] = nueva;
    // Si no se pudo decodificar no se guarda el fallo: la proxima reintenta.
    nueva.imagen.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_mapa[origen], nueva)) _mapa.remove(origen);
      },
    );
    while (_mapa.length > _maximo) {
      _mapa.remove(_mapa.keys.first)!.soltar();
    }
    return nueva.imagen;
  }
}

class _Madre {
  _Madre(this.bytes, this.imagen);

  final Uint8List bytes;
  final Future<ui.Image> imagen;

  /// Libera la imagen cuando termine de decodificarse. Quien la este usando
  /// tiene su propia copia (`clone`), asi que no se la lleva por delante.
  void soltar() =>
      imagen.then<void>((i) => i.dispose(), onError: (Object _) {});
}

final _madres = _Madres();

/// Un proveedor por direccion de teselas, compartido por todos los mapas de la
/// app: lo que uno aprendio -que en esta zona no hay imagen mas alla del nivel
/// 18- le sirve al otro, y no se repiten los pedidos.
ProveedorTeselas proveedorDe({
  required String plantilla,
  required String paquete,
}) {
  return _proveedores.putIfAbsent(
    plantilla,
    () => ProveedorTeselas(
      FuenteTeselas(
        plantilla: plantilla,
        paquete: paquete,
        almacen: () {
          try {
            return BuiltInMapCachingProvider.getOrCreateInstance();
          } catch (_) {
            return null;
          }
        },
      ),
    ),
  );
}

final _proveedores = <String, ProveedorTeselas>{};

/// El telefono dice que volvio la red: los mapas dejan de esperar la pausa y
/// salen a buscar las imagenes que quedaron borrosas.
void reanudarTeselas() {
  for (final proveedor in _proveedores.values) {
    proveedor.fuente.reanudar();
  }
}
