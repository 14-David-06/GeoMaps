import 'package:flutter/material.dart';

/// Los colores con los que la app dice como esta algo: bien, ojo, mal.
///
/// Siempre llevan texto blanco encima, y a pleno sol. Los de la paleta de
/// Material no alcanzan: el naranja 800 con letra blanca da 3 a 1 de
/// contraste, y lo minimo para que lo lea quien no ve bien es 4,5 a 1. Estos
/// cuatro lo pasan.
abstract final class ColoresEstado {
  /// GPS preciso, con red, todo subido.
  static const bien = Color(0xFF2E7D32);

  /// Sirve pero hay que mirarlo: GPS impreciso, la sesion por vencer.
  static const aviso = Color(0xFFB45309);

  /// No anda: sin GPS, un error.
  static const mal = Color(0xFFC62828);

  /// Un dato que no es ni bueno ni malo: sin conexion, dias de sesion.
  static const neutro = Color(0xFF616161);
}

/// Los tamanos de letra de la app.
///
/// La mayoria de quienes la usan en campo son personas mayores que no ven
/// bien, asi que la escala entera sube respecto a la de Material: el texto
/// corriente va en 16 y **nada baja de 15**. Material trae renglones de 11 y
/// 12 (el pie de un campo, el subtitulo de una fila) que en un potrero no los
/// lee nadie.
///
/// Los tamanos puestos a mano en una pantalla respetan ese mismo piso.
abstract final class Letra {
  /// El piso: ningun texto que informe algo va por debajo de esto.
  static const minima = 15.0;

  /// El texto corriente.
  static const cuerpo = 16.0;

  /// Lo que se viene a leer en una tarjeta o una fila.
  static const destacada = 18.0;
}

const _letra = TextTheme(
  titleLarge: TextStyle(fontSize: 22),
  titleMedium: TextStyle(fontSize: 19),
  titleSmall: TextStyle(fontSize: 17),
  bodyLarge: TextStyle(fontSize: Letra.destacada),
  bodyMedium: TextStyle(fontSize: Letra.cuerpo),
  bodySmall: TextStyle(fontSize: Letra.minima),
  labelLarge: TextStyle(fontSize: Letra.cuerpo),
  labelMedium: TextStyle(fontSize: Letra.minima),
  labelSmall: TextStyle(fontSize: Letra.minima),
);

/// Un boton que se acierta con guantes y con el telefono en una mano. La letra
/// no se fija aca: los botones usan `labelLarge`, que ya sube con [_letra].
const _altoBoton = 52.0;
const _rellenoBoton = EdgeInsets.symmetric(horizontal: 20, vertical: 12);

/// El tema Sirius.
///
/// Dos ajustes propios de GeoMaps. La app se usa a pleno sol en un potrero,
/// asi que los controles sobre el mapa van con fondo solido y contraste alto,
/// no con la superficie translucida de Material 3: un boton semitransparente
/// sobre una imagen satelital no se ve al mediodia. Y la usa gente que no ve
/// bien: la letra y los botones son mas grandes que los de fabrica (ver
/// [Letra]).
///
/// TODO(marca): traer de sirius_agro la paleta Sirius y la Museo Slab. Mientras
/// tanto, el verde de semilla mantiene la app legible sin mentir sobre la marca.
final ThemeData temaSirius = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20)),
  textTheme: _letra,
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(64, _altoBoton),
      padding: _rellenoBoton,
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      minimumSize: const Size(64, _altoBoton),
      padding: _rellenoBoton,
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(64, _altoBoton),
      padding: _rellenoBoton,
    ),
  ),
  // Los de solo texto van en filas apretadas (la franja de grabacion, los
  // dialogos): crecen en zona de toque, no en alto dibujado.
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(minimumSize: const Size(56, 48)),
  ),
);
