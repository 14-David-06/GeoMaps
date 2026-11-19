import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'core/errores.dart';
import 'core/version_app.dart';
import 'platform/pwa.dart';
import 'state/actualizacion.dart';
import 'state/aviso_ubicacion.dart';
import 'state/errores.dart';
import 'state/providers.dart';
import 'state/pwa.dart';
import 'state/sesion.dart';
import 'ui/actualizacion_page.dart';
import 'ui/aviso_ubicacion_page.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';
import 'ui/pwa/aviso_instalar_page.dart';
import 'ui/theme.dart';

/// Punto de entrada.
///
/// Nada en el arranque puede esperar una respuesta del backend: si el telefono
/// abre en un lote sin senal, la sesion guardada y los trazados de ayer tienen
/// que estar ahi.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // La app del iPhone: el estado del service worker, y la letra empaquetada
    // antes del primer cuadro (sin ella, sin senal abre sin letras).
    Pwa.arrancar();
    await Pwa.cargarFuentes();
  }
  final version = await _versionLocal();
  // Antes que todo lo demas: lo que falle de aca en adelante queda anotado.
  final errores = await _prepararErrores(version);
  // TODO: abrir la base drift y sembrar en el primer arranque.
  await _prepararCacheMapa();
  runApp(
    ProviderScope(
      overrides: [
        versionLocalProvider.overrideWithValue(version),
        registroErroresProvider.overrideWithValue(errores),
      ],
      child: const GeoMapsApp(),
    ),
  );
}

/// El cuaderno de errores, en la carpeta de la app que Android no vacia. Sin
/// carpeta no hay cuaderno, y la app abre igual.
Future<RegistroErrores?> _prepararErrores(VersionLocal? version) async {
  try {
    return await engancharErrores(
      await getApplicationSupportDirectory(),
      version,
    );
  } catch (_) {
    return null;
  }
}

/// Cache en disco de las teselas del mapa base (satelite y calles).
///
/// flutter_map ya cachea por defecto, pero con dos problemas para el campo:
///
/// - **Vigencia.** Respeta el `max-age` del servidor, y Esri manda un dia. Una
///   tesela vencida se vuelve a pedir, y si no hay red flutter_map no cae a la
///   copia vieja: deja el hueco. Por eso el mapa salia a medias sin senal. Con
///   la vigencia larga, sin red se usa lo guardado; con red, pasados los 60
///   dias se revalida con el ETag, que cuesta casi nada si la imagen no cambio.
/// - **Carpeta.** La de por defecto es la de cache del sistema, que Android
///   vacia cuando le falta espacio. La de soporte de la app no la toca.
///
/// Tiene que correr antes del primer mapa: la configuracion solo se toma al
/// crear la instancia.
Future<void> _prepararCacheMapa() async {
  try {
    final carpeta = await getApplicationSupportDirectory();
    BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: carpeta.path,
      maxCacheSize: 2000000000,
      overrideFreshAge: const Duration(days: 60),
    );
  } catch (_) {
    // Sin carpeta propia queda la cache por defecto de flutter_map: peor sin
    // senal, pero el mapa abre.
  }
}

/// La version de este APK, leida del propio APK: no toca la red. Si no se
/// puede leer, la app arranca igual y simplemente no se bloquea.
Future<VersionLocal?> _versionLocal() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final code = int.tryParse(info.buildNumber);
    if (code == null) return null;
    return VersionLocal(
      code: code,
      nombre: info.version,
      desdePlay: info.installerStore == 'com.android.vending',
    );
  } catch (_) {
    return null;
  }
}

class GeoMapsApp extends StatelessWidget {
  const GeoMapsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoMaps',
      theme: temaSirius,
      debugShowCheckedModeBanner: false,
      home: const _Puerta(),
    );
  }
}

/// Decide entre actualizar, login y home.
///
/// La decision se toma contra la sesion **guardada**, sin red. Pedir login en un
/// potrero es pedirle a alguien que no trabaje: por eso una sesion vencida
/// tambien entra. El inicio le avisa que nada va a subir hasta que vuelva a
/// entrar con senal, y la deja seguir con lo que tiene en el telefono.
///
/// Una version bloqueada va antes que todo, con sesion o sin ella: lo que se
/// hiciera en ella despues no podria sincronizarse.
class _Puerta extends ConsumerWidget {
  const _Puerta();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(actualizacionProvider.select((e) => e.estado));
    if (version == EstadoVersion.bloqueada) return const ActualizacionPage();

    // En el iPhone, abierta desde Safari y no desde el icono: lo que se guarde
    // en la pestana no pasa a la app instalada. Primero se instala.
    if (kIsWeb &&
        !ref.watch(seguirEnNavegadorProvider) &&
        ref.watch(estadoPwaProvider.select((e) => e.esIphone && !e.instalada))) {
      return const AvisoInstalarPage();
    }

    final estado = ref.watch(sesionProvider);

    // Solo mientras se lee el almacen seguro al arrancar. Dura milisegundos.
    // Un intento de entrar no pasa por aca: el ingreso se queda en pantalla
    // con lo que la persona escribio, por si hay que corregir la clave.
    if (estado.arrancando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (estado.sesion == null) return const LoginPage();

    // El aviso va antes del inicio porque el inicio arranca el GPS, y el GPS
    // pide el permiso: el aviso tiene que llegar antes que el dialogo.
    final aviso = ref.watch(avisoUbicacionProvider);
    if (aviso == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return aviso ? const HomePage() : const AvisoUbicacionPage();
  }
}
