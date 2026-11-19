"""El endpoint POST /v1/sync: recibe todo lo que el telefono hizo sin senal.

Orden de escritura, que no es arbitrario porque Airtable necesita los enlaces
resueltos:

    Proyectos -> Mapas -> Trazados -> Waypoints -> Archivos -> Sincronizaciones

Hoy suben los proyectos que se crearon en el telefono, los trazados y los
puntos marcados. Las fotos de los puntos van aparte (`services/fotos.py`),
porque no pasan por aca: suben directo al bucket.

Lo que devuelve importa tanto como lo que escribe: por cada UUID enviado, si
quedo o no y por que. El telefono marca `sincronizado = true` solo los que el
backend confirmo, asi que una subida a medias reintenta exactamente lo que
falto y nada mas.

## El proyecto `local`

Lo que se levanta sin haber elegido un proyecto cae, en el telefono, en el
proyecto `local`, que es una cadena fija y la misma en todos los telefonos. En
Airtable no puede ser una sola fila: mezclaria las rutas de todas las cuentas y
el prefijo de S3 de todas. Por eso se traduce a un proyecto por cuenta,
`local-<Auth UID>`, que se crea la primera vez con el dueno puesto. Asi el
aislamiento sigue colgando de `Dueno Auth UID` como en el resto de la base.

Los proyectos que la persona crea en la app viajan en `proyectos`, con el UUID
que les puso el telefono, y suben antes que lo que cuelga de ellos. Ese codigo
tiene que ser un UUID justamente para que nadie pueda mandar un `local-...`
ajeno (ver `ProyectoSync`).
"""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import HTTPException

from ..config import Settings
from ..schemas_sync import (
    METODOS_CAPTURA,
    MOTIVOS_RUTA,
    SIMBOLOS_WAYPOINT,
    TIPOS_TRAZADO,
    ProyectoSync,
    ResultadoItem,
    SyncRequest,
    SyncResponse,
    TrazadoSync,
    WaypointSync,
)
from . import airtable, almacenamiento, camiones, geometria
from .auth import Identidad, formula_del_duenno

PROYECTO_LOCAL = "local"


class RechazoItem(Exception):
    """Un trazado que no se puede guardar, con el motivo para el telefono.

    Corta ese trazado y no la tanda: que uno venga mal no puede dejar sin subir
    los otros nueve.
    """


async def sincronizar(
    settings: Settings, identidad: Identidad, req: SyncRequest
) -> SyncResponse:
    inicio = datetime.now(timezone.utc)
    usuario = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        airtable.formula_codigo("Auth UID", identidad.auth_uid),
    )
    if not usuario:
        # El JWT es valido pero la fila no esta: la borraron a mano. Sin ella no
        # hay a quien colgarle el trabajo, y subirlo huerfano es peor.
        raise HTTPException(
            status_code=403,
            detail="Tu cuenta no esta en la base. Escribinos para revisarla.",
        )

    proyectos: dict[str, tuple[str, str]] = {}

    # Los proyectos primero: lo que sigue se cuelga de ellos.
    subidos: list[ResultadoItem] = []
    for p in req.proyectos:
        try:
            proyecto_id = await _subir_proyecto(settings, identidad, usuario["id"], p)
            proyectos[p.codigo] = (p.codigo, proyecto_id)
            subidos.append(ResultadoItem(codigo=p.codigo, ok=True))
        except RechazoItem as exc:
            subidos.append(ResultadoItem(codigo=p.codigo, ok=False, error=str(exc)))
        except HTTPException as exc:
            subidos.append(
                ResultadoItem(codigo=p.codigo, ok=False, error=str(exc.detail))
            )
        except Exception as exc:  # noqa: BLE001 -- red: reintentable.
            subidos.append(
                ResultadoItem(
                    codigo=p.codigo,
                    ok=False,
                    error=f"No se pudo guardar el proyecto ({type(exc).__name__}). "
                    "Se reintenta en la proxima sincronizacion.",
                )
            )

    resultados: list[ResultadoItem] = []
    for t in req.trazados:
        await _cerrar_vuelta(settings, identidad, t)
        try:
            if t.proyecto_codigo not in proyectos:
                proyectos[t.proyecto_codigo] = await _proyecto(
                    settings, identidad, usuario["id"], t.proyecto_codigo
                )
            codigo_proyecto, proyecto_id = proyectos[t.proyecto_codigo]
            llave = await _trazado(
                settings, t, codigo_proyecto, proyecto_id, usuario["id"]
            )
            resultados.append(ResultadoItem(codigo=t.codigo, ok=True, llave_geometria=llave))
        except (RechazoItem, geometria.GeometriaInvalida) as exc:
            resultados.append(ResultadoItem(codigo=t.codigo, ok=False, error=str(exc)))
        except HTTPException as exc:
            resultados.append(
                ResultadoItem(codigo=t.codigo, ok=False, error=str(exc.detail))
            )
        except Exception as exc:  # noqa: BLE001 -- boto3, red: reintentable.
            resultados.append(
                ResultadoItem(
                    codigo=t.codigo,
                    ok=False,
                    error=f"No se pudo guardar la geometria ({type(exc).__name__}). "
                    "Se reintenta en la proxima sincronizacion.",
                )
            )

    # Los puntos van despues de los trazados a proposito: un punto marcado
    # durante un recorrido se enlaza a su fila, y para eso tiene que existir.
    puntos: list[ResultadoItem] = []
    for w in req.waypoints:
        try:
            if w.proyecto_codigo not in proyectos:
                proyectos[w.proyecto_codigo] = await _proyecto(
                    settings, identidad, usuario["id"], w.proyecto_codigo
                )
            _, proyecto_id = proyectos[w.proyecto_codigo]
            await _waypoint(settings, w, proyecto_id, usuario["id"])
            puntos.append(ResultadoItem(codigo=w.codigo, ok=True))
        except RechazoItem as exc:
            puntos.append(ResultadoItem(codigo=w.codigo, ok=False, error=str(exc)))
        except HTTPException as exc:
            puntos.append(
                ResultadoItem(codigo=w.codigo, ok=False, error=str(exc.detail))
            )
        except Exception as exc:  # noqa: BLE001 -- red: reintentable.
            puntos.append(
                ResultadoItem(
                    codigo=w.codigo,
                    ok=False,
                    error=f"No se pudo guardar el punto ({type(exc).__name__}). "
                    "Se reintenta en la proxima sincronizacion.",
                )
            )

    await _anotar(settings, usuario["id"], inicio, subidos + resultados + puntos)
    return SyncResponse(trazados=resultados, waypoints=puntos, proyectos=subidos)


