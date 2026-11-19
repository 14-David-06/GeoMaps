"""POST /v1/sync contra un Airtable y un S3 en memoria.

Lo que se prueba son las reglas que, rotas, rompen datos de alguien: que el
proyecto `local` sea uno por cuenta, que nadie pise un trazado ajeno conociendo
su UUID, que S3 vaya antes que Airtable, y que reintentar no duplique.
"""

from __future__ import annotations

import re
from typing import Any

import pytest
from fastapi import HTTPException

from app.config import get_settings
from pydantic import ValidationError

from app.schemas_sync import ProyectoSync, SyncRequest, TrazadoSync, WaypointSync
from app.services import airtable, almacenamiento, sincronizacion
from app.services.auth import Identidad

# anyio ya viene con FastAPI: no hace falta otro plugin para correr las async.
pytestmark = pytest.mark.anyio

YO = Identidad(auth_uid="111", correo="yo@x.co", nombre="Yo", foto=None)
OTRO = Identidad(auth_uid="222", correo="otro@x.co", nombre="Otro", foto=None)


class BaseFalsa:
    """Lo minimo de Airtable que usa la sincronizacion: buscar por igualdades
    de una formula `AND({Campo}='valor', ...)` y guardar."""

    def __init__(self) -> None:
        self.tablas: dict[str, dict[str, dict[str, Any]]] = {}
        self.s3: dict[str, bytes] = {}
        self.orden: list[str] = []
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
        self.orden.append(f"airtable:{tabla}")
        if record_id:
            self.tablas[tabla][record_id].update(campos)
        else:
            record_id = self.fila(tabla, campos)
        return {"id": record_id, "fields": self.tablas[tabla][record_id]}

    def subir(self, settings, llave, contenido, content_type):
        self.orden.append("s3")
        self.s3[llave] = contenido
        return llave

    def de(self, tabla: str) -> list[dict[str, Any]]:
        return list(self.tablas.get(tabla, {}).values())


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture
def base(monkeypatch) -> BaseFalsa:
    b = BaseFalsa()
    monkeypatch.setattr(airtable, "buscar_uno", b.buscar_uno)
    monkeypatch.setattr(airtable, "guardar", b.guardar)
    monkeypatch.setattr(almacenamiento, "subir", b.subir)
    for ident in (YO, OTRO):
        b.fila("Usuarios", {"Auth UID": ident.auth_uid})
    return b


def _ruta(codigo: str = "ruta-0001", **cambios) -> TrazadoSync:
    datos = {
        "codigo": codigo,
        "proyecto_codigo": "local",
        "nombre": "Acopio 12",
        "tipo": "ruta",
        "metodo": "calculada",
        "geometria": {
            "type": "Feature",
            "properties": {},
            "geometry": {
                "type": "LineString",
                "coordinates": [[-72.89, 4.28], [-72.888, 4.281], [-72.885, 4.283]],
            },
        },
        "distancia_m": 612.37,
        "bbox": "-72.89,4.28,-72.885,4.283",
        "centro_lat": 4.2813333,
        "centro_lon": -72.8876667,
    }
    datos.update(cambios)
    return TrazadoSync(**datos)


async def _sync(ident: Identidad, *trazados: TrazadoSync):
    return await sincronizacion.sincronizar(
        get_settings(), ident, SyncRequest(trazados=list(trazados))
    )


async def test_sube_la_ruta_con_las_opciones_de_airtable(base):
    r = await _sync(YO, _ruta())

    assert r.trazados[0].ok, r.trazados[0].error
    [fila] = base.de("Trazados")
    assert fila["Tipo"] == "Ruta"
    assert fila["Metodo"] == "Calculada", "el .name de Dart no llega crudo"
    assert fila["Puntos"] == 3
    assert fila["Distancia (m)"] == 612.4
    assert fila["Llave geometria"] == "proyectos/local-111/geometrias/ruta-0001.geojson"
    assert fila["Llave geometria"] in base.s3
    assert r.trazados[0].llave_geometria == fila["Llave geometria"]


async def test_s3_va_antes_que_la_fila(base):
    await _sync(YO, _ruta())
    assert base.orden.index("s3") < base.orden.index("airtable:Trazados")


async def test_el_proyecto_local_es_uno_por_cuenta(base):
    await _sync(YO, _ruta("ruta-yo-0001"), _ruta("ruta-yo-0002"))
    await _sync(OTRO, _ruta("ruta-otro-001"))

    proyectos = base.de("Proyectos")
    assert sorted(p["Codigo proyecto"] for p in proyectos) == ["local-111", "local-222"]
    assert {p["Dueno Auth UID"] for p in proyectos} == {"111", "222"}


async def test_reintentar_no_duplica(base):
    await _sync(YO, _ruta())
    await _sync(YO, _ruta(nombre="Acopio 12 bis"))

    [fila] = base.de("Trazados")
    assert fila["Nombre"] == "Acopio 12 bis"


