import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/pwa.dart';
import '../../state/providers.dart';
import '../../state/pwa.dart';
import '../../state/sincronizador.dart';
import '../../state/zona_guaicaramo.dart';
import 'tarjeta_pwa.dart' show fechaCorta;

/// La version en la hoja de la cuenta. Tocada siete veces seguidas abre el
/// diagnostico de la app web.
///
/// Escondido a proposito: es para quien da soporte, no para quien trabaja en
/// el lote. Existe porque revisar Safari de un iPhone pide una Mac, y en
/// campo la unica forma de saber que quedo guardado es preguntarle a la app.
class VersionConDiagnostico extends ConsumerStatefulWidget {
  const VersionConDiagnostico({super.key});

  @override
  ConsumerState<VersionConDiagnostico> createState() =>
      _VersionConDiagnosticoState();
}

class _VersionConDiagnosticoState extends ConsumerState<VersionConDiagnostico> {
  static const _toques = 7;
  int _contados = 0;
  DateTime _ultimo = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    final version = ref.watch(versionLocalProvider);
    return ListTile(
      leading: const Icon(Icons.info_outline),
      title: Text(
        version == null ? 'GeoMaps web' : 'GeoMaps web ${version.nombre}',
      ),
      onTap: _tocar,
    );
  }

  void _tocar() {
    final ahora = DateTime.now();
    // Siete toques seguidos, no siete en el dia.
    _contados = ahora.difference(_ultimo) > const Duration(seconds: 2)
        ? 1
        : _contados + 1;
    _ultimo = ahora;
    if (_contados < _toques) return;
    _contados = 0;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticoPwaPage()));
  }
}

/// Lo que quedo guardado en este iPhone y en que estado esta la app web.
class DiagnosticoPwaPage extends ConsumerStatefulWidget {
  const DiagnosticoPwaPage({super.key});

  @override
  ConsumerState<DiagnosticoPwaPage> createState() => _DiagnosticoPwaPageState();
}

class _DiagnosticoPwaPageState extends ConsumerState<DiagnosticoPwaPage> {
  late Future<_Medidas> _medidas = _medir();

  static Future<_Medidas> _medir() async => _Medidas(
    versionSw: await Pwa.versionServiceWorker(),
    espacio: await Pwa.espacio(),
    teselas: await Pwa.teselasGuardadas(),
  );

  @override
  Widget build(BuildContext context) {
    final pwa = ref.watch(estadoPwaProvider);
    final version = ref.watch(versionLocalProvider);
    final pendientes = ref.watch(pendientesProvider).valueOrNull;
    final zona = ref.watch(zonaGuaicaramoProvider);
    final acopios = ref
        .watch(acopiosPredioProvider('guaicaramo-acopios.json'))
        .valueOrNull;
    final motor = Pwa.motorBase;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostico'),
        actions: [
          IconButton(
            tooltip: 'Volver a medir',
            onPressed: () => setState(() => _medidas = _medir()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<_Medidas>(
        future: _medidas,
        builder: (context, s) {
          final m = s.data;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _Dato(
                'Version de la app',
                version == null
                    ? 'Sin leer'
                    : '${version.nombre} (${version.code})',
              ),
              _Dato(
                'Version guardada en el telefono',
                m == null ? 'Midiendo...' : (m.versionSw ?? 'Ninguna'),
              ),
              _Dato(
                'Como esta abierta',
                pwa.instalada
                    ? 'Instalada (desde el icono)'
                    : 'En el navegador, sin instalar',
              ),
              _Dato(
                'Funciona sin senal',
                pwa.listaSinSenal
                    ? (pwa.guardadaEl == null
                          ? 'Si'
                          : 'Si, guardada el ${fechaCorta(pwa.guardadaEl!)}')
                    : pwa.guardando
                    ? 'Guardando: ${(pwa.progreso * 100).round()} %'
                    : 'No',
                mal: !pwa.listaSinSenal,
              ),
              _Dato(
                'Espacio usado',
                m?.espacio == null
                    ? 'No se sabe'
                    : '${_mb(m!.espacio!.usado)} de '
                          '${_mb(m.espacio!.cuota)} disponibles',
              ),
              _Dato('Base local', switch (motor) {
                null => 'Sin abrir todavia',
                'inMemory' => 'Solo en memoria: lo que se guarde se pierde',
                final otro => otro,
              }, mal: motor == 'inMemory'),
              _Dato(
                'Imagenes del mapa guardadas',
                m?.teselas == null ? 'No se sabe' : '${m!.teselas}',
              ),
              _Dato(
                'Zona Guaicaramo',
                zona.when(
                  data: (_) => acopios == null
                      ? 'Guardada'
                      : 'Guardada, con ${acopios.acopios.length} acopios',
                  loading: () => 'Leyendo...',
                  error: (_, _) => 'No esta en esta version',
                ),
                mal: zona.hasError,
              ),
              _Dato(
                'Pendientes por subir',
                pendientes == null ? 'Contando...' : '$pendientes',
              ),
              _Dato('Navegador', Pwa.navegador),
            ],
          );
        },
      ),
    );
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _Medidas {
  const _Medidas({this.versionSw, this.espacio, this.teselas});

  final String? versionSw;
  final EspacioPwa? espacio;
  final int? teselas;
}

class _Dato extends StatelessWidget {
  const _Dato(this.titulo, this.valor, {this.mal = false});

  final String titulo;
  final String valor;
  final bool mal;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(titulo),
      subtitle: SelectableText(
        valor,
        style: TextStyle(
          color: mal ? colores.error : colores.onSurface,
          fontWeight: mal ? FontWeight.w700 : null,
        ),
      ),
    );
  }
}
