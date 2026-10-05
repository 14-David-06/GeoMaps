"""Que version del APK esta vigente y cual ya no se puede usar.

GeoMaps se reparte como APK directo, sin Play Store, asi que nadie empuja las
actualizaciones: la app pregunta y este modulo contesta.

## De donde sale la respuesta

De un manifiesto en el bucket, `app/version.json`, que escribe
`tools/publicar_apk.py` al publicar un APK. Vive en S3 y no en variables de
Vercel a proposito: publicar una version no puede exigir un redeploy del
backend, y el manifiesto y el APK tienen que cambiar juntos.

```json
{
  "version_code": 2,             // el +N del pubspec
  "version_nombre": "0.2.0",
  "publicada_en": "2026-09-22T15:00:00+00:00",
  "dias_gracia": 10,
  "minima": 1,                   // por debajo de esto, bloqueo inmediato
  "llave_apk": "app/geomaps-0.2.0+2.apk",
  "sha256": "...",
  "tamano_bytes": 52428800,
  "firma_sha256": "...",         // huella del certificado que firmo el APK
  "notas": "Mapas nuevos de ..."
}
```

## La regla

| Version del telefono | Estado |
|---|---|
| `>= version_code` | `al_dia` |
| `< minima` | `bloqueada` |
| `< version_code`, antes de `publicada_en + dias_gracia` | `desactualizada`: aviso, se sigue trabajando |
| `< version_code`, despues de ese plazo | `bloqueada` |

La app aplica exactamente la misma regla con el manifiesto que guardo la
ultima vez que tuvo red, asi que el bloqueo llega aunque el telefono no vuelva
a ver senal. Y el backend la aplica en cada request (ver `main.py`): una app
vieja que se salte el chequeo igual recibe 426 al sincronizar, y no puede subir
datos con un formato que ya no existe.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Literal

from pydantic import BaseModel

from ..config import Settings
from . import almacenamiento

log = logging.getLogger(__name__)

Estado = Literal["al_dia", "desactualizada", "bloqueada"]

# Cuanto se confia en el manifiesto leido antes de volver a S3. Lo lee el
# middleware en cada request: sin cache, cada llamada de la app pagaria una
# lectura al bucket. Un minuto es lo que tarda en verse una version recien
# publicada, y nadie la esta esperando con el cronometro.
TTL_CACHE_SEGUNDOS = 60


class Manifiesto(BaseModel):
    """La version vigente, tal como la dejo `tools/publicar_apk.py`."""

    version_code: int
    version_nombre: str
    publicada_en: datetime
    dias_gracia: int = 10
    minima: int = 0
    llave_apk: str
    sha256: str
    tamano_bytes: int = 0
    firma_sha256: str = ""
    notas: str = ""

    @property
    def bloquea_en(self) -> datetime:
        """Desde cuando las versiones anteriores a esta dejan de servir."""
        publicada = self.publicada_en
        if publicada.tzinfo is None:
            publicada = publicada.replace(tzinfo=timezone.utc)
        return publicada + timedelta(days=self.dias_gracia)


def evaluar(version_code: int, manifiesto: Manifiesto, ahora: datetime) -> Estado:
    """La regla entera. La app tiene una copia identica en `version_app.dart`."""
    if version_code >= manifiesto.version_code:
        return "al_dia"
    if version_code < manifiesto.minima or ahora >= manifiesto.bloquea_en:
        return "bloqueada"
    return "desactualizada"


def version_de_header(valor: str | None) -> int | None:
    """Lee `X-App-Version`. Un valor que no es un entero se trata como ausente:
    no hay que tumbar un request por una cabecera rara."""
    if not valor:
        return None
    try:
        return int(valor.strip())
    except ValueError:
        return None


# --- Lectura del manifiesto con cache --------------------------------------

_cache: tuple[float, Manifiesto | None] | None = None

# Por que fallo la ultima lectura, si fallo. Sin esto, un bucket mal configurado
# en el despliegue se ve igual que "todavia no se publico nada", y las apps
# nunca avisan de la version nueva sin que nadie se entere de por que.
ultima_falla: str | None = None


def _codigo_de_falla(exc: Exception) -> str:
    """El codigo de AWS (NoSuchBucket, InvalidAccessKeyId...) o el tipo de
    excepcion. Solo el codigo: el mensaje puede traer datos de la cuenta."""
    respuesta = getattr(exc, "response", None)
    if isinstance(respuesta, dict):
        codigo = respuesta.get("Error", {}).get("Code")
        if codigo:
            return str(codigo)
    return type(exc).__name__


def _leer_de_s3(settings: Settings) -> Manifiesto | None:
    crudo = almacenamiento.leer(settings, settings.s3_llave_manifiesto_app)
    if crudo is None:
        return None
    return Manifiesto.model_validate(json.loads(crudo))


async def manifiesto_vigente(settings: Settings) -> Manifiesto | None:
    """El manifiesto publicado, o None si todavia no se publico ninguno.

    Si S3 falla, devuelve None y se cachea igual: sin manifiesto no se bloquea
    a nadie. Es la falla correcta — un bucket caido no puede dejar a todo el
    equipo sin app, y lo peor que pasa es que una version vieja trabaje un
    minuto mas.
    """
    global _cache, ultima_falla
    ahora = time.monotonic()
    if _cache is not None and ahora - _cache[0] < TTL_CACHE_SEGUNDOS:
        return _cache[1]

    try:
        manifiesto = await asyncio.to_thread(_leer_de_s3, settings)
        ultima_falla = None
    except Exception as exc:  # noqa: BLE001
        log.exception("No se pudo leer el manifiesto de version")
        manifiesto = None
        ultima_falla = _codigo_de_falla(exc)

    _cache = (ahora, manifiesto)
    return manifiesto


def olvidar_cache() -> None:
    """Para las pruebas."""
    global _cache
    _cache = None
