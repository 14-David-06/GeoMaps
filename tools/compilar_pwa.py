"""Compila GeoMaps web (la app del iPhone) y la deja dentro del backend.

    backend/.venv/Scripts/python tools/compilar_pwa.py

Deja la app en `backend/public/geomaps/`, que Vercel sirve como archivos
estaticos en https://<dominio>/geomaps/ junto al API de FastAPI: no hay un
proyecto ni un servidor nuevo, y la app llama al API en el mismo dominio.

No despliega nada. Publicar es desplegar el backend como siempre (eso lo hace
quien maneja Vercel).

Pasos:

1. `flutter build web` con `dart_defines.json`, CanvasKit empaquetado
   (`--no-web-resources-cdn`: sin eso la app la pide a un CDN de Google y no
   arranca sin senal) y `--base-href /geomaps/`.
2. Agrega lo que la base local necesita en el navegador: `sqlite3.wasm`, de la
   version de sqlite3 del pubspec.lock, y `drift_worker.js`, compilado con la
   drift del pubspec.lock. Un par de otra version no abre la base.
3. Deja Roboto donde el motor de Flutter la pide al arrancar, para que no la
   busque en fonts.gstatic.com.
4. Quita lo que la app no usa: las otras variantes de CanvasKit (la app
   fuerza la de Safari), los mapas de depuracion y el service worker de
   Flutter, que esta en desuso.
5. Escribe `sw.js` desde `tools/pwa/sw_plantilla.js` con la lista real de
   archivos, su peso y su hash. La version es el pubspec mas un hash del build:
   si no cambio nada, el service worker sale identico y los telefonos no bajan
   nada.
6. Genera el codigo QR de la pagina de instalacion.
7. Copia todo a `backend/public/geomaps/`, borrando lo anterior.

`backend/public/geomaps/` NO se versiona (.gitignore): el build lleva adentro
los datos del predio (lotes, vias, acopios), que son del cliente, y este
repositorio es publico.

Con `--sin-compilar` reusa `app/build/web` (el build de Flutter tarda) y rehace
los pasos 2 a 7.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import urllib.request
from pathlib import Path

from publicar_apk import APP, RAIZ, fallar, version_del_pubspec

SUBRUTA = "/geomaps/"
DOMINIO = "https://geo-maps-seven.vercel.app"

BUILD = APP / "build" / "web"
DESTINO = RAIZ / "backend" / "public" / "geomaps"
PLANTILLA_SW = RAIZ / "tools" / "pwa" / "sw_plantilla.js"
# Lo que se baja o se compila una vez por version de paquete. tools/salida/ no
# se versiona.
GUARDADOS = RAIZ / "tools" / "salida" / "pwa"
QR_DOCS = RAIZ / "docs" / "qr"

# Lo que se publica pero el service worker no guarda en el telefono: no hace
# falta para abrir ni para trabajar. NOTICES son las licencias de los paquetes
# (1,4 MB); instalar-qr.svg se mira con senal.
NO_GUARDAR = {"assets/NOTICES", "instalar-qr.svg"}


def version_del_lock(paquete: str) -> str:
    texto = (APP / "pubspec.lock").read_text(encoding="utf-8")
    m = re.search(
        rf"^  {re.escape(paquete)}:\n(?:    .*\n)*?    version: \"([^\"]+)\"",
        texto,
        re.MULTILINE,
    )
    if not m:
        fallar(f"No encontre la version de {paquete} en pubspec.lock.")
    return m.group(1)


def flutter() -> str:
    ruta = shutil.which("flutter") or shutil.which("flutter.bat")
    if not ruta:
        fallar("No se encontro `flutter` en el PATH.")
    return ruta


def compilar() -> None:
    defines = APP / "dart_defines.json"
    if not defines.exists():
        fallar("Falta app/dart_defines.json (API_KEY).")
    if not list((APP / "assets" / "zonas").glob("*.json")):
        print(
            "[!] app/assets/zonas/ no tiene los datos del predio: la app web "
            "va a salir sin el mapa de Guaicaramo (ver assets/zonas/LEEME.md)."
        )
    print("Compilando la app web (tarda varios minutos)...")
    r = subprocess.run(
        [
            flutter(),
            "build",
            "web",
            "--release",
            f"--base-href={SUBRUTA}",
            "--no-web-resources-cdn",
            # La prueba de WebAssembly es una segunda compilacion entera que
            # esta app no usa.
            "--no-wasm-dry-run",
            f"--dart-define-from-file={defines.name}",
        ],
        cwd=APP,
    )
    if r.returncode != 0:
        fallar("Fallo `flutter build web`.")


def sqlite3_wasm() -> Path:
    version = version_del_lock("sqlite3")
    archivo = GUARDADOS / f"sqlite3-{version}.wasm"
    if archivo.exists():
        return archivo
    url = (
        "https://github.com/simolus3/sqlite3.dart/releases/download/"
        f"sqlite3-{version}/sqlite3.wasm"
    )
    print(f"Bajando sqlite3.wasm {version}...")
    GUARDADOS.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as r:
        datos = r.read()
    # Un WebAssembly empieza con "\0asm". Si GitHub devolvio una pagina de
    # error, mejor saberlo aca que con la base sin abrir en un iPhone.
    if not datos.startswith(b"\0asm"):
        fallar(f"Lo que bajo de {url} no es un WebAssembly.")
    archivo.write_bytes(datos)
    return archivo


def drift_worker() -> Path:
    version = version_del_lock("drift")
    archivo = GUARDADOS / f"drift_worker-{version}.js"
    if archivo.exists():
        return archivo
    print(f"Compilando drift_worker.js con drift {version}...")
    GUARDADOS.mkdir(parents=True, exist_ok=True)
    dart = shutil.which("dart") or shutil.which("dart.bat")
    if not dart:
        fallar("No se encontro `dart` en el PATH.")
    r = subprocess.run(
        [dart, "compile", "js", "-O4", "-o", str(archivo), "web/drift_worker.dart"],
        cwd=APP,
    )
    if r.returncode != 0 or not archivo.exists():
        fallar("No se pudo compilar web/drift_worker.dart.")
    for sobra in archivo.parent.glob(archivo.name + ".*"):
        sobra.unlink()  # .deps y .map
    return archivo


def quitar_sobrantes(web: Path) -> None:
    """Lo que la app no pide nunca. Ver `canvasKitVariant` en flutter_bootstrap.js."""
    canvaskit = web / "canvaskit"
    for hijo in canvaskit.iterdir():
        if hijo.name in {"canvaskit.js", "canvaskit.wasm"}:
            continue
        if hijo.is_dir():
            shutil.rmtree(hijo)
        else:
            hijo.unlink()
    for nombre in (
        "flutter_service_worker.js",
        "flutter.js",  # flutter_bootstrap.js ya lo trae adentro
        ".last_build_id",
        "drift_worker.dart",
    ):
        (web / nombre).unlink(missing_ok=True)
    for mapa in web.rglob("*.map"):
        mapa.unlink()


def fuente_del_motor(web: Path) -> None:
    """Roboto en la ruta que el motor pide bajo `fontFallbackBaseUrl`.

    El motor de Flutter la pide al arrancar con una ruta que cambia con la
    version de Flutter (roboto/v32/....woff2), asi que se lee del build en vez
    de escribirla a mano. El contenido es el TTF de web/fuentes/: el motor lo
    lee igual.
    """
    main = (web / "main.dart.js").read_text(encoding="utf-8", errors="ignore")
    rutas = sorted(set(re.findall(r"roboto/v\d+/[A-Za-z0-9_-]+\.woff2", main)))
    if not rutas:
        print("[!] No encontre la ruta de Roboto en main.dart.js; reviselo.")
        return
    for ruta in rutas:
        destino = web / "fuentes" / ruta
        destino.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(web / "fuentes" / "roboto-regular.ttf", destino)


def qr(web: Path) -> None:
    url = f"{DOMINIO}{SUBRUTA}instalar.html"
    try:
        import segno
    except ImportError:
        print("[!] Sin `segno` no se genera el QR (pip install segno).")
        return
    codigo = segno.make(url, error="m")
    codigo.save(web / "instalar-qr.svg", scale=10, border=2)
    QR_DOCS.mkdir(parents=True, exist_ok=True)
    codigo.save(QR_DOCS / "instalar-geomaps.svg", scale=20, border=4)
    codigo.save(QR_DOCS / "instalar-geomaps.png", scale=20, border=4)
    print(f"QR de {url} en docs/qr/instalar-geomaps.(svg|png)")


def sha256(archivo: Path) -> str:
    return hashlib.sha256(archivo.read_bytes()).hexdigest()


def service_worker(web: Path, version_app: str) -> tuple[str, int, int]:
    archivos = []
    for f in sorted(web.rglob("*")):
        if not f.is_file():
            continue
        ruta = f.relative_to(web).as_posix()
        if ruta == "sw.js" or ruta in NO_GUARDAR:
            continue
        archivos.append([ruta, f.stat().st_size, sha256(f)])

    total = hashlib.sha256(
        "".join(f"{r}:{h};" for r, _, h in archivos).encode()
    ).hexdigest()[:10]
    version = f"{version_app}-{total}"

    plantilla = PLANTILLA_SW.read_text(encoding="utf-8")
    sw = plantilla.replace("'__VERSION__'", json.dumps(version)).replace(
        "__ARCHIVOS__", json.dumps(archivos, indent=1)
    )
    if "__VERSION__" in sw or "__ARCHIVOS__" in sw:
        fallar("La plantilla del service worker quedo sin completar.")
    (web / "sw.js").write_text(sw, encoding="utf-8", newline="\n")
    return version, len(archivos), sum(a[1] for a in archivos)


def copiar(web: Path) -> None:
    # Se borra entero: lo que quede de un build viejo lo guardaria el service
    # worker como si fuera de este. Solo esta carpeta, nunca mas arriba.
    if DESTINO.name != "geomaps" or DESTINO.parent.name != "public":
        fallar(f"Destino inesperado: {DESTINO}")
    # Se vacia y no se borra la carpeta misma: en Windows basta una terminal
    # parada adentro para que no se pueda borrar.
    DESTINO.mkdir(parents=True, exist_ok=True)
    for hijo in DESTINO.iterdir():
        if hijo.is_dir():
            shutil.rmtree(hijo)
        else:
            hijo.unlink()
    shutil.copytree(web, DESTINO, dirs_exist_ok=True)


def mb(n: int) -> str:
    return f"{n / (1024 * 1024):.1f} MB"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--sin-compilar",
        action="store_true",
        help="reusar app/build/web en vez de volver a correr flutter build web",
    )
    args = parser.parse_args()

    nombre, codigo = version_del_pubspec()
    if not args.sin_compilar:
        compilar()
    if not (BUILD / "main.dart.js").exists():
        fallar("No hay build en app/build/web. Corre sin --sin-compilar.")

    # Se trabaja sobre una copia: app/build/web queda como lo dejo Flutter y
    # --sin-compilar se puede repetir.
    trabajo = GUARDADOS / "web"
    if trabajo.exists():
        shutil.rmtree(trabajo)
    GUARDADOS.mkdir(parents=True, exist_ok=True)
    shutil.copytree(BUILD, trabajo)

    shutil.copyfile(sqlite3_wasm(), trabajo / "sqlite3.wasm")
    shutil.copyfile(drift_worker(), trabajo / "drift_worker.js")
    quitar_sobrantes(trabajo)
    fuente_del_motor(trabajo)
    qr(trabajo)
    version, guardados, peso_guardado = service_worker(trabajo, f"{nombre}+{codigo}")
    copiar(trabajo)

    publicados = [f for f in DESTINO.rglob("*") if f.is_file()]
    peso = sum(f.stat().st_size for f in publicados)
    print()
    print(f"Version:            {version}")
    print(f"Copiado a:          {DESTINO.relative_to(RAIZ)}")
    print(f"Archivos:           {len(publicados)} ({mb(peso)})")
    print(f"Se guarda en el iPhone: {guardados} archivos ({mb(peso_guardado)})")
    print(f"Instalacion:        {DOMINIO}{SUBRUTA}instalar.html")
    print()
    print(
        "Falta desplegar el backend para que llegue a los telefonos. Si se "
        "publico un APK nuevo, esta version tiene que salir el mismo dia: el "
        "backend bloquea a los 10 dias las versiones viejas, tambien la web."
    )


if __name__ == "__main__":
    main()