async def test_no_se_pisa_un_trazado_ajeno(base):
    await _sync(YO, _ruta("ruta-compartida"))
    r = await _sync(OTRO, _ruta("ruta-compartida", nombre="Pisado"))

    assert not r.trazados[0].ok
    [fila] = base.de("Trazados")
    assert fila["Nombre"] == "Acopio 12"


async def test_un_trazado_malo_no_frena_la_tanda(base):
    malo = _ruta(
        "ruta-mala-001",
        geometria={"type": "LineString", "coordinates": [[-72.89, 4.28], [-72.8, 95.0]]},
    )
    r = await _sync(YO, malo, _ruta("ruta-buena-01"))

    assert [t.ok for t in r.trazados] == [False, True]
    [log] = base.de("Sincronizaciones")
    assert log["Estado"] == "Parcial"
    assert log["Registros fallidos"] == 1


async def test_proyecto_ajeno_o_sin_subir_se_rechaza(base):
    r = await _sync(YO, _ruta(proyecto_codigo="proyecto-de-nadie"))
    assert not r.trazados[0].ok
    assert base.de("Trazados") == []


# --- Puntos marcados -------------------------------------------------------


def _punto(codigo: str = "punto-0001", **cambios) -> WaypointSync:
    datos = {
        "codigo": codigo,
        "proyecto_codigo": "local",
        "nombre": " Alcantarilla rota ",
        "latitud": 4.4512345678,
        "longitud": -72.9612345678,
        "precision_m": 6.44,
        "simbolo": "fuenteDeAgua",
        "nota": "Revisar antes del invierno",
        "marcado_en": "2026-11-12T14:00:00+00:00",
    }
    datos.update(cambios)
    return WaypointSync(**datos)


async def _sync_puntos(ident: Identidad, *puntos: WaypointSync, trazados=()):
    return await sincronizacion.sincronizar(
        get_settings(),
        ident,
        SyncRequest(trazados=list(trazados), waypoints=list(puntos)),
    )


async def test_sube_el_punto_con_las_opciones_de_airtable(base):
    r = await _sync_puntos(YO, _punto())

    assert r.waypoints[0].ok, r.waypoints[0].error
    [fila] = base.de("Waypoints")
    assert fila["Nombre"] == "Alcantarilla rota"
    assert fila["Simbolo"] == "Fuente de agua", "el .name de Dart no llega crudo"
    assert fila["Latitud"] == 4.451235
    assert fila["Longitud"] == -72.961235
    assert fila["Precision (m)"] == 6.4
    assert "Altitud (m)" not in fila
    assert "s3" not in base.orden, "un punto no tiene nada que mandar a S3"

    [proyecto] = base.de("Proyectos")
    assert proyecto["Codigo proyecto"] == "local-111"


async def test_reintentar_el_punto_no_lo_duplica(base):
    await _sync_puntos(YO, _punto())
    await _sync_puntos(YO, _punto(nombre="Alcantarilla arreglada"))

    [fila] = base.de("Waypoints")
    assert fila["Nombre"] == "Alcantarilla arreglada"


async def test_nadie_pisa_el_punto_de_otro(base):
    await _sync_puntos(YO, _punto())
    r = await _sync_puntos(OTRO, _punto(nombre="Pisado"))

    assert not r.waypoints[0].ok
    [fila] = base.de("Waypoints")
    assert fila["Nombre"] == "Alcantarilla rota"


async def test_el_punto_se_enlaza_al_recorrido_de_la_misma_tanda(base):
    r = await _sync_puntos(
        YO,
        _punto(trazado_codigo="ruta-0001"),
        trazados=[_ruta("ruta-0001", metodo="automatico")],
    )

    assert r.trazados[0].ok and r.waypoints[0].ok
    [fila] = base.de("Waypoints")
    [trazado_id] = base.tablas["Trazados"].keys()
    assert fila["Trazado"] == [trazado_id]


async def test_el_punto_no_se_cuelga_del_recorrido_de_otra_cuenta(base):
    await _sync(OTRO, _ruta("ruta-ajena-1"))
    r = await _sync_puntos(YO, _punto(trazado_codigo="ruta-ajena-1"))

    assert r.waypoints[0].ok, "el punto es valido: solo queda sin enlace"
    [fila] = base.de("Waypoints")
    assert "Trazado" not in fila


async def test_un_punto_malo_no_frena_a_los_demas(base, monkeypatch):
    guardar = base.guardar

    async def falla_en_uno(settings, tabla, campos, record_id):
        if campos.get("Codigo waypoint") == "punto-malo":
            raise RuntimeError("se cayo la red")
        return await guardar(settings, tabla, campos, record_id)

    monkeypatch.setattr(airtable, "guardar", falla_en_uno)
    r = await _sync_puntos(YO, _punto("punto-malo"), _punto("punto-bueno"))

    assert [w.ok for w in r.waypoints] == [False, True]
    assert "Se reintenta" in r.waypoints[0].error
    assert [f["Codigo waypoint"] for f in base.de("Waypoints")] == ["punto-bueno"]


