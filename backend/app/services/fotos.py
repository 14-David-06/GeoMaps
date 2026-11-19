"""Las fotos de los puntos marcados.

Un punto dice "alcantarilla tapada"; la foto dice cuanto. Se toman en el lote,
sin senal, y suben despues como todo lo demas.

## Por donde viaja la foto

No pasa por este backend. El telefono:

1. pide a donde subirla (`pedir_subida`): recibe una URL prefirmada de PUT;
2. la sube directo al bucket;
3. avisa que ya esta (`confirmar`): recien ahi se escribe la fila en
   `Archivos`, con el adjunto para verla en Airtable sin bajar nada.

Es el mismo orden que con los trazados -primero S3, despues Airtable- y por la
misma razon: una fila que apunta a un archivo que no existe es una foto que en
la base parece estar y al abrirla no esta.

## Lo que se cuida

- **De quien es el punto.** El codigo del punto lo manda el telefono, asi que
  no se le cree: el punto tiene que existir y colgar de un proyecto de quien
  pide. Sin eso, cualquiera que conozca el codigo de un punto ajeno le cuelga
  fotos.
- **La llave la arma el backend**, con el proyecto real, el punto y el codigo
  de la foto. El telefono nunca dice en que lugar del bucket escribir.
- **El peso.** Una URL prefirmada de PUT no puede limitar el tamano, asi que se
  mira despues: si lo que subio pesa mas que el tope, se borra y se rechaza.
- **Reintentar no duplica.** Misma foto, misma llave, misma fila.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any

from fastapi import HTTPException

from ..config import Settings
from ..schemas_fotos import (
    MAX_BYTES_FOTO,
    FotoConfirmacion,
    FotoConfirmada,
    FotoPedido,
    FotoSubida,
)
from . import airtable, almacenamiento, sincronizacion
from .auth import Identidad

TIPO = "image/jpeg"

# Lo que se le contesta al telefono cuando el punto todavia no esta arriba, o
# no es suyo. El mismo mensaje para los dos casos: no se le confirma a nadie
# que el codigo de un punto ajeno existe.
_SIN_PUNTO = (
    "El punto de esta foto todavia no esta en la base. Sube cuando suba el punto."
)


async def _contexto(
    settings: Settings,
    identidad: Identidad,
    proyecto_codigo: str,
    waypoint_codigo: str,
) -> tuple[str, str, str, str]:
    """Quien pide, en que proyecto y sobre que punto, todo verificado.

    Devuelve `(usuario_id, codigo_proyecto, proyecto_id, waypoint_id)`.
    """
    usuario = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        airtable.formula_codigo("Auth UID", identidad.auth_uid),
    )
    if not usuario:
        raise HTTPException(
            status_code=403,
            detail="Tu cuenta no esta en la base. Escribinos para revisarla.",
        )

    codigo_proyecto, proyecto_id = await sincronizacion.proyecto_de(
        settings, identidad, usuario["id"], proyecto_codigo
    )

    punto = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_waypoints,
        airtable.formula_codigo("Codigo waypoint", waypoint_codigo),
    )
    if not punto or proyecto_id not in punto.get("fields", {}).get("Proyecto", []):
        raise HTTPException(status_code=409, detail=_SIN_PUNTO)

    return usuario["id"], codigo_proyecto, proyecto_id, punto["id"]


async def pedir_subida(
    settings: Settings, identidad: Identidad, req: FotoPedido
) -> FotoSubida:
    _, codigo_proyecto, _, _ = await _contexto(
        settings, identidad, req.proyecto_codigo, req.waypoint_codigo
    )
    llave = almacenamiento.llave_foto(codigo_proyecto, req.waypoint_codigo, req.codigo)
    return FotoSubida(
        url=almacenamiento.url_escritura(settings, llave, TIPO),
        llave=llave,
        content_type=TIPO,
        vence_en_s=settings.s3_ttl_escritura,
    )


async def confirmar(
    settings: Settings, identidad: Identidad, codigo: str, req: FotoConfirmacion
) -> FotoConfirmada:
    usuario_id, codigo_proyecto, proyecto_id, waypoint_id = await _contexto(
        settings, identidad, req.proyecto_codigo, req.waypoint_codigo
    )
    llave = almacenamiento.llave_foto(codigo_proyecto, req.waypoint_codigo, codigo)

    peso = await asyncio.to_thread(almacenamiento.tamano, settings, llave)
    if peso is None:
        raise HTTPException(
            status_code=409,
            detail="La foto todavia no llego al servidor. Se vuelve a subir sola.",
        )
    if peso > MAX_BYTES_FOTO:
        await asyncio.to_thread(almacenamiento.borrar, settings, llave)
        raise HTTPException(
            status_code=413,
            detail="La foto pesa demasiado para subirla. Tomala de nuevo desde "
            "la app, que la guarda mas liviana.",
        )

    tabla = settings.airtable_tabla_archivos
    existente = await airtable.buscar_uno(
        settings, tabla, airtable.formula_codigo("Codigo archivo", codigo)
    )
    # Igual que con trazados y puntos: el UUID lo genera el telefono, y sin
    # esto quien conozca el codigo de una foto ajena le pisa la fila.
    if existente and proyecto_id not in existente.get("fields", {}).get("Proyecto", []):
        raise HTTPException(
            status_code=409,
            detail="Ese codigo de foto ya esta usado por otro registro.",
        )

    tomada = req.tomada_en or datetime.now(timezone.utc)
    campos: dict[str, Any] = {
        "Codigo archivo": codigo,
        "Nombre": f"{codigo}.jpg",
        "Tipo": "Foto",
        "Llave S3": llave,
        # Airtable copia el archivo al escribir: la URL solo tiene que durar
        # lo que tarda en ir a buscarlo.
        "Adjunto": [
            {
                "url": almacenamiento.url_lectura(settings, llave, ttl=3600),
                "filename": f"{codigo}.jpg",
            }
        ],
        "Tamano (MB)": round(peso / (1024 * 1024), 1),
        "Proyecto": [proyecto_id],
        "Waypoint": [waypoint_id],
        "Generado en": tomada.astimezone(timezone.utc).isoformat(),
        "Generado por": [usuario_id],
    }
    await airtable.guardar(
        settings, tabla, campos, existente["id"] if existente else None
    )
    return FotoConfirmada(codigo=codigo, llave=llave)
