"""Publica una version nueva del APK por el canal de actualizaciones.

Compila, verifica la firma, sube el APK al bucket y despues el manifiesto
`app/version.json`. Desde ese momento las apps viejas ven el aviso, y a los
`--gracia` dias (10 por defecto) se bloquean hasta actualizar.

Se corre con el Python del backend, que ya trae boto3 y lee `backend/.env`:

    backend/.venv/Scripts/python tools/publicar_apk.py --notas "Mapas de ..."

Opciones:

    --notas TEXTO    Lo que ve la persona en el aviso. Corto y concreto.
    --gracia N       Dias antes de bloquear las versiones anteriores (10).
    --critica        Bloquea YA a todas las versiones anteriores. Solo para un
                     bug que corrompe datos: deja sin app a quien este en campo
                     sin senal hasta que vuelva a tenerla.
    --sin-build      Usa el APK ya compilado en vez de compilar.
    --simular        Hace todo menos subir.

## Lo que se niega a hacer, y por que

- **Publicar un APK firmado con la llave de debug.** Android no instala un APK
  encima de otro firmado con otra llave; la unica salida seria desinstalar, y
  eso borra lo que no se sincronizo.
- **Publicar con una firma distinta a la anterior.** El manifiesto guarda la
  huella del certificado. Si cambia, es otra llave (otra maquina, un keystore
  regenerado) y ninguna app instalada podria actualizarse.
- **Publicar un versionCode que no sea mayor al vigente.** Android rechaza el
  "downgrade" y el aviso no se iria nunca.

## Por que el manifiesto va al final

Si se subiera primero, durante la subida del APK (minutos, con 50 MB) las apps
verian una version nueva cuyo APK todavia no existe.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
APP = RAIZ / "app"

# Solo las dos arquitecturas de telefonos de verdad. Sin esto Flutter mete
# tambien x86_64, que es la de los emuladores: 28 MB de los 80 del APK que no
# le sirven a nadie y que cada actualizacion baja por senal rural.
PLATAFORMAS = ("--target-platform", "android-arm,android-arm64")
APK = APP / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
LLAVE_MANIFIESTO = "app/version.json"


def fallar(mensaje: str) -> None:
    print(f"\n[X] {mensaje}\n", file=sys.stderr)
    sys.exit(1)


def cargar_env() -> None:
    """Lee backend/.env sin pisar lo que ya este en el entorno."""
    env = RAIZ / "backend" / ".env"
    if not env.exists():
        fallar("No existe backend/.env: hacen falta las credenciales de AWS.")
    for linea in env.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        os.environ.setdefault(clave.strip(), valor.strip().strip('"').strip("'"))


def version_del_pubspec() -> tuple[str, int]:
    texto = (APP / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([\w.\-]+)\+(\d+)\s*$", texto, re.MULTILINE)
    if not m:
        fallar("pubspec.yaml no tiene una linea `version: X.Y.Z+N`.")
    return m.group(1), int(m.group(2))


def compilar() -> None:
    defines = APP / "dart_defines.json"
    if not defines.exists():
        fallar("Falta app/dart_defines.json (API_KEY, GOOGLE_SERVER_CLIENT_ID).")
    flutter = shutil.which("flutter") or shutil.which("flutter.bat")
    if not flutter:
        fallar("No se encontro `flutter` en el PATH.")
    print("Compilando el APK de release...")
    r = subprocess.run(
        [
            flutter,
            "build",
            "apk",
            "--release",
            *PLATAFORMAS,
            f"--dart-define-from-file={defines.name}",
        ],
        cwd=APP,
    )
    if r.returncode != 0:
        fallar("Fallo la compilacion.")


def apksigner() -> str:
    """apksigner de las build-tools mas nuevas del SDK de Android."""
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        props = APP / "android" / "local.properties"
        if props.exists():
            m = re.search(r"^sdk\.dir=(.+)$", props.read_text(), re.MULTILINE)
            if m:
                sdk = m.group(1).replace("\\:", ":").replace("\\\\", "\\")
    if not sdk:
        fallar("No se encontro el SDK de Android (ANDROID_HOME).")
    build_tools = sorted((Path(sdk) / "build-tools").glob("*"), reverse=True)
    for carpeta in build_tools:
        for nombre in ("apksigner.bat", "apksigner"):
            if (carpeta / nombre).exists():
                return str(carpeta / nombre)
    fallar("No se encontro apksigner en las build-tools del SDK.")
    return ""


def firma_del_apk(apk: Path) -> tuple[str, str]:
    """(huella SHA-256 del certificado, DN del firmante)."""
    r = subprocess.run(
        [apksigner(), "verify", "--print-certs", str(apk)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        fallar(f"El APK no pasa la verificacion de firma:\n{r.stderr or r.stdout}")
    huella = re.search(r"certificate SHA-256 digest:\s*([0-9a-fA-F]+)", r.stdout)
    dn = re.search(r"certificate DN:\s*(.+)", r.stdout)
    if not huella:
        fallar(f"No se pudo leer la huella del certificado:\n{r.stdout}")
    return huella.group(1).lower(), (dn.group(1).strip() if dn else "")


def sha256(archivo: Path) -> str:
    h = hashlib.sha256()
    with archivo.open("rb") as f:
        for bloque in iter(lambda: f.read(1024 * 1024), b""):
            h.update(bloque)
    return h.hexdigest()


def cliente_s3():
    import boto3

    return boto3.client(
        "s3",
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID") or None,
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY") or None,
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
    )


def manifiesto_actual(s3, bucket: str) -> dict | None:
    from botocore.exceptions import ClientError

    try:
        r = s3.get_object(Bucket=bucket, Key=LLAVE_MANIFIESTO)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            return None
        raise
    return json.loads(r["Body"].read())


def minima_nueva(anterior: dict | None, ahora: datetime, critica: bool, code: int) -> int:
    """Desde que version se bloquea sin esperar.

    Quien sigue en una version cuyo plazo ya vencio no recibe diez dias mas
    porque se publico otra: la minima sube hasta la version anterior si su
    gracia ya termino. Sin esto, cada publicacion reiniciaria el reloj de los
    rezagados.
    """
    if critica:
        return code
    if not anterior:
        return 0
    minima = int(anterior.get("minima", 0))
    publicada = datetime.fromisoformat(anterior["publicada_en"])
    if publicada.tzinfo is None:
        publicada = publicada.replace(tzinfo=timezone.utc)
    vence = publicada + timedelta(days=int(anterior.get("dias_gracia", 10)))
    if ahora >= vence:
        minima = max(minima, int(anterior["version_code"]))
    return minima


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--notas", required=True)
    p.add_argument("--gracia", type=int, default=10)
    p.add_argument("--critica", action="store_true")
    p.add_argument("--sin-build", action="store_true")
    p.add_argument("--simular", action="store_true")
    args = p.parse_args()

    cargar_env()
    bucket = os.environ.get("S3_BUCKET")
    if not bucket:
        fallar("Falta S3_BUCKET en backend/.env.")

    if not (APP / "android" / "key.properties").exists():
        fallar(
            "Falta app/android/key.properties. Sin la llave de release el APK "
            "sale firmado con la de debug y ninguna app instalada lo acepta "
            "como actualizacion. Ver docs/despliegue.md, 'Firma del APK'."
        )

    nombre, code = version_del_pubspec()
    if not args.sin_build:
        compilar()
    if not APK.exists():
        fallar(f"No existe {APK}.")

    huella, dn = firma_del_apk(APK)
    if "Android Debug" in dn:
        fallar("El APK esta firmado con la llave de DEBUG. No se publica.")

    s3 = cliente_s3()
    anterior = manifiesto_actual(s3, bucket)
    if anterior:
        if code <= int(anterior["version_code"]):
            fallar(
                f"El versionCode {code} no es mayor que el publicado "
                f"({anterior['version_code']}). Subi el +N en pubspec.yaml."
            )
        previa = anterior.get("firma_sha256")
        if previa and previa != huella:
            fallar(
                "La firma de este APK NO es la de la version publicada.\n"
                f"  publicada: {previa}\n  este APK:  {huella}\n"
                "Ningun telefono podria instalarlo encima. Compila con el "
                "keystore original."
            )

    ahora = datetime.now(timezone.utc)
    llave_apk = f"app/geomaps-{nombre}+{code}.apk"
    manifiesto = {
        "version_code": code,
        "version_nombre": nombre,
        "publicada_en": ahora.isoformat(),
        "dias_gracia": args.gracia,
        "minima": minima_nueva(anterior, ahora, args.critica, code),
        "llave_apk": llave_apk,
        "sha256": sha256(APK),
        "tamano_bytes": APK.stat().st_size,
        "firma_sha256": huella,
        "notas": args.notas.strip(),
    }

    print("\nManifiesto a publicar:")
    print(json.dumps(manifiesto, indent=2, ensure_ascii=False))
    bloquea = ahora + timedelta(days=args.gracia)
    print(
        f"\nLas versiones anteriores a {code} ven el aviso desde ya y se "
        f"bloquean el {bloquea:%Y-%m-%d %H:%M} UTC."
    )
    if manifiesto["minima"]:
        print(f"Las anteriores a {manifiesto['minima']} se bloquean YA.")

    if args.simular:
        print("\n--simular: no se subio nada.")
        return

    print(f"\nSubiendo {llave_apk} ({manifiesto['tamano_bytes'] / 1e6:.1f} MB)...")
    s3.upload_file(
        str(APK),
        bucket,
        llave_apk,
        ExtraArgs={"ContentType": "application/vnd.android.package-archive"},
    )
    s3.put_object(
        Bucket=bucket,
        Key=LLAVE_MANIFIESTO,
        Body=json.dumps(manifiesto, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json",
        # El backend cachea un minuto por su cuenta; esto evita que un proxy
        # intermedio lo cachee mas.
        CacheControl="no-cache",
    )
    print("\nListo. El backend lo empieza a informar en menos de un minuto.")


if __name__ == "__main__":
    main()
