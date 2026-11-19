"""Las fotos de los puntos, contra un Airtable y un S3 en memoria.

Lo que se prueba son las reglas que, rotas, mezclan datos de dos personas o
dejan filas que apuntan a nada: que nadie le cuelgue fotos a un punto ajeno,
que la llave del bucket la arme el backend, que la fila se escriba solo cuando
la foto de verdad llego, y que reintentar no duplique.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app import main
from app.config import get_settings
from app.schemas_fotos import MAX_BYTES_FOTO, FotoConfirmacion, FotoPedido
from app.services import airtable, almacenamiento, fotos
from app.services.auth import Identidad

pytestmark = pytest.mark.anyio

ANA = Identidad(auth_uid="111", correo="ana@x.co", nombre="Ana", foto=None)
BETO = Identidad(auth_uid="222", correo="beto@x.co", nombre="Beto", foto=None)

PUNTO = "punto-0001"
FOTO = "foto-00001"


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


class Mundo:
    """Lo minimo de Airtable y de S3 que usan las fotos."""

    def __init__(self) -> None:
        self.tablas: dict[str, dict[str, dict[str, Any]]] = {}
        self.s3: dict[str, int] = {}
        self.firmadas: list[tuple[str, str]] = []
        self._n = 0

    def fila(self, tabla: str, campos: dict[str, Any]) -> str:
        self._n += 1
        rid = f"rec{self._n}"
        self.tablas.setdefault(tabla, {})[rid] = dict(campos)
        return rid

    async def buscar_uno(self, settings, tabla, formula):
        condiciones = re.findall(r"\{([^}]+)\}='([^']*)'", formula)
        for rid, campos in self.tablas.get(tabla, {}).items():
            if all(str(campos.get(c)) == v for c, v in condiciones):
                return {"id": rid, "fields": campos}
        return None

    async def guardar(self, settings, tabla, campos, record_id):
        if record_id:
            self.tablas[tabla][record_id].update(campos)
        else:
            record_id = self.fila(tabla, campos)
        return {"id": record_id, "fields": self.tablas[tabla][record_id]}

    def url_escritura(self, settings, llave, content_type, ttl=None):
        self.firmadas.append((llave, content_type))
        return f"https://bucket.test/{llave}?firma=put"

    def url_lectura(self, settings, llave, ttl=None):
        return f"https://bucket.test/{llave}?firma=get"

    def tamano(self, settings, llave):
        return self.s3.get(llave)

    def borrar(self, settings, llave):
        self.s3.pop(llave, None)

    def de(self, tabla: str) -> list[dict[str, Any]]:
        return list(self.tablas.get(tabla, {}).values())


@pytest.fixture
def mundo(monkeypatch) -> Mundo:
    m = Mundo()
    monkeypatch.setattr(airtable, "buscar_uno", m.buscar_uno)
    monkeypatch.setattr(airtable, "guardar", m.guardar)
    for nombre in ("url_escritura", "url_lectura", "tamano", "borrar"):
        monkeypatch.setattr(almacenamiento, nombre, getattr(m, nombre))

    s = get_settings()
    # Ana, con su proyecto "local" y un punto ya subido.
    ana = m.fila(s.airtable_tabla_usuarios, {"Auth UID": ANA.auth_uid})
    proyecto = m.fila(
        s.airtable_tabla_proyectos,
        {
            "Codigo proyecto": "local-111",
            "Dueno Auth UID": ANA.auth_uid,
            "Dueno": [ana],
        },
    )
    m.fila(
        s.airtable_tabla_waypoints,
        {"Codigo waypoint": PUNTO, "Proyecto": [proyecto]},
    )
    # Beto, con el suyo.
    beto = m.fila(s.airtable_tabla_usuarios, {"Auth UID": BETO.auth_uid})
    m.fila(
        s.airtable_tabla_proyectos,
        {
            "Codigo proyecto": "local-222",
            "Dueno Auth UID": BETO.auth_uid,
            "Dueno": [beto],
        },
    )
    return m


LLAVE = f"proyectos/local-111/fotos/{PUNTO}/{FOTO}.jpg"


def _pedido(**cambios) -> FotoPedido:
    datos = {
        "codigo": FOTO,
        "waypoint_codigo": PUNTO,
        "proyecto_codigo": "local",
        "tamano_bytes": 420_000,
    }
    datos.update(cambios)
    return FotoPedido(**datos)


def _confirmacion(**cambios) -> FotoConfirmacion:
    datos = {
        "waypoint_codigo": PUNTO,
        "proyecto_codigo": "local",
        "tomada_en": datetime(2026, 11, 18, 14, 5, tzinfo=timezone.utc),
    }
    datos.update(cambios)
    return FotoConfirmacion(**datos)


# --- Pedir a donde subir ---------------------------------------------------


async def test_la_llave_la_arma_el_backend_bajo_el_proyecto_de_quien_pide(mundo):
    r = await fotos.pedir_subida(get_settings(), ANA, _pedido())

    assert r.llave == LLAVE
    assert r.url.startswith(f"https://bucket.test/{LLAVE}")
    assert r.content_type == "image/jpeg"
    # El tipo va firmado: con esa URL no se sube otra cosa que una foto.
    assert mundo.firmadas == [(LLAVE, "image/jpeg")]


async def test_nadie_le_cuelga_fotos_a_un_punto_ajeno(mundo):
    # Beto conoce el codigo del punto de Ana. No alcanza.
    with pytest.raises(HTTPException) as e:
        await fotos.pedir_subida(get_settings(), BETO, _pedido())

    assert e.value.status_code == 409
    assert mundo.firmadas == []


async def test_un_punto_que_todavia_no_subio_se_reintenta_despues(mundo):
    with pytest.raises(HTTPException) as e:
        await fotos.pedir_subida(
            get_settings(), ANA, _pedido(waypoint_codigo="punto-nuevo")
        )

    assert e.value.status_code == 409
    assert "cuando suba el punto" in e.value.detail


async def test_ajeno_y_inexistente_contestan_lo_mismo(mundo):
    # No se le confirma a nadie que el codigo de un punto ajeno existe.
    with pytest.raises(HTTPException) as ajeno:
        await fotos.pedir_subida(get_settings(), BETO, _pedido())
    with pytest.raises(HTTPException) as inexistente:
        await fotos.pedir_subida(
            get_settings(), BETO, _pedido(waypoint_codigo="punto-9999")
        )

    assert ajeno.value.detail == inexistente.value.detail


def test_un_codigo_no_puede_salirse_de_su_carpeta():
    # Termina adentro de una llave de S3.
    for malo in ("../../otro", "a/b/c/d/e/f", "foto 00001", "x"):
        with pytest.raises(ValidationError):
            _pedido(codigo=malo)
        with pytest.raises(ValidationError):
            _pedido(waypoint_codigo=malo)


def test_una_foto_mas_pesada_que_el_tope_ni_se_firma():
    with pytest.raises(ValidationError):
        _pedido(tamano_bytes=MAX_BYTES_FOTO + 1)


# --- Confirmar -------------------------------------------------------------


async def test_confirmar_escribe_la_fila_con_el_punto_y_el_adjunto(mundo):
    s = get_settings()
    mundo.s3[LLAVE] = 420_000

    r = await fotos.confirmar(s, ANA, FOTO, _confirmacion())

    assert r.llave == LLAVE
    (fila,) = mundo.de(s.airtable_tabla_archivos)
    assert fila["Codigo archivo"] == FOTO
    assert fila["Tipo"] == "Foto"
    assert fila["Llave S3"] == LLAVE
    assert fila["Tamano (MB)"] == 0.4
    assert fila["Generado en"] == "2026-11-18T14:05:00+00:00"
    assert fila["Adjunto"][0]["url"].endswith("firma=get")
    # Enlazada al punto y al proyecto de Ana, no a los de nadie mas.
    punto = await mundo.buscar_uno(
        s, s.airtable_tabla_waypoints, f"{{Codigo waypoint}}='{PUNTO}'"
    )
    assert fila["Waypoint"] == [punto["id"]]
    assert fila["Proyecto"] == punto["fields"]["Proyecto"]


async def test_sin_la_foto_en_el_bucket_no_hay_fila(mundo):
    # El telefono cree que subio y se le corto: la fila apuntaria a nada.
    with pytest.raises(HTTPException) as e:
        await fotos.confirmar(get_settings(), ANA, FOTO, _confirmacion())

    assert e.value.status_code == 409
    assert mundo.de(get_settings().airtable_tabla_archivos) == []


async def test_reintentar_no_duplica(mundo):
    s = get_settings()
    mundo.s3[LLAVE] = 420_000

    await fotos.confirmar(s, ANA, FOTO, _confirmacion())
    await fotos.confirmar(s, ANA, FOTO, _confirmacion())

    assert len(mundo.de(s.airtable_tabla_archivos)) == 1


async def test_lo_que_pesa_de_mas_se_borra_y_se_rechaza(mundo):
    # La URL firmada no puede limitar el tamano: se mira despues.
    mundo.s3[LLAVE] = MAX_BYTES_FOTO + 1

    with pytest.raises(HTTPException) as e:
        await fotos.confirmar(get_settings(), ANA, FOTO, _confirmacion())

    assert e.value.status_code == 413
    assert LLAVE not in mundo.s3
    assert mundo.de(get_settings().airtable_tabla_archivos) == []


async def test_el_codigo_de_una_foto_ajena_no_se_pisa(mundo):
    s = get_settings()
    # Beto ya tiene una foto con ese codigo, en su proyecto.
    proyecto_beto = await mundo.buscar_uno(
        s, s.airtable_tabla_proyectos, "{Codigo proyecto}='local-222'"
    )
    mundo.fila(
        s.airtable_tabla_archivos,
        {"Codigo archivo": FOTO, "Proyecto": [proyecto_beto["id"]]},
    )
    mundo.s3[LLAVE] = 420_000

    with pytest.raises(HTTPException) as e:
        await fotos.confirmar(s, ANA, FOTO, _confirmacion())

    assert e.value.status_code == 409
    (fila,) = mundo.de(s.airtable_tabla_archivos)
    assert fila["Proyecto"] == [proyecto_beto["id"]]


def test_las_dos_rutas_piden_sesion():
    llave = get_settings().app_api_key
    cabeceras = {"X-API-Key": llave} if llave else {}
    cliente = TestClient(main.app)

    pedir = cliente.post(
        "/v1/fotos", headers=cabeceras, json=_pedido().model_dump(mode="json")
    )
    confirmar = cliente.post(
        f"/v1/fotos/{FOTO}/confirmar",
        headers=cabeceras,
        json=_confirmacion().model_dump(mode="json"),
    )

    assert pedir.status_code == 401
    assert confirmar.status_code == 401
