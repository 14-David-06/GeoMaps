import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/enlaces.dart';
import '../state/sesion.dart';

/// Entrada y registro. Dos puertas, una pantalla.
///
/// **Correo y clave** arriba, porque es lo que funciona en cualquier telefono:
/// Google Sign-In necesita los servicios de Google Play, y los equipos baratos
/// que se usan en campo no siempre los tienen actualizados — o los tienen rotos
/// de una forma que no se arregla desde la app. Una cuenta con clave no depende
/// de nada de eso.
///
/// **Continuar con Google** abajo, separado por una linea, porque para quien si
/// puede usarlo es un toque en vez de tres campos.
///
/// El interruptor Entrar / Crear cuenta cambia el formulario en el lugar, sin
/// navegar a otra pantalla: con una sola ventana de senal, mandar a alguien a
/// una segunda pantalla es una oportunidad de perderla.
///
/// Con [reingreso] es la misma pantalla abierta desde adentro, por quien tiene
/// la sesion vencida: lleva una flecha para volver sin entrar -sigue pudiendo
/// trabajar en el telefono- y se cierra sola en cuanto la sesion queda al dia.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({this.reingreso = false, super.key});

  /// Si la abrio alguien que ya esta adentro, para renovar una sesion vencida.
  final bool reingreso;

  /// Abre el ingreso encima de lo que haya, para volver a entrar.
  static Future<void> abrirParaReingresar(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LoginPage(reingreso: true)),
    );
  }

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formulario = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _correo = TextEditingController();
  final _clave = TextEditingController();

  bool _registrando = false;
  bool _verClave = false;

  @override
  void dispose() {
    _nombre.dispose();
    _correo.dispose();
    _clave.dispose();
    super.dispose();
  }

  void _cambiarModo(bool registrando) {
    if (_registrando == registrando) return;
    // El correo y la clave se conservan al cambiar de modo. Quien escribio su
    // correo, vio "ese correo ya tiene cuenta" y toco Entrar no tiene por que
    // escribirlo de nuevo.
    setState(() => _registrando = registrando);
  }

  Future<void> _enviar() async {
    // Cierra el teclado antes de la llamada: si no, el error aparece tapado y
    // parece que no paso nada.
    FocusScope.of(context).unfocus();
    if (!_formulario.currentState!.validate()) return;

    final notifier = ref.read(sesionProvider.notifier);
    final correo = _correo.text.trim();
    final clave = _clave.text;

    if (_registrando) {
      await notifier.registrar(
        nombre: _nombre.text.trim(),
        correo: correo,
        clave: clave,
      );
    } else {
      await notifier.entrarConClave(correo, clave);
    }
  }

  @override
  Widget build(BuildContext context) {
    final estado = ref.watch(sesionProvider);
    final colores = Theme.of(context).colorScheme;
    final cargando = estado.cargando;

    if (widget.reingreso) {
      // Entro: esta pantalla ya no tiene nada que hacer encima del inicio.
      ref.listen<EstadoSesion>(sesionProvider, (antes, ahora) {
        if (ahora.autenticado && mounted) Navigator.of(context).maybePop();
      });
    }

    return Scaffold(
      appBar: widget.reingreso
          ? AppBar(title: const Text('Entrar de nuevo'))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.layers, size: 64, color: colores.primary),
                  const SizedBox(height: 20),
                  Text(
                    'GeoMaps',
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.reingreso
                        ? 'Tu sesion vencio. Lo que hiciste sigue guardado en '
                              'este telefono, y sube cuando entres.'
                        : 'Tus mapas del predio, sin senal',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colores.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),

                  _SelectorModo(
                    registrando: _registrando,
                    habilitado: !cargando,
                    alCambiar: _cambiarModo,
                  ),
                  const SizedBox(height: 20),

                  Form(
                    key: _formulario,
                    child: Column(
                      children: [
                        // El nombre solo se pide al registrar. En el login
                        // sobra: el backend ya lo tiene.
                        if (_registrando) ...[
                          TextFormField(
                            controller: _nombre,
                            enabled: !cargando,
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Nombre',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (v) => (v == null || v.trim().length < 2)
                                ? 'Escribi tu nombre.'
                                : null,
                          ),
                          const SizedBox(height: 14),
                        ],

                        TextFormField(
                          controller: _correo,
                          enabled: !cargando,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          // Sin esto, el teclado de Android pone mayuscula a la
                          // primera letra y el correo entra distinto al que la
                          // persona cree que escribio.
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Correo',
                            prefixIcon: Icon(Icons.alternate_email),
                          ),
                          validator: (v) {
                            final t = (v ?? '').trim();
                            if (t.isEmpty) return 'Escribi tu correo.';
                            // La validacion de verdad la hace el backend; esto
                            // solo evita gastar un viaje de red en un tipeo
                            // obvio, que en red rural cuesta veinte segundos.
                            if (!t.contains('@') || !t.contains('.')) {
                              return 'Ese correo no parece valido.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: _clave,
                          enabled: !cargando,
                          obscureText: !_verClave,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => cargando ? null : _enviar(),
                          decoration: InputDecoration(
                            labelText: 'Clave',
                            prefixIcon: const Icon(Icons.lock_outline),
                            // Poder ver lo que se escribe importa mas de lo
                            // habitual: se teclea con guantes, con sol de
                            // frente y sin poder recuperar la clave despues.
                            suffixIcon: IconButton(
                              icon: Icon(
                                _verClave
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              tooltip: _verClave ? 'Ocultar' : 'Ver',
                              onPressed: () =>
                                  setState(() => _verClave = !_verClave),
                            ),
                            helperText: _registrando
                                ? 'Minimo 8 caracteres. Anotala: por ahora no '
                                      'hay recuperacion automatica.'
                                : null,
                            helperMaxLines: 3,
                          ),
                          validator: (v) {
                            final t = v ?? '';
                            if (t.isEmpty) return 'Escribi tu clave.';
                            // El minimo solo se exige al registrar. En el login
                            // rechazar por largo le contaria a un atacante como
                            // son las claves validas, y a quien se equivoco no
                            // le ahorra nada.
                            if (_registrando && t.length < 8) {
                              return 'Al menos 8 caracteres.';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                  // El error va aca, pegado al boton que lo causo, y no al
                  // pie de la pantalla: abajo de todo quedaba fuera de la
                  // vista y parecia que tocar Entrar no hacia nada.
                  if (estado.error != null) ...[
                    const SizedBox(height: 16),
                    _CartelError(texto: estado.error!),
                  ],
                  const SizedBox(height: 22),

                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: cargando ? null : _enviar,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: cargando
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_registrando ? 'Crear cuenta' : 'Entrar'),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'o',
                          style: TextStyle(color: colores.onSurfaceVariant),
                        ),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 24),

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: cargando
                          ? null
                          : () => ref.read(sesionProvider.notifier).entrar(),
                      icon: const Icon(Icons.login),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Text('Continuar con Google'),
                      ),
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Esta frase no es relleno. Sin ella, una pantalla de login al
                  // abrir la app hace creer que GeoMaps no sirve offline, que es
                  // justo lo contrario de lo que es.
                  Text(
                    'El primer ingreso necesita conexion una sola vez. '
                    'Despues la app funciona un mes completo sin senal.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: colores.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Aca y no solo en el perfil: quien crea la cuenta tiene que
                  // poder leer que se hace con sus datos antes de crearla.
                  TextButton(
                    onPressed: () => Enlaces.abrir(Enlaces.privacidad),
                    child: const Text('Politica de privacidad'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Por que no se pudo entrar, en las palabras que mando el servidor.
class _CartelError extends StatelessWidget {
  const _CartelError({required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colores.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colores.onErrorContainer, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(
                color: colores.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Interruptor Entrar / Crear cuenta.
///
/// Un segmentado y no dos pestanas de navegacion: las dos opciones tienen que
/// verse a la vez. Quien abre la app por primera vez necesita ver que existe
/// "Crear cuenta" sin buscarlo.
class _SelectorModo extends StatelessWidget {
  const _SelectorModo({
    required this.registrando,
    required this.habilitado,
    required this.alCambiar,
  });

  final bool registrando;
  final bool habilitado;
  final ValueChanged<bool> alCambiar;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('Entrar')),
        ButtonSegment(value: true, label: Text('Crear cuenta')),
      ],
      selected: {registrando},
      showSelectedIcon: false,
      onSelectionChanged: habilitado ? (s) => alCambiar(s.first) : null,
    );
  }
}