async def _subir_proyecto(
    settings: Settings, identidad: Identidad, usuario_id: str, p: ProyectoSync
) -> str:
    """Crea o actualiza un proyecto del telefono. Devuelve su record id.

    El codigo es un UUID que genero el telefono, asi que no se le cree que sea
    suyo: si ya existe con otro dueno, se rechaza. Sin eso, quien conozca el
    codigo de un proyecto ajeno se lo queda con solo subirlo.
    """
    tabla = settings.airtable_tabla_proyectos
    existente = await airtable.buscar_uno(
        settings, tabla, airtable.formula_codigo("Codigo proyecto", p.codigo)
    )
    if existente and (
        existente.get("fields", {}).get("Dueno Auth UID") != identidad.auth_uid
    ):
        raise RechazoItem("Ese codigo de proyecto ya esta usado por otro registro.")

    campos: dict[str, Any] = {
        "Codigo proyecto": p.codigo,
        "Nombre": p.nombre.strip(),
        "Estado": "Activo" if p.activo else "Cerrado",
        "Dueno Auth UID": identidad.auth_uid,
        "Dueno": [usuario_id],
    }
    opcionales = {
        "Cliente": (p.cliente or "").strip() or None,
        "Municipio": (p.municipio or "").strip() or None,
    }
    campos.update({k: v for k, v in opcionales.items() if v is not None})

    fila = await airtable.guardar(
        settings, tabla, campos, existente["id"] if existente else None
    )
    return fila["id"]


async def proyecto_de(
    settings: Settings, identidad: Identidad, usuario_id: str, codigo: str
) -> tuple[str, str]:
    """Lo mismo que `_proyecto`, para quien no sube una tanda sino un solo
    registro (las fotos): si el proyecto no es de quien pide, es un 409 y no
    un item rechazado."""
    try:
        return await _proyecto(settings, identidad, usuario_id, codigo)
    except RechazoItem as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from None


