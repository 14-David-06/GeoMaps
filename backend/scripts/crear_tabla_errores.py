"""Crea en Airtable la tabla `Errores`: los fallos que la app anota en el telefono.

Sin esta tabla la app guarda sus informes de error en el telefono y los
reintenta cada vez que engancha senal, sin perder ninguno (hasta cuarenta por
telefono). Ver `app/services/errores_app.py`.

    python scripts/crear_tabla_errores.py            # solo dice que haria
    python scripts/crear_tabla_errores.py --aplicar  # la crea

Se puede correr las veces que haga falta: si la tabla ya existe, agrega solo
los campos que le falten y no toca nada de lo que hay. Nunca borra ni renombra.

Necesita un token de Airtable con el permiso `schema.bases:write` sobre la
base. Si el del `.env` no lo tiene, Airtable responde 403 y el script lo dice:
se crea a mano con los campos de `docs/airtable-schema.md`, o con otro token.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import get_settings  # noqa: E402

API = "https://api.airtable.com/v0/meta/bases"

_FECHA_HORA = {
    "type": "dateTime",
    "options": {
        "dateFormat": {"name": "iso"},
        "timeFormat": {"name": "24hour"},
        "timeZone": "America/Bogota",
    },
}

_ENTERO = {"type": "number", "options": {"precision": 0}}


def campos() -> list[dict[str, Any]]:
    """Los campos, en el orden en que se leen. El primero es el primario."""
    texto = {"type": "singleLineText"}
    largo = {"type": "multilineText"}
    return [
        {"name": "Codigo error", **texto},
        {"name": "Mensaje", **largo},
        {"name": "Veces", **_ENTERO},
        {"name": "Ocurrio en", **_FECHA_HORA},
        {"name": "Version", **texto},
        {"name": "Sistema", **texto},
        {"name": "Persona", **texto},
        {"name": "Donde", **texto},
        {"name": "Traza", **largo},
        {"name": "Recibido en", **_FECHA_HORA},
        {"name": "Version code", **_ENTERO},
        {"name": "Auth UID", **texto},
        {
            "name": "Estado",
            "type": "singleSelect",
            "options": {
                "choices": [
                    {"name": "Nuevo", "color": "redBright"},
                    {"name": "Visto", "color": "yellowBright"},
                    {"name": "Arreglado", "color": "greenBright"},
                ]
            },
        },
    ]


DESCRIPCION = (
    "Fallos de la app GeoMaps: una fila por error que un telefono anoto, con "
    "la version del APK, el modelo del telefono y la traza. 'Veces' dice "
    "cuantas veces se repitio antes de subir. 'Estado' es para quien lo "
    "revisa: el backend no lo escribe."
)


def main() -> int:
    aplicar = "--aplicar" in sys.argv
    s = get_settings()
    if not s.airtable_token or not s.airtable_base_id:
        print("Falta AIRTABLE_TOKEN o AIRTABLE_BASE_ID en el .env.")
        return 1
    nombre = s.airtable_tabla_errores
    base = f"{API}/{s.airtable_base_id}/tables"
    quiero = campos()

    with httpx.Client(
        timeout=30, headers={"Authorization": f"Bearer {s.airtable_token}"}
    ) as c:
        r = c.get(base)
        if r.status_code != 200:
            print(f"No se pudo leer el esquema ({r.status_code}): {r.text[:300]}")
            return 1
        tablas = {t["name"]: t for t in r.json()["tables"]}

        existente = tablas.get(nombre)
        if existente is None:
            print(f"La tabla '{nombre}' no existe. Se crea con {len(quiero)} campos:")
            for f in quiero:
                print(f"  + {f['name']}  ({f['type']})")
            if not aplicar:
                print("\nNo se toco nada. Con --aplicar se crea.")
                return 0
            r = c.post(
                base,
                json={"name": nombre, "description": DESCRIPCION, "fields": quiero},
            )
            return _resultado(r, f"Tabla '{nombre}' creada.")

        hay = {f["name"] for f in existente["fields"]}
        faltan = [f for f in quiero if f["name"] not in hay]
        if not faltan:
            print(f"La tabla '{nombre}' ya existe y tiene todos los campos.")
            return 0
        print(f"La tabla '{nombre}' existe. Le faltan {len(faltan)} campos:")
        for f in faltan:
            print(f"  + {f['name']}  ({f['type']})")
        if not aplicar:
            print("\nNo se toco nada. Con --aplicar se agregan.")
            return 0
        for f in faltan:
            r = c.post(f"{base}/{existente['id']}/fields", json=f)
            if _resultado(r, f"  campo '{f['name']}' agregado."):
                return 1
        return 0


def _resultado(r: httpx.Response, bien: str) -> int:
    if r.status_code in (200, 201):
        print(bien)
        return 0
    print(f"Airtable respondio {r.status_code}: {r.text[:400]}")
    if r.status_code in (401, 403):
        print(
            "El token no tiene permiso para cambiar el esquema "
            "(schema.bases:write). Crea la tabla a mano con los campos de "
            "docs/airtable-schema.md, o corre esto con un token que lo tenga."
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
