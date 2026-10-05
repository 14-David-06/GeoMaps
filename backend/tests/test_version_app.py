"""La regla de versiones y el 426.

El manifiesto de S3 se reemplaza por uno en memoria: lo que se prueba es la
regla y quien la aplica, no boto3.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import get_settings
from app.services import version_app
from app.services.version_app import Manifiesto, evaluar

PUBLICADA = datetime(2026, 9, 1, 12, 0, tzinfo=timezone.utc)


def _manifiesto(**cambios) -> Manifiesto:
    datos = {
        "version_code": 3,
        "version_nombre": "0.3.0",
        "publicada_en": PUBLICADA,
        "dias_gracia": 10,
        "minima": 1,
        "llave_apk": "app/geomaps-0.3.0+3.apk",
        "sha256": "abc",
    }
    datos.update(cambios)
    return Manifiesto(**datos)


# --- La regla -------------------------------------------------------------


def test_la_version_vigente_esta_al_dia():
    assert evaluar(3, _manifiesto(), PUBLICADA + timedelta(days=30)) == "al_dia"


def test_una_version_mas_nueva_que_la_publicada_esta_al_dia():
    # Un build de desarrollo, o uno que se probo antes de publicar.
    assert evaluar(4, _manifiesto(), PUBLICADA) == "al_dia"


def test_dentro_de_la_gracia_solo_avisa():
    ahora = PUBLICADA + timedelta(days=9, hours=23)
    assert evaluar(2, _manifiesto(), ahora) == "desactualizada"


def test_a_los_diez_dias_bloquea():
    assert evaluar(2, _manifiesto(), PUBLICADA + timedelta(days=10)) == "bloqueada"


def test_por_debajo_de_la_minima_bloquea_sin_esperar():
    assert evaluar(1, _manifiesto(minima=2), PUBLICADA) == "bloqueada"


def test_la_gracia_sale_del_manifiesto():
    m = _manifiesto(dias_gracia=3)
    assert evaluar(2, m, PUBLICADA + timedelta(days=2)) == "desactualizada"
    assert evaluar(2, m, PUBLICADA + timedelta(days=3)) == "bloqueada"


def test_fecha_sin_zona_se_toma_como_utc():
    m = _manifiesto(publicada_en=datetime(2026, 9, 1, 12, 0))
    assert m.bloquea_en == PUBLICADA + timedelta(days=10)


@pytest.mark.parametrize("valor", [None, "", "abc", "1.2"])
def test_cabecera_invalida_se_ignora(valor):
    assert version_app.version_de_header(valor) is None


# --- El endpoint y el middleware -----------------------------------------


@pytest.fixture
def cliente(monkeypatch):
    manifiesto = {"valor": _manifiesto(publicada_en=datetime.now(timezone.utc))}

    async def falso(_settings):
        return manifiesto["valor"]

    monkeypatch.setattr(version_app, "manifiesto_vigente", falso)
    monkeypatch.setattr(
        main.almacenamiento, "url_lectura", lambda _s, llave: f"https://s3/{llave}"
    )
    c = TestClient(main.app)
    c.manifiesto = manifiesto
    llave = get_settings().app_api_key
    c.cabeceras = {"X-API-Key": llave} if llave else {}
    return c


def test_version_devuelve_estado_y_url(cliente):
    r = cliente.get("/v1/version", headers={**cliente.cabeceras, "X-App-Version": "2"})
    assert r.status_code == 200
    cuerpo = r.json()
    assert cuerpo["estado"] == "desactualizada"
    assert cuerpo["version_code"] == 3
    assert cuerpo["apk_url"] == "https://s3/app/geomaps-0.3.0+3.apk"


def test_version_responde_aunque_la_app_este_bloqueada(cliente):
    r = cliente.get("/v1/version", headers={**cliente.cabeceras, "X-App-Version": "0"})
    assert r.status_code == 200
    assert r.json()["estado"] == "bloqueada"


def test_sin_manifiesto_no_hay_nada_publicado(cliente):
    cliente.manifiesto["valor"] = None
    r = cliente.get("/v1/version", headers={**cliente.cabeceras, "X-App-Version": "1"})
    assert r.json()["publicada"] is False
    assert r.json()["estado"] is None


def test_version_bloqueada_recibe_426_en_el_resto(cliente):
    r = cliente.get("/v1/yo", headers={**cliente.cabeceras, "X-App-Version": "0"})
    assert r.status_code == 426
    assert "0.3.0" in r.json()["detail"]


def test_version_en_gracia_pasa(cliente):
    # Llega al endpoint: el 401 es por no traer token, no por la version.
    r = cliente.get("/v1/yo", headers={**cliente.cabeceras, "X-App-Version": "2"})
    assert r.status_code == 401


def test_sin_cabecera_no_se_bloquea(cliente):
    r = cliente.get("/v1/yo", headers=cliente.cabeceras)
    assert r.status_code == 401


def test_health_nunca_se_bloquea(cliente):
    assert cliente.get("/health", headers={"X-App-Version": "0"}).status_code == 200


def test_sin_manifiesto_por_falla_dice_el_codigo(monkeypatch):
    """Un bucket mal configurado no puede verse igual que "no hay version"."""
    from botocore.exceptions import ClientError

    def explota(_settings, _llave):
        raise ClientError({"Error": {"Code": "NoSuchBucket"}}, "GetObject")

    monkeypatch.setattr(version_app.almacenamiento, "leer", explota)
    version_app.olvidar_cache()
    try:
        c = TestClient(main.app)
        llave = get_settings().app_api_key
        r = c.get("/v1/version", headers={"X-API-Key": llave} if llave else {})
        assert r.status_code == 200
        assert r.json()["publicada"] is False
        assert r.json()["falla"] == "NoSuchBucket"
    finally:
        version_app.olvidar_cache()
