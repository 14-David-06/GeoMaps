"""Baja de cuenta: borrar a la persona y todo lo que subio.

Play exige que quien puede crear una cuenta desde la app pueda tambien
borrarla desde la app. Aca se cumple el procedimiento de
docs/airtable-schema.md, "Baja de cuenta", y en su orden: primero S3, despues
las filas de Airtable de las hojas a la raiz, y la fila de `Usuarios` al final.
Al reves, un corte a mitad deja archivos en el bucket sin forma de saber de
quien eran; asi, deja una cuenta que todavia existe y se puede volver a borrar.

Por eso es idempotente: si la fila de `Usuarios` ya no esta, no hay nada que
hacer, y si un corte la dejo a medias, la segunda vuelta borra lo que falto.

## Lo que no se borra

- **Las vueltas de camion en SiriusFleet.** Son la planilla operativa de la
  empresa, no datos de la cuenta: dicen que operador saco que vuelta, con el id
  del operador de SiriusFleet. La cedula que ata la cuenta al operador vive en
  `Usuarios` y se va con la fila.
- **Las cuentas de `Soporte` y `Admin`.** Pueden ser duenas de los proyectos de
  la empresa (los mapas del predio), y una baja propia se los llevaria. Esas se
  dan de baja a mano.
"""

from __future__ import annotations

import asyncio

from fastapi import HTTPException

from ..config import Settings
from . import airtable, almacenamiento, errores_app
from .auth import Identidad, formula_del_duenno

ROLES_SIN_BAJA_PROPIA = {"Soporte", "Admin"}


async def eliminar(settings: Settings, identidad: Identidad) -> None:
    usuario = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        airtable.formula_codigo("Auth UID", identidad.auth_uid),
    )
    if not usuario:
        return
    campos = usuario.get("fields", {})
    if campos.get("Rol") in ROLES_SIN_BAJA_PROPIA:
        raise HTTPException(
            status_code=409,
            detail="Las cuentas de soporte y administracion se dan de baja a "
            "mano, porque pueden ser duenas de proyectos de la empresa. "
            "Pedila a soporte.",
        )

    # Lo que cuelga de un proyecto: el enlace del proyecto -> su tabla.
    hojas = {
        "Trazados": settings.airtable_tabla_trazados,
        "Waypoints": settings.airtable_tabla_waypoints,
        "Archivos": settings.airtable_tabla_archivos,
        "Mapas": settings.airtable_tabla_mapas,
    }
    proyectos = await airtable.listar(
        settings,
        settings.airtable_tabla_proyectos,
        formula_del_duenno(identidad.auth_uid),
    )
    for proyecto in proyectos:
        fp = proyecto.get("fields", {})
        codigo = fp.get("Codigo proyecto")
        if codigo:
            await asyncio.to_thread(
                almacenamiento.borrar_prefijo, settings, f"proyectos/{codigo}/"
            )
        for enlace, tabla in hojas.items():
            await airtable.borrar(settings, tabla, fp.get(enlace) or [])
    await airtable.borrar(
        settings, settings.airtable_tabla_proyectos, [p["id"] for p in proyectos]
    )

    # Lo que cuelga de la persona y no de un proyecto.
    for enlace, tabla in {
        "Sincronizaciones": settings.airtable_tabla_sincronizaciones,
        "Dispositivos": settings.airtable_tabla_dispositivos,
    }.items():
        await airtable.borrar(settings, tabla, campos.get(enlace) or [])

    # Los informes de error no cuelgan de la fila por un enlace: llevan el
    # `Auth UID`. Si la tabla todavia no existe en la base no hay nada que
    # borrar, y eso no puede frenar la baja.
    try:
        await errores_app.borrar_de(settings, identidad.auth_uid)
    except HTTPException as e:
        if not airtable.falta_esquema(e):
            raise

    await airtable.borrar(settings, settings.airtable_tabla_usuarios, [usuario["id"]])
