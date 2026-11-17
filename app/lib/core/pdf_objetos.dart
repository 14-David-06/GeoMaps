import 'dart:io' show zlib;
import 'dart:typed_data';

/// Leer la **estructura** de un PDF: sus objetos, sus paginas y lo que cuelga
/// de ellas. No dibuja nada; para eso esta el motor de PDF del telefono.
///
/// ## Por que existe
///
/// La georreferencia de un plano vive en diccionarios del PDF, y cada programa
/// los escribe distinto. Buscar `/VP` como texto alcanzaba para el plano de
/// topografia con el que se empezo, y fallaba con casi todo lo demas:
///
/// - QGIS y GDAL escriben el viewport como **referencia** a otro objeto
///   (`/VP [ 7 0 R ]`), no adentro de la pagina.
/// - ArcGIS Pro, Acrobat y cualquier PDF "optimizado" guardan los diccionarios
///   **comprimidos** en flujos de objetos (`/ObjStm`): el texto `/VP` no
///   aparece en ningun lado del archivo, aunque el plano si este
///   georreferenciado.
/// - Un plano de varias hojas tiene varios `/MediaBox`, y el primero que
///   aparece en el archivo no es necesariamente el de la hoja que importa.
///
/// ## Como arma la tabla de objetos
///
/// No lee la tabla de referencias cruzadas del final: **recorre el archivo**
/// buscando cada `N G obj`, y abre los flujos de objetos para sacar los que
/// estan comprimidos. Es lo que hacen las herramientas de reparacion, y tiene
/// dos ventajas aca: no depende de que la tabla este sana -un PDF que paso por
/// WhatsApp o por un correo a veces llega con ella corrida-, y no hay que
/// implementar las tres variantes de tabla que existen. Cuando un objeto
/// aparece dos veces gana el que esta mas adelante, que es como un PDF guarda
/// sus correcciones.
class PdfDocumento {
  PdfDocumento(this._b) {
    _indexar();
  }

  final Uint8List _b;

  /// Donde empieza el cuerpo de cada objeto suelto, y en que lugar del archivo
  /// se definio (para decidir cual gana si esta repetido).
  final Map<int, _Entrada> _objetos = {};
  final Map<int, Object?> _cache = {};
  final Set<int> _abiertos = {};

  /// El archivo declara cifrado. Los numeros de un diccionario suelto se leen
  /// igual -solo se cifran las cadenas y los flujos-, pero lo que este adentro
  /// de un flujo de objetos queda ilegible.
  bool cifrado = false;

  /// Hubo flujos de objetos que no se pudieron abrir.
  bool comprimidosIlegibles = false;

  /// Es un PDF: empieza con la marca `%PDF` (se tolera basura adelante, que es
  /// como llegan algunos adjuntos de correo).
  bool get esPdf {
    final tope = _b.length < 1024 ? _b.length : 1024;
    for (var i = 0; i + 4 <= tope; i++) {
      if (_b[i] == 0x25 &&
          _b[i + 1] == 0x50 &&
          _b[i + 2] == 0x44 &&
          _b[i + 3] == 0x46) {
        return true;
      }
    }
    return false;
  }

  // --- Acceso a los objetos ------------------------------------------------

  /// El objeto numero [n], ya leido. Null si no existe o esta roto.
  Object? objeto(int n) {
    if (_cache.containsKey(n)) return _cache[n];
    final e = _objetos[n];
    // Un objeto que se referencia a si mismo no puede colgar la lectura.
    if (e == null || !_abiertos.add(n)) return null;
    Object? valor;
    try {
      valor = _Lector(e.bufer ?? _b, e.desde).valor();
    } on FormatException {
      valor = null;
    } on RangeError {
      valor = null;
    } finally {
      _abiertos.remove(n);
    }
    return _cache[n] = valor;
  }

  /// Sigue las referencias hasta llegar a un valor de verdad.
  Object? resolver(Object? v) {
    for (var i = 0; i < 32 && v is PdfRef; i++) {
      v = objeto(v.numero);
    }
    return v is PdfRef ? null : v;
  }

