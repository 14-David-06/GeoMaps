import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ota_update/ota_update.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/version_app.dart';
import '../platform/pwa.dart';
import 'providers.dart';
import 'red.dart';
import 'sesion.dart';

/// Si hay que actualizar la app, y la descarga del APK nuevo.
///
/// ## Como llega el bloqueo sin senal
///
/// Cada vez que hay red se consulta `/v1/version` y la respuesta se guarda.
/// Al arrancar, antes de cualquier red, se evalua contra esa copia. Quien vio
/// el aviso de una version nueva y se fue al monte se bloquea igual cuando se
/// cumplen los 10 dias, aunque no vuelva a tener senal: tuvo diez dias de aviso
/// en la pantalla de inicio.
///
/// ## Que pasa con los datos
///
/// Nada. El APK nuevo se instala encima del viejo, firmado con la misma llave,
/// y Android conserva la base local, las preferencias y la sesion. Lo que no
/// se sincronizo sigue en el telefono y sube desde la version nueva.
class EstadoActualizacion {
  const EstadoActualizacion({
    this.publicada,
    this.estado = EstadoVersion.alDia,
    this.ahora,
    this.verificando = false,
    this.descargando = false,
    this.progreso,
    this.instalando = false,
    this.error,
  });

  /// El ultimo manifiesto visto con red. Null si nunca se vio uno.
  final VersionPublicada? publicada;
  final EstadoVersion estado;

  /// La hora con la que se evaluo (ver `horaEfectiva`).
  final DateTime? ahora;

  final bool verificando;
  final bool descargando;

  /// 0 a 100 mientras baja el APK.
  final int? progreso;

  /// Se le paso el APK al instalador de Android.
  final bool instalando;
  final String? error;

  int get diasParaBloqueo =>
      publicada?.diasParaBloqueo(ahora ?? DateTime.now()) ?? 0;

  EstadoActualizacion copiar({
    VersionPublicada? publicada,
    EstadoVersion? estado,
    DateTime? ahora,
    bool? verificando,
    bool? descargando,
    int? progreso,
    bool? instalando,
    String? error,
    bool limpiarError = false,
  }) => EstadoActualizacion(
    publicada: publicada ?? this.publicada,
    estado: estado ?? this.estado,
    ahora: ahora ?? this.ahora,
    verificando: verificando ?? this.verificando,
    descargando: descargando ?? this.descargando,
    progreso: descargando == false ? null : (progreso ?? this.progreso),
    instalando: instalando ?? this.instalando,
    error: limpiarError ? null : (error ?? this.error),
  );
}

class ActualizacionNotifier extends StateNotifier<EstadoActualizacion> {
  ActualizacionNotifier(this._api, this._local)
    : super(const EstadoActualizacion()) {
    if (_local == null) return;
    _api.alVersionVencida = () => verificar();
    _escucha = AppLifecycleListener(onResume: _verificarSiToca);
    unawaited(_arrancar());
  }

  final ApiClient _api;
  final VersionLocal? _local;
  AppLifecycleListener? _escucha;
  StreamSubscription<OtaEvent>? _descarga;
  DateTime? _ultimaVerificacion;

  static const _llaveManifiesto = 'version_publicada';
  static const _llaveHora = 'version_hora_confiable';

  /// Cada cuanto se vuelve a preguntar al volver a la app. Una version nueva
  /// se publica cada semanas; preguntar en cada vuelta gasta datos de gente
  /// que paga el mega.
  static const _cadaCuanto = Duration(hours: 1);

  Future<void> _arrancar() async {
    await _restaurar();
    await verificar();
  }

