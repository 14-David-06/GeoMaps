"""El seguimiento de las vueltas de camiones, en la tabla `Vueltas` de Airtable.

Una fila es **una vuelta tomada por una cuenta**: cuando la tomo y desde donde,
cuando llego a los vagones, cuando volvio y cuando la finalizo. La planilla de
SiriusFleet solo tiene la hora de salida; lo que pasa despues -si de verdad
fue, si volvio- vive aca.

Sirve para dos cosas:

- **El seguimiento.** Coordinacion abre la tabla y ve cada vuelta con sus
  horas, sin bajar ningun archivo. El recorrido completo del GPS esta en
  `Trazados`, enlazado por `Codigo trazado`.
- **Una vuelta a la vez.** Mientras una cuenta tenga una fila en `En camino` o
  `En el punto`, no puede tomar otra. Es la regla que antes dependia de que el
  telefono se acordara: reinstalar la app la borraba.

## Si la tabla no existe

Todo lo de aca levanta `SinControl` y quien llama sigue sin seguimiento: las
vueltas se toman igual, anotadas en la planilla. Una tabla sin crear no puede
dejar a los camiones parados; lo que se pierde es el control, y por eso la
lista le dice a la app si lo hay (`VueltasResponse.control`).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from fastapi import HTTPException

from ..config import Settings
from ..schemas_camiones import Posicion, ViajeAbierto, Vuelta
from . import airtable

EN_CAMINO = "En camino"
EN_PUNTO = "En el punto"
FINALIZADA = "Finalizada"
DEVUELTA = "Devuelta"

# Los estados en que la cuenta sigue ocupada con esa vuelta.
ABIERTOS = (EN_CAMINO, EN_PUNTO)

# La opcion del Single select -> como la nombra la app.
CLAVES: dict[str, str] = {
    EN_CAMINO: "en_camino",
    EN_PUNTO: "en_punto",
    FINALIZADA: "finalizada",
    DEVUELTA: "devuelta",
}


class SinControl(Exception):
    """La tabla `Vueltas` no existe, o le faltan campos: no hay seguimiento."""


def _falta_la_tabla(exc: HTTPException) -> bool:
    """Si el error de Airtable es de esquema y no de red. La regla vive en
    `airtable.falta_esquema`, que tambien usa la baja de cuenta."""
    return airtable.falta_esquema(exc)


def _tabla(settings: Settings) -> str:
    return settings.airtable_tabla_vueltas


def _abierta() -> str:
    return "OR(" + ", ".join(f"{{Estado}}='{e}'" for e in ABIERTOS) + ")"


async def _listar(settings: Settings, formula: str) -> list[dict[str, Any]]:
    try:
        return await airtable.listar(settings, _tabla(settings), formula)
    except HTTPException as exc:
        if _falta_la_tabla(exc):
            raise SinControl() from exc
        raise


async def abierto(settings: Settings, auth_uid: str) -> dict[str, Any] | None:
    """La vuelta sin finalizar de esta cuenta, o None.

    No deberia haber mas de una; si la hay -dos telefonos confirmando en el
    mismo segundo- manda la mas reciente.
    """
    filas = await _listar(
        settings,
        f"AND({airtable.formula_codigo('Auth UID', auth_uid)}, {_abierta()})",
    )
    if not filas:
        return None
    return max(filas, key=lambda f: f.get("fields", {}).get("Tomada en") or "")


async def de_vuelta(
    settings: Settings, auth_uid: str, vuelta_id: str
) -> dict[str, Any] | None:
    """La fila abierta de esta cuenta para ese renglon de la planilla."""
    filas = await _listar(
        settings,
        f"AND({airtable.formula_codigo('Auth UID', auth_uid)}, "
        f"{airtable.formula_codigo('Vuelta ID', vuelta_id)}, {_abierta()})",
    )
    return filas[0] if filas else None


async def por_codigo(settings: Settings, codigo: str) -> dict[str, Any] | None:
    filas = await _listar(settings, airtable.formula_codigo("Codigo viaje", codigo))
    return filas[0] if filas else None


def nombre_de(vuelta: dict[str, Any]) -> str:
    """`Vuelta #23 · B.3-P.4 · 11A`: se reconoce en la tabla sin abrir nada."""
    donde = vuelta.get("origen_codigo") or (
        f"{vuelta.get('origen_bloque') or '?'} · {vuelta.get('origen_num') or '?'}"
    )
    return f"Vuelta #{vuelta.get('consecutivo')} · {donde}"


async def crear(
    settings: Settings,
    *,
    codigo: str,
    vuelta: dict[str, Any],
    usuario_id: str,
    auth_uid: str,
    conductor: str,
    salida: Posicion | None,
) -> dict[str, Any]:
    """Abre el seguimiento de una vuelta recien tomada."""
    campos: dict[str, Any] = {
        "Codigo viaje": codigo,
        "Nombre": nombre_de(vuelta),
        "Vuelta ID": vuelta["id"],
        "Jornada": str(vuelta.get("jornada") or "")[:10] or None,
        "Consecutivo": vuelta.get("consecutivo"),
        "Acopio": vuelta.get("origen_codigo"),
        "Conductor": conductor,
        "Usuario": [usuario_id],
        "Auth UID": auth_uid,
        "Estado": EN_CAMINO,
        "Tomada en": datetime.now(timezone.utc).isoformat(),
    }
    if salida is not None:
        campos["Salida lat"] = round(salida.lat, 6)
        campos["Salida lon"] = round(salida.lon, 6)
    return await guardar(
        settings, None, {k: v for k, v in campos.items() if v is not None}
    )


async def guardar(
    settings: Settings, record_id: str | None, campos: dict[str, Any]
) -> dict[str, Any]:
    try:
        return await airtable.guardar(settings, _tabla(settings), campos, record_id)
    except HTTPException as exc:
        if _falta_la_tabla(exc):
            raise SinControl() from exc
        raise


def clave_estado(fila: dict[str, Any]) -> str:
    estado = fila.get("fields", {}).get("Estado") or EN_CAMINO
    # Un estado que este backend no conoce -lo escribio alguien a mano en la
    # tabla- cuenta como cerrado: es la forma de liberar a un conductor.
    return CLAVES.get(estado, "cerrada")


def esta_abierta(fila: dict[str, Any]) -> bool:
    return fila.get("fields", {}).get("Estado") in ABIERTOS


def a_abierto(fila: dict[str, Any], vuelta: Vuelta | None) -> ViajeAbierto:
    f = fila.get("fields", {})
    lat, lon = f.get("Salida lat"), f.get("Salida lon")
    return ViajeAbierto(
        codigo=f.get("Codigo viaje") or "",
        vuelta_id=f.get("Vuelta ID") or "",
        nombre=f.get("Nombre"),
        estado=clave_estado(fila),
        tomada_en=f.get("Tomada en"),
        salida=None if lat is None or lon is None else Posicion(lat=lat, lon=lon),
        llegada_en=f.get("Llegada en"),
        regreso_en=f.get("Regreso en"),
        vuelta=vuelta,
    )