  Map<String, Object?>? dicc(Object? v) {
    final r = resolver(v);
    return r is Map<String, Object?> ? r : null;
  }

  List<Object?>? lista(Object? v) {
    final r = resolver(v);
    return r is List<Object?> ? r : null;
  }

  /// Un numero, venga como numero o como cadena. Los GeoPDF de TerraGo y los
  /// que escribe GDAL en ese formato guardan los decimales entre parentesis
  /// -`(12.5)`- para no perder precision.
  double? numero(Object? v) {
    final r = resolver(v);
    if (r is num) return r.toDouble();
    if (r is PdfCadena) return double.tryParse(r.valor.trim());
    return null;
  }

  /// Una lista de numeros. Null si falta o si algun elemento no es un numero.
  List<double>? numeros(Object? v) {
    final l = lista(v);
    if (l == null) return null;
    final salida = <double>[];
    for (final e in l) {
      final n = numero(e);
      if (n == null) return null;
      salida.add(n);
    }
    return salida;
  }

  /// Un nombre (`/GEO`) o una cadena (`(GEO)`), como texto.
  String? texto(Object? v) {
    final r = resolver(v);
    if (r is PdfNombre) return r.valor;
    if (r is PdfCadena) return r.valor;
    return null;
  }

  // --- Paginas -------------------------------------------------------------

  /// Las paginas en el orden en que se ven, con lo que heredan del arbol.
  ///
  /// El orden importa: el motor que dibuja pide la hoja por su posicion, y el
  /// orden de los objetos en el archivo no tiene por que coincidir.
  List<PdfPagina> paginas({int tope = 400}) {
    final salida = <PdfPagina>[];
    final raiz = _catalogo();
    final arbol = raiz == null ? null : raiz['Pages'];
    if (arbol != null) {
      _bajar(arbol, const {}, salida, <int>{}, tope);
    }
    if (salida.isNotEmpty) return salida;

    // Sin arbol legible: las paginas sueltas, en el orden de sus numeros. Es
    // adivinar el orden, pero un plano casi siempre es de una sola hoja.
    final numeros = _objetos.keys.toList()..sort();
    for (final n in numeros) {
      if (salida.length >= tope) break;
      final d = dicc(objeto(n));
      if (d != null && texto(d['Type']) == 'Page') {
        salida.add(PdfPagina._(this, d, const {}, salida.length));
      }
    }
    return salida;
  }

  void _bajar(
    Object? nodo,
    Map<String, Object?> heredado,
    List<PdfPagina> salida,
    Set<int> vistos,
    int tope,
  ) {
    if (salida.length >= tope) return;
    if (nodo is PdfRef && !vistos.add(nodo.numero)) return;
    final d = dicc(nodo);
    if (d == null) return;

    final hijos = lista(d['Kids']);
    if (hijos == null) {
      salida.add(PdfPagina._(this, d, heredado, salida.length));
      return;
    }

    // Estos tres se heredan del nodo padre cuando la pagina no los trae.
    final propio = {
      ...heredado,
      for (final k in const ['MediaBox', 'CropBox', 'Rotate'])
        if (d.containsKey(k)) k: d[k],
    };
    for (final h in hijos) {
      _bajar(h, propio, salida, vistos, tope);
    }
  }

  Map<String, Object?>? _catalogo() {
    for (final r in _raices.reversed) {
      final d = dicc(r);
      if (d != null && d.containsKey('Pages')) return d;
    }
    // Sin `trailer` legible: cualquier objeto que diga ser el catalogo.
    Map<String, Object?>? mejor;
    var lugar = -1;
    for (final e in _objetos.entries) {
      if (e.value.lugar < lugar) continue;
      final d = dicc(objeto(e.key));
      if (d != null && texto(d['Type']) == 'Catalog' && d.containsKey('Pages')) {
        mejor = d;
        lugar = e.value.lugar;
      }
    }
    return mejor;
  }