  /// Evalua con lo guardado, sin red. Corre al arrancar.
  Future<void> _restaurar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final crudo = prefs.getString(_llaveManifiesto);
      final hora = prefs.getString(_llaveHora);
      if (crudo == null) return;
      final publicada = VersionPublicada.deJson(
        jsonDecode(crudo) as Map<String, dynamic>,
      );
      _evaluar(publicada, hora == null ? null : DateTime.parse(hora));
    } catch (_) {
      // Preferencias ilegibles: se sigue como si nunca se hubiera consultado.
      // Lo peor que pasa es que el bloqueo espera a la proxima vez con red.
    }
  }

  void _evaluar(VersionPublicada? publicada, DateTime? horaConfiable) {
    final local = _local;
    if (local == null || publicada == null) return;
    final ahora = horaEfectiva(DateTime.now(), horaConfiable);
    state = state.copiar(
      publicada: publicada,
      estado: publicada.evaluar(local.code, ahora),
      ahora: ahora,
    );
  }

  void _verificarSiToca() {
    final ultima = _ultimaVerificacion;
    if (ultima == null || DateTime.now().difference(ultima) > _cadaCuanto) {
      verificar();
    } else {
      // Sin consultar, igual se reevalua: el plazo pudo haberse cumplido con
      // la app en segundo plano.
      _evaluar(state.publicada, state.ahora);
    }
  }

  /// Consulta el backend. Sin red falla en silencio y queda lo guardado,
  /// salvo que la persona lo haya pedido con el boton (`avisar`).
  Future<void> verificar({bool avisar = false}) async {
    if (_local == null || state.verificando) return;
    state = state.copiar(verificando: true, limpiarError: true);
    try {
      final r = await _api.version();
      _ultimaVerificacion = DateTime.now();
      final servidor = DateTime.parse(r['ahora'] as String);
      final hora = horaEfectiva(DateTime.now(), servidor);

      if (r['publicada'] != true) {
        state = state.copiar(verificando: false);
        return;
      }
      final publicada = VersionPublicada.deJson(r);
      await _guardar(publicada, hora);
      _evaluar(publicada, hora);

      // Con red, manda el backend. Cubre un reloj del telefono atrasado que la
      // hora del servidor no alcanzo a corregir.
      if (r['estado'] == 'bloqueada') {
        state = state.copiar(estado: EstadoVersion.bloqueada);
      }
      state = state.copiar(verificando: false);
    } catch (e) {
      state = state.copiar(
        verificando: false,
        error: avisar
            ? 'No se pudo consultar la version. Busca senal y volve a probar.'
            : null,
      );
    }
  }

  Future<void> _guardar(VersionPublicada p, DateTime hora) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_llaveManifiesto, jsonEncode(p.aJson()));
      await prefs.setString(_llaveHora, hora.toIso8601String());
    } catch (_) {}
  }

  /// Baja el APK nuevo y se lo pasa al instalador de Android.
  ///
  /// Antes vuelve a consultar: la URL guardada es prefirmada y pudo vencer.
  /// El sha256 lo verifica el plugin al terminar de bajar; un APK cortado o
  /// adulterado no llega al instalador.
  Future<void> actualizar() async {
    if (state.descargando) return;
    if (kIsWeb) {
      // La app web no baja un APK: su service worker ya trajo la version
      // nueva, y aplicarla es recargar. Si no trajo ninguna, todavia no se
      // publico para el iPhone.
      if (!await Pwa.actualizar()) {
        state = state.copiar(
          error:
              'La version nueva para iPhone todavia no esta lista. Abri la '
              'app con senal en un rato, o avisale al administrador.',
        );
      }
      return;
    }
    if (_local?.desdePlay ?? false) return _abrirPlay();
    await verificar(avisar: true);
    // Sin red no se intenta con la URL guardada: es prefirmada y lo mas
    // probable es que ya haya vencido. El error de `verificar` ya lo dice.
    if (state.error != null) return;
    final p = state.publicada;
    if (p == null || p.apkUrl == null) {
      state = state.copiar(
        error:
            'Todavia no hay un APK publicado para descargar. Avisale al '
            'administrador.',
      );
      return;
    }

    state = state.copiar(
      descargando: true,
      progreso: 0,
      instalando: false,
      limpiarError: true,
    );
    await _descarga?.cancel();
    try {
      _descarga = OtaUpdate()
          .execute(
            p.apkUrl!,
            destinationFilename: 'geomaps-${p.versionCode}.apk',
            sha256checksum: p.sha256,
          )
          .listen(
            _alEvento,
            onError: (Object e) => _terminar(error: _mensajeGenerico),
            onDone: () {
              if (state.descargando) _terminar();
            },
          );
    } catch (e) {
      _terminar(error: _mensajeGenerico);
    }
  }

  void _alEvento(OtaEvent e) {
    switch (e.status) {
      case OtaStatus.DOWNLOADING:
        state = state.copiar(progreso: int.tryParse(e.value ?? ''));
      case OtaStatus.INSTALLING:
      case OtaStatus.INSTALLATION_DONE:
        // El instalador de Android ya esta en pantalla. Si la persona lo
        // cierra, vuelve aca y el boton sigue ahi.
        _terminar(instalando: true);
      case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
        _terminar(
          error:
              'Android no dejo instalar. En Ajustes, activa "Permitir de '
              'esta fuente" para GeoMaps y volve a tocar Actualizar.',
        );
      case OtaStatus.DOWNLOAD_ERROR:
        _terminar(
          error:
              'Se corto la descarga. Busca mejor senal (o wifi) y volve a '
              'intentar.',
        );
      case OtaStatus.CHECKSUM_ERROR:
        _terminar(
          error: 'La descarga llego danada y no se instalo. Volve a intentar.',
        );
      case OtaStatus.ALREADY_RUNNING_ERROR:
        break;
      case OtaStatus.CANCELED:
        _terminar();
      case OtaStatus.INSTALLATION_ERROR:
      case OtaStatus.INTERNAL_ERROR:
        _terminar(error: _mensajeGenerico);
    }
  }

  /// La copia de Play se actualiza desde Play. Se abre la ficha de la app, que
  /// muestra el boton Actualizar en cuanto Play tiene la version nueva.
  Future<void> _abrirPlay() async {
    state = state.copiar(limpiarError: true);
    final abrio = await launchUrl(
      Uri.parse(
        'https://play.google.com/store/apps/details?id=$_paquete',
      ),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!abrio) {
      state = state.copiar(
        error: 'No se pudo abrir Play Store. Buscala ahi como GeoMaps y '
            'toca Actualizar.',
      );
    }
  }

  static const _paquete = 'com.siriusregenerative.geomaps';

  static const _mensajeGenerico =
      'No se pudo instalar la actualizacion. Volve a intentar; si sigue '
      'fallando, pedi el APK al administrador.';

  void _terminar({String? error, bool instalando = false}) {
    state = state.copiar(
      descargando: false,
      instalando: instalando,
      error: error,
      limpiarError: error == null,
    );
  }

  @override
  void dispose() {
    _escucha?.dispose();
    _descarga?.cancel();
    _api.alVersionVencida = null;
    super.dispose();
  }
}

final actualizacionProvider =
    StateNotifierProvider<ActualizacionNotifier, EstadoActualizacion>((ref) {
      final local = ref.watch(versionLocalProvider);
      final notifier = ActualizacionNotifier(ref.watch(apiProvider), local);
      if (local == null) return notifier;
      // Quien estuvo sin senal se entera de la version nueva apenas vuelve la red,
      // sin tener que cerrar y abrir la app.
      ref.listen(redProvider, (antes, ahora) {
        final habia = antes?.valueOrNull?.hayRed ?? false;
        final hay = ahora.valueOrNull?.hayRed ?? false;
        if (hay && !habia) notifier.verificar();
      });
      return notifier;
    });