async def _proyecto(
    settings: Settings, identidad: Identidad, usuario_id: str, codigo: str
) -> tuple[str, str]:
    """El codigo real del proyecto y su record id, verificando que sea suyo."""
    real = _codigo_local(identidad.auth_uid) if codigo == PROYECTO_LOCAL else codigo
    tabla = settings.airtable_tabla_proyectos
    fila = await airtable.buscar_uno(
        settings,
        tabla,
        f"AND({airtable.formula_codigo('Codigo proyecto', real)}, "
        f"{formula_del_duenno(identidad.auth_uid)})",
    )
    if fila:
        return real, fila["id"]

    if codigo != PROYECTO_LOCAL:
        # Mismo mensaje exista o no con otro dueno: no se confirma a nadie que
        # un codigo ajeno existe.
        raise RechazoItem(
            "El proyecto de este trazado todavia no esta en la base. Se reintenta "
            "cuando suba el proyecto."
        )

    creada = await airtable.guardar(
        settings,
        tabla,
        {
            "Codigo proyecto": real,
            "Nombre": "Sin proyecto",
            "Estado": "Activo",
            "Dueno Auth UID": identidad.auth_uid,
            "Dueno": [usuario_id],
        },
        None,
    )
    return real, creada["id"]


def _codigo_local(auth_uid: str) -> str:
    # El Auth UID es el `sub` de Google (digitos) o `pwd_<uuid4>`: ya es seguro
    # como pedazo de llave de S3 y de formula. Se limpia igual por si acaso.
    limpio = "".join(c for c in auth_uid if c.isalnum() or c in "-_")
    return f"{PROYECTO_LOCAL}-{limpio}"


async def _trazado(
    settings: Settings,
    t: TrazadoSync,
    codigo_proyecto: str,
    proyecto_id: str,
    usuario_id: str,
) -> str:
    """Sube un trazado: primero el GeoJSON a S3, despues la fila. Devuelve la llave."""
    puntos = geometria.coordenadas_de_linea(t.geometria)

    tabla = settings.airtable_tabla_trazados
    existente = await airtable.buscar_uno(
        settings, tabla, airtable.formula_codigo("Codigo trazado", t.codigo)
    )
    # El UUID lo genera el telefono, asi que el backend no puede creerle que sea
    # suyo: sin esto, alguien que conozca el codigo de un trazado ajeno lo pisa.
    if existente and proyecto_id not in existente.get("fields", {}).get("Proyecto", []):
        raise RechazoItem("Ese codigo de trazado ya esta usado por otro registro.")

    # Primero S3. Una fila con `Llave geometria` apuntando a un objeto que no
    # existe es un trazado que en la base parece estar y al abrirlo no esta.
    llave = almacenamiento.llave_geometria(codigo_proyecto, t.codigo)
    contenido = json.dumps(t.geometria, separators=(",", ":")).encode()
    await asyncio.to_thread(
        almacenamiento.subir, settings, llave, contenido, "application/geo+json"
    )

    campos: dict[str, Any] = {
        "Codigo trazado": t.codigo,
        "Nombre": t.nombre.strip(),
        "Tipo": TIPOS_TRAZADO[t.tipo],
        "Metodo": METODOS_CAPTURA[t.metodo],
        "Llave geometria": llave,
        "Vista previa": geometria.vista_previa(puntos),
        "Puntos": len(puntos),
        "Proyecto": [proyecto_id],
        "Capturado por": [usuario_id],
    }
    opcionales = {
        "Distancia (m)": _redondeo(t.distancia_m, 1),
        "Area (ha)": _redondeo(t.area_ha, 4),
        "Precision media (m)": _redondeo(t.precision_media_m, 1),
        "Bbox": t.bbox,
        "Centro lat": _redondeo(t.centro_lat, 6),
        "Centro lon": _redondeo(t.centro_lon, 6),
        "Iniciado en": t.iniciado_en.isoformat() if t.iniciado_en else None,
        "Terminado en": t.terminado_en.isoformat() if t.terminado_en else None,
    }
    campos.update({k: v for k, v in opcionales.items() if v is not None})

    record_id = existente["id"] if existente else None
    calificacion = _calificacion(t)
    if not calificacion:
        await airtable.guardar(settings, tabla, campos, record_id)
        return llave

    try:
        await airtable.guardar(settings, tabla, {**campos, **calificacion}, record_id)
    except HTTPException as exc:
        # Los campos de la calificacion se agregaron despues que la tabla. Si
        # en esta base todavia no existen, el recorrido sube igual sin ellos:
        # la calificacion ya quedo adentro del GeoJSON de S3, y un campo que
        # falta en Airtable no puede dejar el viaje de alguien sin subir.
        if "UNKNOWN_FIELD_NAME" not in str(exc.detail):
            raise
        await airtable.guardar(settings, tabla, campos, record_id)
    return llave