  // --- Armado de la tabla --------------------------------------------------

  /// Los `/Root` que declaran los `trailer` y las tablas comprimidas, en el
  /// orden en que aparecen. El ultimo es el vigente.
  final List<Object?> _raices = [];

  void _indexar() {
    // Todas las marcas "N G obj", incluidas las repetidas: hacen falta para
    // saber a que objeto pertenece un texto que se encuentre despues.
    final marcas = <_Marca>[];
    final fin = _b.length - 2;
    for (var i = 1; i < fin; i++) {
      // "obj": se busca la 'j' final primero porque es la letra menos comun.
      if (_b[i + 2] != 0x6A || _b[i + 1] != 0x62 || _b[i] != 0x6F) continue;
      final despues = i + 3 < _b.length ? _b[i + 3] : 0x20;
      if (!_esBlanco(despues) && !_esDelimitador(despues)) continue;

      var p = i - 1;
      if (!_esBlanco(_b[p])) continue; // "endobj" cae aca
      while (p >= 0 && _esBlanco(_b[p])) {
        p--;
      }
      final finGen = p;
      while (p >= 0 && _esDigito(_b[p])) {
        p--;
      }
      if (p == finGen || p < 0 || !_esBlanco(_b[p])) continue;
      while (p >= 0 && _esBlanco(_b[p])) {
        p--;
      }
      final finNum = p;
      while (p >= 0 && _esDigito(_b[p])) {
        p--;
      }
      if (p == finNum || finNum - p > 9) continue;

      var numero = 0;
      for (var k = p + 1; k <= finNum; k++) {
        numero = numero * 10 + (_b[k] - 0x30);
      }
      marcas.add(_Marca(numero, i + 3));
      _objetos[numero] = _Entrada(i + 3, i);
    }

    // Los `trailer` de las tablas clasicas.
    for (final t in _buscar('trailer')) {
      _anotarRaiz(_leerDicc(t + 7));
    }

    // Las tablas comprimidas y los flujos de objetos. Los dos se reconocen
    // por su `/Type`, que esta siempre en claro: el diccionario de un flujo
    // nunca se comprime, ni siquiera en un archivo cifrado.
    for (final t in _buscar('/XRef')) {
      final m = _marcaAntes(marcas, t);
      if (m == null) continue;
      final d = _leerDicc(m.desde);
      if (d != null && texto(d['Type']) == 'XRef') _anotarRaiz(d);
    }

    final contenedores = <int>{};
    for (final t in _buscar('/ObjStm')) {
      final m = _marcaAntes(marcas, t);
      if (m == null || !contenedores.add(m.desde)) continue;
      _abrirFlujoDeObjetos(m.desde);
    }

    // Lo que se haya leido mientras la tabla estaba a medio armar pudo quedar
    // apuntando a una version vieja del objeto.
    _cache.clear();
  }

  void _anotarRaiz(Map<String, Object?>? d) {
    if (d == null) return;
    if (d.containsKey('Encrypt')) cifrado = true;
    if (d.containsKey('Root')) _raices.add(d['Root']);
  }

