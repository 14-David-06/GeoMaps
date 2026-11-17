"""Escritura y lectura en Airtable.

La regla que sostiene todo el modelo offline: **upsert por UUID, nunca create a
ciegas.** Cada tabla tiene su campo `Codigo <entidad>` con el UUID que genero el
telefono antes de tener red. El servicio busca por ese codigo con
`filterByFormula` y decide entre PATCH y POST.

Por que importa: la red movil rural corta a mitad de un POST mas seguido de lo
que parece. Sin el upsert, cada reintento de sincronizacion duplicaria el
trazado, y dos poligonos identicos con areas iguales son imposibles de
distinguir despues.

Dos detalles de la API que cuestan tiempo:

- `typecast: true` deja que Airtable convierta la cadena al tipo del campo. Sin
  el, escribir un Single select con una opcion que no existe falla con un error
  que no dice cual.
- Los adjuntos se cargan por URL: Airtable va el mismo a buscarla desde sus
  servidores. Con el bucket privado eso significa pasarle una URL prefirmada de
  lectura. Airtable copia el archivo a su propio almacenamiento al escribir, asi
  que el adjunto sigue funcionando cuando la URL vence. Lo que no sobrevive es
  lo contrario: una URL ya vencida al escribir deja el adjunto vacio y Airtable
  responde 200 igual.

Lo que Airtable guarda de S3 es la **llave**, nunca la URL. La llave es estable;
la URL vence. Una base llena de URLs prefirmadas vencidas es una base de filas
que apuntan a un 403 sin decir por que.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import httpx
from fastapi import HTTPException

from ..config import Settings

API = "https://api.airtable.com/v0"

# Airtable topa en 5 requests por segundo por base, y ese techo lo comparten el
# login y la sincronizacion. Todo lo que se pueda hacer en una sola llamada, se
# hace en una sola llamada.
TIMEOUT = 30


def _cabeceras(settings: Settings) -> dict[str, str]:
    if not settings.airtable_token or not settings.airtable_base_id:
        raise HTTPException(
            status_code=500, detail="Falta configuracion de Airtable."
        )
    return {"Authorization": f"Bearer {settings.airtable_token}"}


def _url(settings: Settings, tabla: str) -> str:
    return f"{API}/{settings.airtable_base_id}/{quote(tabla, safe='')}"


async def buscar_uno(
    settings: Settings, tabla: str, formula: str
) -> dict[str, Any] | None:
    """Primera fila que cumple la formula, o None."""
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        r = await client.get(
            _url(settings, tabla),
            headers=_cabeceras(settings),
            params={"filterByFormula": formula, "maxRecords": 1},
        )
    _revisar(r, tabla)
    registros = r.json().get("records", [])
    return registros[0] if registros else None


async def upsert(
    settings: Settings,
    tabla: str,
    campo_codigo: str,
    codigo: str,
    campos: dict[str, Any],
) -> dict[str, Any]:
    """Crea o actualiza por codigo. Es la unica forma de escribir en Airtable.

    Reintentar una sincronizacion cortada tiene que ser inofensivo, y esto es lo
    que lo hace inofensivo.
    """
    existente = await buscar_uno(settings, tabla, formula_codigo(campo_codigo, codigo))
    return await guardar(
        settings,
        tabla,
        {campo_codigo: codigo, **campos},
        existente["id"] if existente else None,
    )


def formula_codigo(campo_codigo: str, codigo: str) -> str:
    """La formula que encuentra una fila por su UUID."""
    seguro = codigo.replace("'", "")
    return f"{{{campo_codigo}}}='{seguro}'"


async def guardar(
    settings: Settings,
    tabla: str,
    campos: dict[str, Any],
    record_id: str | None,
) -> dict[str, Any]:
    """PATCH sobre `record_id`, o POST si es None.

    Es la mitad de escritura de `upsert`, aparte para quien ya busco la fila por
    su cuenta: la sincronizacion la necesita para revisar de quien es antes de
    pisarla, y buscarla dos veces gasta cupo de los 5 requests por segundo.
    """
    cuerpo = {"fields": campos, "typecast": True}
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        if record_id:
            r = await client.patch(
                f"{_url(settings, tabla)}/{record_id}",
                headers=_cabeceras(settings),
                json=cuerpo,
            )
        else:
            r = await client.post(
                _url(settings, tabla), headers=_cabeceras(settings), json=cuerpo
            )
    _revisar(r, tabla)
    return r.json()


async def upsert_lote(
    settings: Settings,
    tabla: str,
    campo_codigo: str,
    filas: list[dict[str, Any]],
) -> None:
    """Crea o actualiza varias filas por su codigo, de a diez por llamada.

    Es el upsert propio de Airtable (`performUpsert`): el mismo resultado que
    `upsert`, sin la busqueda previa por cada fila. Sirve cuando las filas son
    de quien las manda y no hay nada que revisar antes de pisarlas; la
    sincronizacion de trazados no lo usa justamente porque tiene que mirar de
    quien es cada uno.
    """
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        for i in range(0, len(filas), 10):
            r = await client.patch(
                _url(settings, tabla),
                headers=_cabeceras(settings),
                json={
                    "performUpsert": {"fieldsToMergeOn": [campo_codigo]},
                    "records": [{"fields": f} for f in filas[i : i + 10]],
                    "typecast": True,
                },
            )
            _revisar(r, tabla)


async def listar(settings: Settings, tabla: str, formula: str) -> list[dict[str, Any]]:
    """Todas las filas que cumplen la formula, recorriendo las paginas.

    Airtable devuelve de a 100 y un `offset` para seguir. Quien pide "todas"
    y se queda con la primera pagina borra o informa a medias sin enterarse.
    """
    filas: list[dict[str, Any]] = []
    params: dict[str, Any] = {"filterByFormula": formula}
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        while True:
            r = await client.get(
                _url(settings, tabla), headers=_cabeceras(settings), params=params
            )
            _revisar(r, tabla)
            cuerpo = r.json()
            filas.extend(cuerpo.get("records", []))
            if not cuerpo.get("offset"):
                return filas
            params["offset"] = cuerpo["offset"]


async def borrar(settings: Settings, tabla: str, record_ids: list[str]) -> None:
    """Borra filas por record id, de a 10: el maximo que acepta la API por
    llamada. Sin ids no llama a nada."""
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        for i in range(0, len(record_ids), 10):
            r = await client.delete(
                _url(settings, tabla),
                headers=_cabeceras(settings),
                params=[("records[]", rid) for rid in record_ids[i : i + 10]],
            )
            _revisar(r, tabla)


def falta_esquema(exc: HTTPException) -> bool:
    """Si el error de Airtable es de esquema y no de red.

    Una tabla que no existe responde 403 `INVALID_PERMISSIONS_OR_MODEL_NOT_FOUND`
    -el mismo error que no tener permiso, Airtable no los distingue- y un campo
    que falta, `UNKNOWN_FIELD_NAME` al escribir o "Unknown field names" al
    filtrar.

    Sirve a quien puede seguir sin esa tabla: una que todavia no se creo no
    puede dejar parado lo que no depende de ella.
    """
    detalle = str(exc.detail)
    return any(
        marca in detalle
        for marca in (
            "no existe en la base",
            "MODEL_NOT_FOUND",
            "TABLE_NOT_FOUND",
            "UNKNOWN_FIELD_NAME",
            "Unknown field name",
        )
    )


def _revisar(r: httpx.Response, tabla: str) -> None:
    if r.status_code == 404:
        raise HTTPException(
            status_code=500,
            detail=f"La tabla '{tabla}' no existe en la base de Airtable. "
            "Revisa docs/airtable-schema.md y el nombre en el .env.",
        )
    if r.status_code == 422:
        # Casi siempre es un campo que no existe o que se renombro en la
        # interfaz de Airtable. Decirlo asi ahorra media hora de adivinar.
        raise HTTPException(
            status_code=500,
            detail=f"Airtable rechazo los campos de '{tabla}': {r.text[:400]}. "
            "Suele ser un campo renombrado o que no existe.",
        )
    if r.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"Airtable respondio {r.status_code}: {r.text[:400]}",
        )