def test_un_punto_imposible_no_entra():
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        _punto(latitud=120.0)
    with pytest.raises(ValidationError):
        _punto(longitud=-272.96)
    # El simbolo llega con el .name de Dart; la opcion de Airtable no vale.
    with pytest.raises(ValidationError):
        _punto(simbolo="Fuente de agua")


# --- Calificacion de la ruta -------------------------------------------------


async def test_la_calificacion_llega_a_la_fila(base):
    r = await _sync(
        YO,
        _ruta(
            metodo="automatico",
            calificacion=2,
            calificacion_motivos=["barro", "cerrada", "motivo_nuevo"],
            calificacion_comentario="  El paso del cano esta cerrado  ",
        ),
    )

    assert r.trazados[0].ok, r.trazados[0].error
    [fila] = base.de("Trazados")
    assert fila["Calificacion"] == 2
    assert fila["Motivos calificacion"] == "Barro o agua, Paso cerrado, motivo_nuevo"
    assert fila["Comentario calificacion"] == "El paso del cano esta cerrado"


async def test_sin_calificar_no_se_escribe_nada_de_eso(base):
    await _sync(YO, _ruta())
    [fila] = base.de("Trazados")
    assert "Calificacion" not in fila
    assert "Motivos calificacion" not in fila


async def test_si_la_base_no_tiene_los_campos_el_recorrido_sube_igual(base, monkeypatch):
    """Una base donde todavia no se crearon los campos de calificacion."""
    guardar = base.guardar

    async def sin_esos_campos(settings, tabla, campos, record_id):
        if "Calificacion" in campos:
            raise HTTPException(
                status_code=500,
                detail="Airtable rechazo los campos de 'Trazados': "
                '{"error":{"type":"UNKNOWN_FIELD_NAME","message":"Unknown field name: '
                '\\"Calificacion\\""}}',
            )
        return await guardar(settings, tabla, campos, record_id)

    monkeypatch.setattr(airtable, "guardar", sin_esos_campos)
    r = await _sync(YO, _ruta(calificacion=5))

    assert r.trazados[0].ok, r.trazados[0].error
    [fila] = base.de("Trazados")
    assert fila["Codigo trazado"] == "ruta-0001"
    assert "Calificacion" not in fila


async def test_otro_rechazo_de_airtable_no_se_traga(base, monkeypatch):
    async def falla(settings, tabla, campos, record_id):
        if tabla == "Trazados":
            raise HTTPException(status_code=502, detail="Airtable respondio 503")
        return await base.guardar(settings, tabla, campos, record_id)

    monkeypatch.setattr(airtable, "guardar", falla)
    r = await _sync(YO, _ruta(calificacion=4))

    assert not r.trazados[0].ok
    assert "503" in r.trazados[0].error


def test_una_calificacion_fuera_de_rango_no_entra():
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        _ruta(calificacion=0)
    with pytest.raises(ValidationError):
        _ruta(calificacion=6)


# ------------------- El recorrido de una vuelta de camiones -------------------

VIAJE = {
    "codigo": "6f1c2b9e-0000-4000-8000-0000000000aa",
    "llegada": {"en": "2026-10-14T15:20:00Z", "lat": 4.45, "lon": -72.96, "distancia_m": 30},
    "regreso": {"en": "2026-10-14T15:50:00Z", "lat": 4.40, "lon": -72.90},
    "fin": {"en": "2026-10-14T15:52:00Z", "lat": 4.40, "lon": -72.90, "distancia_m": 8},
    "recorrido_m": 11842.0,
}


async def test_el_recorrido_de_una_vuelta_la_cierra(base, monkeypatch):
    """Finalizar sin senal: la vuelta se cierra cuando sube el recorrido, y
    con eso el conductor puede tomar la siguiente."""
    from app.services import camiones

    avisos = []

    async def seguimiento(settings, identidad, codigo, req):
        avisos.append((identidad.auth_uid, codigo, req))

    monkeypatch.setattr(camiones, "seguimiento", seguimiento)
    r = await _sync(YO, _ruta("viaje-0001", metodo="automatico", viaje=VIAJE))

    assert r.trazados[0].ok
    (quien, codigo, req), = avisos
    assert (quien, codigo) == ("111", VIAJE["codigo"])
    assert req.fin is not None and req.llegada.distancia_m == 30
    # El seguimiento queda apuntando al recorrido que lo trajo.
    assert req.trazado == "viaje-0001"