  /// El diccionario que empieza en [desde], sin resolver nada.
  Map<String, Object?>? _leerDicc(int desde) {
    try {
      final v = _Lector(_b, desde).valor();
      return v is Map<String, Object?> ? v : null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  /// Saca los objetos de un flujo de objetos y los suma a la tabla.
  ///
  /// El flujo, ya descomprimido, empieza con `N` pares "numero posicion" y
  /// sigue con los objetos pegados uno atras del otro, sin `obj` ni `endobj`.
  void _abrirFlujoDeObjetos(int desde) {
    try {
      final lector = _Lector(_b, desde);
      final d = lector.valor();
      if (d is! Map<String, Object?> || texto(d['Type']) != 'ObjStm') return;

      final datos = _descomprimir(d, lector);
      final cuantos = numero(d['N'])?.toInt() ?? 0;
      final primero = numero(d['First'])?.toInt() ?? 0;
      if (cuantos <= 0 || primero <= 0 || primero > datos.length) return;

      final cabecera = _Lector(datos, 0);
      for (var i = 0; i < cuantos; i++) {
        final n = cabecera.entero();
        final donde = cabecera.entero();
        if (n == null || donde == null) break;
        final viejo = _objetos[n];
        if (viejo != null && viejo.lugar > desde) continue;
        _objetos[n] = _Entrada(primero + donde, desde, datos);
      }
    } on FormatException {
      // Lo mas comun: el archivo esta cifrado y lo que se descomprime no es
      // un flujo zlib. Se anota para poder decirlo en vez de "sin coordenadas".
      comprimidosIlegibles = true;
    } on RangeError {
      comprimidosIlegibles = true;
    }
  }

  /// Los bytes del flujo que sigue al diccionario [d], ya sin filtro.
  Uint8List _descomprimir(Map<String, Object?> d, _Lector lector) {
    lector.saltarBlancos();
    if (!lector.sigue('stream')) throw const FormatException('sin stream');
    var p = lector.p + 6;
    if (p < _b.length && _b[p] == 0x0D) p++;
    if (p < _b.length && _b[p] == 0x0A) p++;

    // `/Length` puede ser una referencia, y en archivos reparados a veces
    // miente. Se le cree solo si despues de ese largo viene `endstream`.
    var fin = -1;
    final largo = numero(d['Length'])?.toInt();
    if (largo != null && largo >= 0 && p + largo <= _b.length) {
      final l = _Lector(_b, p + largo)..saltarBlancos();
      if (l.sigue('endstream')) fin = p + largo;
    }
    if (fin < 0) {
      fin = _indice('endstream', p);
      if (fin < 0) throw const FormatException('flujo sin cierre');
    }

    var datos = Uint8List.sublistView(_b, p, fin);
    final filtros = switch (resolver(d['Filter'])) {
      final PdfNombre n => [n.valor],
      final List<Object?> l => [for (final f in l) texto(f) ?? '?'],
      _ => const <String>[],
    };
    for (final f in filtros) {
      if (f != 'FlateDecode' && f != 'Fl') {
        throw FormatException('filtro $f');
      }
      datos = _inflar(datos);
    }

    final parametros = switch (resolver(d['DecodeParms'])) {
      final Map<String, Object?> m => m,
      final List<Object?> l when l.isNotEmpty => dicc(l.first),
      _ => null,
    };
    final predictor = numero(parametros?['Predictor'])?.toInt() ?? 1;
    if (predictor >= 10) {
      datos = _sinPredictorPng(
        datos,
        columnas: numero(parametros?['Columns'])?.toInt() ?? 1,
        colores: numero(parametros?['Colors'])?.toInt() ?? 1,
        bits: numero(parametros?['BitsPerComponent'])?.toInt() ?? 8,
      );
    } else if (predictor != 1) {
      throw FormatException('predictor $predictor');
    }
    return datos;
  }

  /// Descomprime un flujo zlib.
  ///
  /// Cuando el largo se saco buscando `endstream`, el salto de linea que lo
  /// precede queda pegado al final; si molesta, se reintenta sin el.
  static Uint8List _inflar(Uint8List datos) {
    try {
      return Uint8List.fromList(zlib.decode(datos));
    } on FormatException {
      var fin = datos.length;
      while (fin > 0 && (datos[fin - 1] == 0x0A || datos[fin - 1] == 0x0D)) {
        fin--;
      }
      if (fin == datos.length) rethrow;
      return Uint8List.fromList(
        zlib.decode(Uint8List.sublistView(datos, 0, fin)),
      );
    }
  }

  /// Deshace el predictor de PNG, fila por fila. Algunos programas lo aplican
  /// a los flujos de objetos aunque no gane nada.
  static Uint8List _sinPredictorPng(
    Uint8List datos, {
    required int columnas,
    required int colores,
    required int bits,
  }) {
    final paso = ((colores * bits) + 7) ~/ 8;
    final ancho = ((columnas * colores * bits) + 7) ~/ 8;
    final filas = datos.length ~/ (ancho + 1);
    final salida = Uint8List(filas * ancho);
    for (var f = 0; f < filas; f++) {
      final tipo = datos[f * (ancho + 1)];
      final entra = f * (ancho + 1) + 1;
      final sale = f * ancho;
      for (var i = 0; i < ancho; i++) {
        final izq = i >= paso ? salida[sale + i - paso] : 0;
        final arr = f > 0 ? salida[sale - ancho + i] : 0;
        final diag = (f > 0 && i >= paso) ? salida[sale - ancho + i - paso] : 0;
        final crudo = datos[entra + i];
        final suma = switch (tipo) {
          0 => 0,
          1 => izq,
          2 => arr,
          3 => (izq + arr) >> 1,
          4 => _paeth(izq, arr, diag),
          _ => throw FormatException('fila PNG $tipo'),
        };
        salida[sale + i] = (crudo + suma) & 0xFF;
      }
    }
    return salida;
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    return pb <= pc ? b : c;
  }

  // --- Busquedas en los bytes ----------------------------------------------

  Iterable<int> _buscar(String palabra) sync* {
    var p = _indice(palabra, 0);
    while (p >= 0) {
      yield p;
      p = _indice(palabra, p + palabra.length);
    }
  }

  int _indice(String palabra, int desde) {
    final c = palabra.codeUnits;
    final tope = _b.length - c.length;
    for (var i = desde; i <= tope; i++) {
      if (_b[i] != c[0]) continue;
      var k = 1;
      while (k < c.length && _b[i + k] == c[k]) {
        k++;
      }
      if (k == c.length) return i;
    }
    return -1;
  }

  /// La ultima marca `obj` que esta antes de [posicion].
  static _Marca? _marcaAntes(List<_Marca> marcas, int posicion) {
    var a = 0;
    var b = marcas.length - 1;
    _Marca? mejor;
    while (a <= b) {
      final m = (a + b) >> 1;
      if (marcas[m].desde <= posicion) {
        mejor = marcas[m];
        a = m + 1;
      } else {
        b = m - 1;
      }
    }
    return mejor;
  }
}

/// Una pagina, con lo que hereda del arbol ya resuelto.
class PdfPagina {
  PdfPagina._(this._doc, this.dicc, this._heredado, this.indice);

  final PdfDocumento _doc;

  /// El diccionario de la pagina, tal cual.
  final Map<String, Object?> dicc;
  final Map<String, Object?> _heredado;

  /// Posicion de la hoja en el documento, desde 0.
  final int indice;

  Object? _propio(String clave) => dicc[clave] ?? _heredado[clave];

  /// `[x1 y1 x2 y2]` de la hoja entera. Null si el PDF no lo declara.
  List<double>? get mediaBox => _caja('MediaBox');

  /// La parte de la hoja que se muestra, si es menor que la hoja.
  List<double>? get cropBox => _caja('CropBox');

  List<double>? _caja(String clave) {
    final v = _doc.numeros(_propio(clave));
    return (v == null || v.length < 4) ? null : v;
  }

  /// Giro con el que se muestra la hoja: 0, 90, 180 o 270, a la derecha.
  int get rotacion {
    final r = (_doc.numero(_propio('Rotate'))?.round() ?? 0) % 360;
    return r < 0 ? r + 360 : r;
  }
}

/// Una referencia a otro objeto: `12 0 R`.
class PdfRef {
  const PdfRef(this.numero);
  final int numero;
}

/// Un nombre: `/Viewport`.
class PdfNombre {
  const PdfNombre(this.valor);
  final String valor;
}

/// Una cadena: `(texto)` o `<686f6c61>`.
class PdfCadena {
  const PdfCadena(this.valor);
  final String valor;
}

class _Entrada {
  const _Entrada(this.desde, this.lugar, [this.bufer]);

  /// Donde empieza el cuerpo del objeto, dentro de [bufer] o del archivo.
  final int desde;

  /// En que punto del archivo se definio. Para un objeto comprimido es el
  /// lugar del flujo que lo contiene.
  final int lugar;

  /// El flujo descomprimido, si el objeto venia adentro de uno.
  final Uint8List? bufer;
}

class _Marca {
  const _Marca(this.numero, this.desde);
  final int numero;
  final int desde;
}

bool _esBlanco(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0;

bool _esDigito(int c) => c >= 0x30 && c <= 0x39;

bool _esDelimitador(int c) =>
    c == 0x28 || // (
    c == 0x29 || // )
    c == 0x3C || // <
    c == 0x3E || // >
    c == 0x5B || // [
    c == 0x5D || // ]
    c == 0x7B || // {
    c == 0x7D || // }
    c == 0x2F || // /
    c == 0x25; // %

/// Lee valores de PDF desde una posicion: diccionarios, listas, nombres,
/// cadenas, numeros y referencias.
class _Lector {
  _Lector(this.b, this.p);

  final Uint8List b;
  int p;

  void saltarBlancos() {
    while (p < b.length) {
      final c = b[p];
      if (_esBlanco(c)) {
        p++;
      } else if (c == 0x25) {
        // Comentario: hasta el fin de la linea.
        while (p < b.length && b[p] != 0x0A && b[p] != 0x0D) {
          p++;
        }
      } else {
        break;
      }
    }
  }

  bool sigue(String palabra) {
    if (p + palabra.length > b.length) return false;
    for (var i = 0; i < palabra.length; i++) {
      if (b[p + i] != palabra.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// Un entero sin signo, o null si lo que sigue no lo es.
  int? entero() {
    saltarBlancos();
    final inicio = p;
    var n = 0;
    while (p < b.length && _esDigito(b[p]) && p - inicio < 15) {
      n = n * 10 + (b[p] - 0x30);
      p++;
    }
    if (p == inicio) return null;
    return n;
  }

  Object? valor([int nivel = 0]) {
    if (nivel > 48) throw const FormatException('demasiado anidado');
    saltarBlancos();
    if (p >= b.length) throw const FormatException('fin del archivo');

    final c = b[p];
    if (c == 0x3C) {
      if (p + 1 < b.length && b[p + 1] == 0x3C) {
        p += 2;
        return _diccionario(nivel);
      }
      p++;
      return PdfCadena(_hexadecimal());
    }
    if (c == 0x5B) {
      p++;
      return _lista(nivel);
    }
    if (c == 0x2F) {
      p++;
      return PdfNombre(_nombre());
    }
    if (c == 0x28) {
      p++;
      return PdfCadena(_literal());
    }
    if (_esDigito(c) || c == 0x2B || c == 0x2D || c == 0x2E) {
      return _numeroOReferencia();
    }

    final inicio = p;
    while (p < b.length && !_esBlanco(b[p]) && !_esDelimitador(b[p])) {
      p++;
    }
    final palabra = String.fromCharCodes(b, inicio, p);
    switch (palabra) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    if (p == inicio) p++;
    throw FormatException('no es un valor: $palabra');
  }

  Map<String, Object?> _diccionario(int nivel) {
    final salida = <String, Object?>{};
    while (true) {
      saltarBlancos();
      if (p + 1 >= b.length) throw const FormatException('diccionario abierto');
      if (b[p] == 0x3E && b[p + 1] == 0x3E) {
        p += 2;
        return salida;
      }
      if (b[p] != 0x2F) throw const FormatException('se esperaba una clave');
      p++;
      final clave = _nombre();
      salida[clave] = valor(nivel + 1);
    }
  }

  List<Object?> _lista(int nivel) {
    final salida = <Object?>[];
    while (true) {
      saltarBlancos();
      if (p >= b.length) throw const FormatException('lista abierta');
      if (b[p] == 0x5D) {
        p++;
        return salida;
      }
      salida.add(valor(nivel + 1));
    }
  }

  String _nombre() {
    final sb = StringBuffer();
    while (p < b.length && !_esBlanco(b[p]) && !_esDelimitador(b[p])) {
      var c = b[p];
      // `#20` es un espacio escrito adentro de un nombre.
      if (c == 0x23 && p + 2 < b.length) {
        final h = int.tryParse(String.fromCharCodes(b, p + 1, p + 3), radix: 16);
        if (h != null) {
          c = h;
          p += 2;
        }
      }
      sb.writeCharCode(c);
      p++;
    }
    return sb.toString();
  }

  String _literal() {
    final sb = StringBuffer();
    var abiertos = 1;
    while (p < b.length) {
      final c = b[p++];
      if (c == 0x5C) {
        if (p >= b.length) break;
        final e = b[p++];
        switch (e) {
          case 0x6E:
            sb.writeCharCode(0x0A);
          case 0x72:
            sb.writeCharCode(0x0D);
          case 0x74:
            sb.writeCharCode(0x09);
          case 0x62:
            sb.writeCharCode(0x08);
          case 0x66:
            sb.writeCharCode(0x0C);
          case 0x0D:
            // Barra al final de la linea: la cadena sigue en la proxima.
            if (p < b.length && b[p] == 0x0A) p++;
          case 0x0A:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var octal = e - 0x30;
              for (var k = 0; k < 2; k++) {
                if (p < b.length && b[p] >= 0x30 && b[p] <= 0x37) {
                  octal = octal * 8 + (b[p++] - 0x30);
                }
              }
              sb.writeCharCode(octal & 0xFF);
            } else {
              sb.writeCharCode(e);
            }
        }
      } else if (c == 0x28) {
        abiertos++;
        sb.writeCharCode(c);
      } else if (c == 0x29) {
        abiertos--;
        if (abiertos == 0) return sb.toString();
        sb.writeCharCode(c);
      } else {
        sb.writeCharCode(c);
      }
    }
    throw const FormatException('cadena abierta');
  }

  String _hexadecimal() {
    final sb = StringBuffer();
    int? alto;
    while (p < b.length) {
      final c = b[p++];
      if (c == 0x3E) {
        if (alto != null) sb.writeCharCode(alto << 4);
        return sb.toString();
      }
      final v = _valorHex(c);
      if (v == null) continue;
      if (alto == null) {
        alto = v;
      } else {
        sb.writeCharCode((alto << 4) | v);
        alto = null;
      }
    }
    throw const FormatException('cadena hexadecimal abierta');
  }

  static int? _valorHex(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x37;
    if (c >= 0x61 && c <= 0x66) return c - 0x57;
    return null;
  }

  Object _numeroOReferencia() {
    final inicio = p;
    var soloDigitos = true;
    while (p < b.length) {
      final c = b[p];
      if (_esDigito(c)) {
        p++;
      } else if (c == 0x2B || c == 0x2D || c == 0x2E) {
        soloDigitos = false;
        p++;
      } else {
        break;
      }
    }
    final crudo = String.fromCharCodes(b, inicio, p);

    // "12 0 R" empieza igual que tres numeros sueltos: se mira adelante y, si
    // no era una referencia, se vuelve atras.
    if (soloDigitos && crudo.length <= 10) {
      final vuelta = p;
      final generacion = entero();
      if (generacion != null) {
        saltarBlancos();
        if (p < b.length && b[p] == 0x52) {
          final sig = p + 1 < b.length ? b[p + 1] : 0x20;
          if (_esBlanco(sig) || _esDelimitador(sig)) {
            p++;
            return PdfRef(int.parse(crudo));
          }
        }
      }
      p = vuelta;
    }

    final n = num.tryParse(crudo) ?? num.tryParse('${crudo}0');
    if (n == null) throw FormatException('numero ilegible: $crudo');
    return n;
  }
}
