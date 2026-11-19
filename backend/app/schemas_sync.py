"""Lo que viaja en `POST /v1/sync`.

Los enumerados llegan con el `.name` de Dart (`ruta`, `calculada`) y se
traducen aca a la opcion del Single select de Airtable (`Ruta`, `Calculada`).
La traduccion vive en un solo diccionario por campo porque el upsert usa
`typecast: true`: un valor sin traducir no falla, crea en silencio una opcion
nueva al lado de la buena (`ruta` junto a `Ruta`) y parte los filtros en dos.
Por eso aca solo entra lo que esta en el diccionario; lo demas es un 422.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

from .schemas_camiones import ViajeSync

TIPOS_TRAZADO: dict[str, str] = {"ruta": "Ruta", "poligono": "Poligono"}

METODOS_CAPTURA: dict[str, str] = {
    "automatico": "Automatico",
    "manual": "Manual",
    "mixto": "Mixto",
    # Una ruta que calculo el ruteo por las vias del predio, no que alguien
    # camino. Tiene que distinguirse: no lleva precision de GPS y no sirve
    # como lindero.
    "calculada": "Calculada",
}


# Por que una ruta salio mal: el id que manda la app -> como se lee en la
# fila. Un id que este backend no conoce -un motivo que estreno un APK mas
# nuevo- se escribe tal cual en vez de perderse.
MOTIVOS_RUTA: dict[str, str] = {
    "via_mala": "Via en mal estado",
    "barro": "Barro o agua",
    "cerrada": "Paso cerrado",
    "mas_larga": "Dio mucha vuelta",
    "equivocada": "Mando por donde no era",
}


class TrazadoSync(BaseModel):
    """Un trazado tal como lo tiene el telefono.

    `puntos` no viaja: lo cuenta el backend sobre la geometria que recibe, que
    es la que queda en S3. Un conteo que dijera otra cosa que el archivo seria
    un dato mas en que no confiar.
    """

    codigo: str = Field(min_length=8, max_length=64)
    proyecto_codigo: str = Field(min_length=1, max_length=64)
    nombre: str = Field(min_length=1, max_length=200)
    tipo: Literal["ruta", "poligono"]
    metodo: Literal["automatico", "manual", "mixto", "calculada"]

    # El GeoJSON completo: Feature o geometria LineString, en [lon, lat].
    geometria: dict[str, Any]

    distancia_m: float | None = None
    area_ha: float | None = None
    precision_media_m: float | None = None
    bbox: str | None = Field(default=None, max_length=200)
    centro_lat: float | None = None
    centro_lon: float | None = None
    iniciado_en: datetime | None = None
    terminado_en: datetime | None = None

    # Como califico la ruta quien la recorrio, de 1 a 5, al terminarla. Va
    # tambien adentro del GeoJSON; aca viaja aparte para ponerla en la fila.
    calificacion: int | None = Field(default=None, ge=1, le=5)
    calificacion_motivos: list[str] | None = Field(default=None, max_length=10)
    calificacion_comentario: str | None = Field(default=None, max_length=2000)

    # Si el recorrido es el de una vuelta de camiones: su seguimiento -cuando
    # llego, cuando volvio, cuando finalizo-. Es por donde se cierra la vuelta
    # cuando el telefono la finalizo sin senal.
    viaje: ViajeSync | None = None


# El `.name` del enum de Dart -> la opcion del Single select `Simbolo`.
SIMBOLOS_WAYPOINT: dict[str, str] = {
    "generico": "Generico",
    "muestra": "Muestra",
    "arbol": "Arbol",
    "fuenteDeAgua": "Fuente de agua",
    "infraestructura": "Infraestructura",
    "riesgo": "Riesgo",
}


class WaypointSync(BaseModel):
    """Un punto marcado tal como lo tiene el telefono."""

    codigo: str = Field(min_length=8, max_length=64)
    proyecto_codigo: str = Field(min_length=1, max_length=64)
    # El recorrido durante el que se marco, si fue durante uno.
    trazado_codigo: str | None = Field(default=None, max_length=64)
    nombre: str = Field(min_length=1, max_length=200)

    # Con rango: descarta lo imposible, una latitud de 200. No alcanza para
    # cazar los ejes invertidos -en Colombia darian latitud -72, que existe,
    # en el mar del sur-: eso lo cuida el telefono, que arma el punto.
    latitud: float = Field(ge=-90, le=90)
    longitud: float = Field(ge=-180, le=180)
    altitud_m: float | None = None
    # Nulo si el punto se puso a mano sobre el mapa: no hay GPS que responda.
    precision_m: float | None = None
    simbolo: Literal[
        "generico", "muestra", "arbol", "fuenteDeAgua", "infraestructura", "riesgo"
    ]
    nota: str | None = Field(default=None, max_length=2000)
    marcado_en: datetime


class ProyectoSync(BaseModel):
    """Un proyecto creado en el telefono: el agrupador bajo el que se guarda
    lo que se levanta (un predio, un contrato, una visita).

    El codigo tiene que ser un UUID, no cualquier texto. Los proyectos
    "sin proyecto" de cada cuenta se llaman `local-<Auth UID>` y los arma el
    backend: si el telefono pudiera mandar un codigo libre, alguien podria
    crear a su nombre el `local-...` de otra cuenta, y de ahi en mas las rutas
    de esa otra cuenta caerian en un prefijo de S3 compartido.
    """

    codigo: str = Field(
        pattern=r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )
    nombre: str = Field(min_length=1, max_length=120)
    cliente: str | None = Field(default=None, max_length=120)
    municipio: str | None = Field(default=None, max_length=120)
    # Falso es archivado: en la base queda `Cerrado`, no se borra.
    activo: bool = True


class SyncRequest(BaseModel):
    """Lo pendiente del telefono, en tandas.

    El tope es por el tiempo de la funcion serverless y por el limite de 5
    requests por segundo de Airtable: cada trazado son tres llamadas, y una
    tanda grande que se corta a la mitad por timeout es peor que tres chicas.
    Un punto son dos llamadas y ninguna a S3: entran mas por tanda.
    """

    # Los proyectos van primero: un trazado se cuelga del suyo, y para eso
    # el proyecto tiene que existir. Son una busqueda y una escritura cada uno.
    proyectos: list[ProyectoSync] = Field(default_factory=list, max_length=20)
    trazados: list[TrazadoSync] = Field(default_factory=list, max_length=10)
    waypoints: list[WaypointSync] = Field(default_factory=list, max_length=20)


class ResultadoItem(BaseModel):
    """Que paso con cada UUID. El telefono marca como subido solo los `ok`."""

    codigo: str
    ok: bool
    llave_geometria: str | None = None
    error: str | None = None


class SyncResponse(BaseModel):
    trazados: list[ResultadoItem]
    # Con default: un telefono viejo, que no manda puntos, no espera la llave.
    waypoints: list[ResultadoItem] = Field(default_factory=list)
    proyectos: list[ResultadoItem] = Field(default_factory=list)