async def _cerrar_vuelta(
    settings: Settings, identidad: Identidad, t: TrazadoSync
) -> None:
    """Si el recorrido es de una vuelta de camiones, guarda su seguimiento.

    Va antes de subir la geometria y no depende de ella: cerrar la vuelta es
    lo que le permite al conductor tomar la siguiente, y eso no puede esperar
    a que S3 acepte el archivo. Nunca hace fallar el trazado: si no se pudo,
    el recorrido sube igual y el seguimiento se reintenta con el.
    """
    if t.viaje is None:
        return
    try:
        await camiones.seguimiento(
            settings,
            identidad,
            t.viaje.codigo,
            t.viaje.model_copy(update={"trazado": t.viaje.trazado or t.codigo}),
        )
    except Exception:  # noqa: BLE001
        pass


def _calificacion(t: TrazadoSync) -> dict[str, Any]:
    """Los campos de la calificacion de la ruta, si la hubo."""
    if t.calificacion is None:
        return {}
    motivos = ", ".join(MOTIVOS_RUTA.get(m, m) for m in t.calificacion_motivos or [])
    comentario = (t.calificacion_comentario or "").strip()
    campos: dict[str, Any] = {"Calificacion": t.calificacion}
    if motivos:
        campos["Motivos calificacion"] = motivos
    if comentario:
        campos["Comentario calificacion"] = comentario
    return campos


async def _waypoint(
    settings: Settings,
    w: WaypointSync,
    proyecto_id: str,
    usuario_id: str,
) -> None:
    """Sube un punto marcado. Todo cabe en la fila: no hay nada que mandar a S3."""
    tabla = settings.airtable_tabla_waypoints
    existente = await airtable.buscar_uno(
        settings, tabla, airtable.formula_codigo("Codigo waypoint", w.codigo)
    )
    # Igual que con los trazados: el UUID lo genera el telefono, y sin esto
    # quien conozca el codigo de un punto ajeno lo pisa.
    if existente and proyecto_id not in existente.get("fields", {}).get("Proyecto", []):
        raise RechazoItem("Ese codigo de punto ya esta usado por otro registro.")

    campos: dict[str, Any] = {
        "Codigo waypoint": w.codigo,
        "Nombre": w.nombre.strip(),
        "Latitud": round(w.latitud, 6),
        "Longitud": round(w.longitud, 6),
        "Simbolo": SIMBOLOS_WAYPOINT[w.simbolo],
        "Marcado en": w.marcado_en.isoformat(),
        "Proyecto": [proyecto_id],
        "Marcado por": [usuario_id],
    }
    opcionales = {
        "Altitud (m)": _redondeo(w.altitud_m, 1),
        "Precision (m)": _redondeo(w.precision_m, 1),
        "Nota": (w.nota or "").strip() or None,
    }
    campos.update({k: v for k, v in opcionales.items() if v is not None})

    if w.trazado_codigo:
        trazado = await airtable.buscar_uno(
            settings,
            settings.airtable_tabla_trazados,
            airtable.formula_codigo("Codigo trazado", w.trazado_codigo),
        )
        # Se enlaza solo si el recorrido es del mismo proyecto, que es de quien
        # sube. Si todavia no subio -o se borro del telefono antes de subir- el
        # punto queda sin enlace: sigue siendo un punto valido.
        if trazado and proyecto_id in trazado.get("fields", {}).get("Proyecto", []):
            campos["Trazado"] = [trazado["id"]]

    await airtable.guardar(settings, tabla, campos, existente["id"] if existente else None)


def _redondeo(valor: float | None, decimales: int) -> float | None:
    return None if valor is None else round(valor, decimales)


async def _anotar(
    settings: Settings,
    usuario_id: str,
    inicio: datetime,
    resultados: list[ResultadoItem],
) -> None:
    """La fila de `Sincronizaciones`. Nunca hace fallar la subida.

    Es lo que permite responder "el trazado del martes no aparece" sin adivinar,
    pero si Airtable no la acepta, lo que ya se subio quedo subido igual y el
    telefono tiene que enterarse.
    """
    if not resultados:
        return
    fallidos = [r for r in resultados if not r.ok]
    estado = "Ok" if not fallidos else ("Fallida" if len(fallidos) == len(resultados) else "Parcial")
    try:
        await airtable.guardar(
            settings,
            settings.airtable_tabla_sincronizaciones,
            {
                "Codigo sync": str(uuid.uuid4()),
                "Inicio": inicio.isoformat(),
                "Fin": datetime.now(timezone.utc).isoformat(),
                "Registros enviados": len(resultados),
                "Registros fallidos": len(fallidos),
                "Estado": estado,
                "Detalle": "\n".join(f"{r.codigo}: {r.error}" for r in fallidos) or None,
                "Usuario": [usuario_id],
            },
            None,
        )
    except Exception:  # noqa: BLE001
        pass