async def test_la_vuelta_se_cierra_aunque_el_recorrido_no_suba(base, monkeypatch):
    from app.services import camiones

    avisos = []

    async def seguimiento(settings, identidad, codigo, req):
        avisos.append(codigo)

    def s3_caido(*_):
        raise RuntimeError("S3 no contesta")

    monkeypatch.setattr(camiones, "seguimiento", seguimiento)
    monkeypatch.setattr(almacenamiento, "subir", s3_caido)
    r = await _sync(YO, _ruta("viaje-0001", metodo="automatico", viaje=VIAJE))

    assert not r.trazados[0].ok
    assert avisos == [VIAJE["codigo"]]


async def test_un_seguimiento_que_falla_no_frena_el_recorrido(base, monkeypatch):
    from app.services import camiones

    async def falla(*_, **__):
        raise HTTPException(status_code=404, detail="Ese viaje no existe.")

    monkeypatch.setattr(camiones, "seguimiento", falla)
    r = await _sync(YO, _ruta("viaje-0001", metodo="automatico", viaje=VIAJE))

    assert r.trazados[0].ok
    assert len(base.de("Trazados")) == 1


async def test_un_recorrido_cualquiera_no_toca_el_seguimiento(base, monkeypatch):
    from app.services import camiones

    async def nunca(*_, **__):
        raise AssertionError("no es una vuelta")

    monkeypatch.setattr(camiones, "seguimiento", nunca)
    r = await _sync(YO, _ruta())
    assert r.trazados[0].ok


# --- Proyectos creados en el telefono ---------------------------------------

UUID_P = "0b8f2c1e-5a3d-4e7f-9b1a-2c3d4e5f6a7b"


def _proyecto(codigo: str = UUID_P, **cambios) -> ProyectoSync:
    datos = {
        "codigo": codigo,
        "nombre": "Finca La Esperanza",
        "cliente": "Palmas del Upia",
        "municipio": "Barranca de Upia",
    }
    datos.update(cambios)
    return ProyectoSync(**datos)


async def _sync_con(ident: Identidad, **partes):
    return await sincronizacion.sincronizar(
        get_settings(), ident, SyncRequest(**partes)
    )


async def test_sube_el_proyecto_con_su_dueno(base):
    r = await _sync_con(YO, proyectos=[_proyecto()])

    assert r.proyectos[0].ok, r.proyectos[0].error
    [fila] = base.de("Proyectos")
    assert fila["Codigo proyecto"] == UUID_P
    assert fila["Nombre"] == "Finca La Esperanza"
    assert fila["Cliente"] == "Palmas del Upia"
    assert fila["Estado"] == "Activo"
    assert fila["Dueno Auth UID"] == "111"


async def test_lo_que_se_levanta_cae_en_su_proyecto_y_no_en_el_local(base):
    # El proyecto y su primera ruta suben en la misma tanda, recien creados.
    r = await _sync_con(
        YO,
        proyectos=[_proyecto()],
        trazados=[_ruta(proyecto_codigo=UUID_P)],
    )

    assert r.trazados[0].ok, r.trazados[0].error
    assert (
        r.trazados[0].llave_geometria
        == f"proyectos/{UUID_P}/geometrias/ruta-0001.geojson"
    )
    assert [p["Codigo proyecto"] for p in base.de("Proyectos")] == [UUID_P]


async def test_nadie_se_queda_con_el_proyecto_de_otro(base):
    # El codigo lo genera el telefono: conocer el de un proyecto ajeno no
    # alcanza para quedarselo.
    await _sync_con(OTRO, proyectos=[_proyecto()])

    r = await _sync_con(YO, proyectos=[_proyecto(nombre="Ahora es mio")])

    assert not r.proyectos[0].ok
    [fila] = base.de("Proyectos")
    assert fila["Dueno Auth UID"] == "222"
    assert fila["Nombre"] == "Finca La Esperanza"


async def test_archivar_lo_cierra_sin_borrarlo_ni_duplicarlo(base):
    await _sync_con(YO, proyectos=[_proyecto()])
    await _sync_con(YO, proyectos=[_proyecto(activo=False)])

    [fila] = base.de("Proyectos")
    assert fila["Estado"] == "Cerrado"


def test_el_codigo_de_un_proyecto_tiene_que_ser_un_uuid():
    # `local-<Auth UID>` es el "sin proyecto" de cada cuenta y lo arma el
    # backend. Si el telefono pudiera mandar ese codigo, alguien crearia a su
    # nombre el de otra cuenta.
    for malo in ("local-222", "local", "../otro", "proyecto-1", ""):
        with pytest.raises(ValidationError):
            _proyecto(codigo=malo)


async def test_un_telefono_que_no_manda_proyectos_sigue_andando(base):
    r = await _sync(YO, _ruta())

    assert r.trazados[0].ok
    assert r.proyectos == []
