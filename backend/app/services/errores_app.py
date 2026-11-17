"""Los fallos de la app, anotados en Airtable para que alguien los vea.

Sin esto, un error en el telefono de un conductor solo se conoce si el
conductor lo cuenta, y lo que cuenta es "se cerro". La app anota cada fallo en
el telefono -sin senal, como todo- y lo sube cuando engancha; aca queda una
fila por fallo en la tabla `Errores`, con la traza, la version del APK y el
modelo del telefono.

Va por el backend y a Airtable, no a un servicio de reporte de fallos: la
politica de privacidad dice que la app no usa ninguno de terceros, y la base es
lo que el equipo ya mira todos los dias.

Lo que se cuida:

- **Reintentar no duplica.** Cada informe trae el UUID que le puso el telefono
  y se escribe con upsert por ese codigo.
- **Una tanda son pocas llamadas.** Airtable topa en cinco por segundo para
  todos, sincronizacion incluida; los informes entran de a diez por llamada.
- **De quien es.** Cada fila lleva el `Auth UID`: es lo que permite borrarlas
  con la cuenta (`services/cuenta.py`).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from ..config import Settings
from ..schemas_errores import ErrorApp, ErroresRequest, ErroresResponse
from . import airtable
from .auth import Identidad

CAMPO_CODIGO = "Codigo error"


def _fila(e: ErrorApp, identidad: Identidad, recibido: str) -> dict[str, Any]:
    version = e.version_nombre or ""
    if e.version_code is not None:
        version = f"{version}+{e.version_code}" if version else f"+{e.version_code}"
    campos: dict[str, Any] = {
        CAMPO_CODIGO: e.codigo,
        # El primer renglon, que es lo que se lee en la grilla sin abrir la fila.
        "Mensaje": e.mensaje.strip(),
        "Traza": e.traza,
        "Donde": e.donde,
        "Ocurrio en": e.ocurrio_en.astimezone(timezone.utc).isoformat(),
        "Recibido en": recibido,
        "Veces": e.veces,
        "Version": version or None,
        "Version code": e.version_code,
        "Sistema": e.sistema,
        "Persona": identidad.nombre or identidad.correo or None,
        "Auth UID": identidad.auth_uid,
    }
    # Un campo vacio no se manda: Airtable lo deja en blanco igual, y mandarlo
    # como null pisa lo que hubiera en un reintento que trajo menos datos.
    return {k: v for k, v in campos.items() if v is not None and v != ""}


async def registrar(
    settings: Settings, identidad: Identidad, req: ErroresRequest
) -> ErroresResponse:
    recibido = datetime.now(timezone.utc).isoformat()
    filas = [_fila(e, identidad, recibido) for e in req.errores]
    await airtable.upsert_lote(
        settings, settings.airtable_tabla_errores, CAMPO_CODIGO, filas
    )
    return ErroresResponse(recibidos=[e.codigo for e in req.errores])


async def borrar_de(settings: Settings, auth_uid: str) -> None:
    """Borra los informes de una cuenta. Parte de la baja de cuenta."""
    filas = await airtable.listar(
        settings,
        settings.airtable_tabla_errores,
        airtable.formula_codigo("Auth UID", auth_uid),
    )
    await airtable.borrar(
        settings, settings.airtable_tabla_errores, [f["id"] for f in filas]
    )
