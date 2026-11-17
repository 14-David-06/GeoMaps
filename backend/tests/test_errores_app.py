"""POST /v1/errores: los fallos que la app anoto, contra un Airtable en memoria.

Lo que se prueba es lo que, roto, deja la tabla inservible o deja al telefono
reintentando para siempre: que reintentar no duplique, que cada fila diga de
quien es, que un cuerpo desmedido se rechace, y que la baja de cuenta se lleve
los informes aunque la tabla todavia no exista.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app import main
from app.config import get_settings
from app.schemas_errores import MAXIMO_POR_TANDA, ErrorApp, ErroresRequest
from app.services import airtable, cuenta, errores_app
from app.services.auth import Identidad

pytestmark = pytest.mark.anyio

ANA = Identidad(auth_uid="pwd_ana", correo="ana@x.co", nombre="Ana Gomez", foto=None)
BETO = Identidad(auth_uid="pwd_beto", correo="beto@x.co", nombre="", foto=None)


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


class TablaFalsa:
    """Lo minimo de Airtable que usan los informes: upsert por codigo de a
    diez, listar por `Auth UID` y borrar."""

    def __init__(self) -> None:
        self.filas: dict[str, dict[str, Any]] = {}
        self.llamadas: list[int] = []
        self.existe = True

    def _revisar(self) -> None:
        if not self.existe:
            raise HTTPException(
                status_code=502,
                detail='Airtable respondio 403: {"error":{"type":'
                '"INVALID_PERMISSIONS_OR_MODEL_NOT_FOUND"}}',
            )

    async def upsert_lote(self, settings, tabla, campo_codigo, filas):
        self._revisar()
        assert tabla == settings.airtable_tabla_errores
        for i in range(0, len(filas), 10):
            parte = filas[i : i + 10]
            self.llamadas.append(len(parte))
            for f in parte:
                self.filas.setdefault(f[campo_codigo], {}).update(f)

    async def listar(self, settings, tabla, formula):
        if tabla != settings.airtable_tabla_errores:
            return []
        self._revisar()
        uid = formula.split("='")[1].rstrip("'")
        return [
            {"id": codigo, "fields": f}
            for codigo, f in self.filas.items()
            if f.get("Auth UID") == uid
        ]

    async def borrar(self, settings, tabla, ids):
        if tabla != settings.airtable_tabla_errores:
            return
        for rid in ids:
            del self.filas[rid]


@pytest.fixture
def tabla(monkeypatch) -> TablaFalsa:
    t = TablaFalsa()
    monkeypatch.setattr(airtable, "upsert_lote", t.upsert_lote)
    monkeypatch.setattr(airtable, "listar", t.listar)
    monkeypatch.setattr(airtable, "borrar", t.borrar)
    return t


def _error(codigo: str = "err-0001", **cambios) -> ErrorApp:
    datos = {
        "codigo": codigo,
        "mensaje": "RangeError (index): Invalid value: Not in inclusive range 0..2: 3",
        "traza": "#0 List.[] (dart:core)\n#1 PanelRuta.build (capa_ruta.dart:201)",
        "donde": "widgets library",
        "ocurrio_en": datetime(2026, 11, 17, 15, 30, tzinfo=timezone.utc),
        "veces": 1,
        "version_code": 11,
        "version_nombre": "0.2.7",
        "sistema": "OPPO CPH2637 · Android 14",
    }
    datos.update(cambios)
    return ErrorApp(**datos)


async def _mandar(ident: Identidad, *errores: ErrorApp):
    return await errores_app.registrar(
        get_settings(), ident, ErroresRequest(errores=list(errores))
    )


async def test_guarda_el_informe_con_quien_y_con_que_version(tabla):
    r = await _mandar(ANA, _error())

    assert r.recibidos == ["err-0001"]
    fila = tabla.filas["err-0001"]
    assert fila["Mensaje"].startswith("RangeError")
    assert fila["Version"] == "0.2.7+11"
    assert fila["Sistema"] == "OPPO CPH2637 · Android 14"
    assert fila["Persona"] == "Ana Gomez"
    assert fila["Auth UID"] == "pwd_ana"
    assert fila["Ocurrio en"] == "2026-11-17T15:30:00+00:00"


async def test_reintentar_no_duplica(tabla):
    # La red rural corta a mitad de una subida mas seguido de lo que parece: el
    # telefono vuelve a mandar lo mismo, y tiene que quedar una sola fila.
    await _mandar(ANA, _error(veces=3))
    await _mandar(ANA, _error(veces=3))

    assert list(tabla.filas) == ["err-0001"]
    assert tabla.filas["err-0001"]["Veces"] == 3


async def test_una_tanda_entera_son_dos_llamadas(tabla):
    # Airtable acepta diez filas por llamada y cinco llamadas por segundo para
    # todos: veinte informes no pueden costar veinte.
    errores = [_error(f"err-{i:04d}") for i in range(MAXIMO_POR_TANDA)]
    r = await _mandar(ANA, *errores)

    assert tabla.llamadas == [10, 10]
    assert len(r.recibidos) == MAXIMO_POR_TANDA


async def test_sin_nombre_queda_el_correo_y_los_vacios_no_viajan(tabla):
    await _mandar(BETO, _error(traza=None, donde=None, sistema=None))

    fila = tabla.filas["err-0001"]
    assert fila["Persona"] == "beto@x.co"
    assert "Traza" not in fila and "Donde" not in fila and "Sistema" not in fila


def test_un_cuerpo_desmedido_se_rechaza():
    with pytest.raises(ValidationError):
        ErroresRequest(errores=[_error(f"err-{i:04d}") for i in range(21)])
    with pytest.raises(ValidationError):
        _error(traza="x" * 8001)
    with pytest.raises(ValidationError):
        ErroresRequest(errores=[])


def test_pide_sesion():
    # Con la llave de la app y sin sesion: cualquiera con la llave del APK
    # podria llenar la tabla.
    llave = get_settings().app_api_key
    r = TestClient(main.app).post(
        "/v1/errores",
        headers={"X-API-Key": llave} if llave else {},
        json={"errores": [_error().model_dump(mode="json")]},
    )
    assert r.status_code == 401
    assert "token de sesion" in r.json()["detail"]


async def test_la_baja_de_cuenta_se_lleva_sus_informes_y_no_los_ajenos(tabla):
    await _mandar(ANA, _error("err-ana-1"), _error("err-ana-2"))
    await _mandar(BETO, _error("err-beto-1"))

    await errores_app.borrar_de(get_settings(), "pwd_ana")

    assert list(tabla.filas) == ["err-beto-1"]


async def test_sin_la_tabla_la_baja_de_cuenta_sigue(tabla, monkeypatch):
    # La tabla se crea a mano con un script; una base que todavia no la tiene
    # no puede dejar a alguien sin poder borrar su cuenta.
    tabla.existe = False
    s = get_settings()
    borrados: list[str] = []

    async def buscar_uno(settings, t, formula):
        return {"id": "usu-ana", "fields": {"Auth UID": "pwd_ana", "Rol": "Usuario"}}

    async def borrar(settings, t, ids):
        borrados.extend(ids)

    monkeypatch.setattr(airtable, "buscar_uno", buscar_uno)
    monkeypatch.setattr(airtable, "borrar", borrar)

    await cuenta.eliminar(s, ANA)

    assert borrados == ["usu-ana"]


async def test_sin_la_tabla_la_subida_falla_y_el_telefono_reintenta(tabla):
    tabla.existe = False
    with pytest.raises(HTTPException) as e:
        await _mandar(ANA, _error())
    assert airtable.falta_esquema(e.value)
