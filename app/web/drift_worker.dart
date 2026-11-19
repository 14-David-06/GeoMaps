// El worker con el que drift abre la base local en el navegador (SQLite en
// WebAssembly, guardado en el almacen del navegador).
//
// No lo compila `flutter build web`: lo compila tools/compilar_pwa.py con la
// misma version de drift del pubspec.lock y lo deja como drift_worker.js al
// lado de la app. Un worker de otra version de drift no abre la base.
import 'package:drift/wasm.dart';

void main() => WasmDatabase.workerMainForOpen();
