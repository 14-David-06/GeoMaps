import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Avisa cuanto mide lo que tiene adentro, cada vez que cambia de tamano.
///
/// Es para acomodar una cosa alrededor de otra cuyo alto no se sabe de
/// antemano. En el mapa, los botones van arriba de la tarjeta de abajo, y esa
/// tarjeta mide una cosa con la letra normal y casi el doble con la letra del
/// telefono agrandada: con un numero fijo, los botones quedaban tapados justo
/// para quien menos ve.
///
/// El aviso llega despues de dibujar el cuadro, no en medio de el, asi que
/// quien lo recibe puede redibujarse.
class Medido extends SingleChildRenderObjectWidget {
  const Medido({required this.alMedir, required Widget super.child, super.key});

  final ValueChanged<Size> alMedir;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMedido(alMedir);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderMedido).alMedir = alMedir;
  }
}

class _RenderMedido extends RenderProxyBox {
  _RenderMedido(this.alMedir);

  ValueChanged<Size> alMedir;
  Size? _avisado;

  @override
  void performLayout() {
    super.performLayout();
    final medida = size;
    if (medida == _avisado) return;
    _avisado = medida;
    // Despues del cuadro: en medio del layout no se puede pedir un redibujo.
    WidgetsBinding.instance.addPostFrameCallback((_) => alMedir(medida));
  }
}
