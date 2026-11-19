"""Lo que viaja para subir la foto de un punto marcado.

La foto no pasa por el backend: el telefono pide aca **a donde** subirla, la
sube directo al bucket con una URL prefirmada, y despues avisa que ya esta.
Son tres pasos y no uno porque una funcion serverless no es lugar para hacer
pasar megas: tiene limite de cuerpo y de tiempo, y la red rural tarda.

Los codigos van con patron estricto porque terminan adentro de una llave de
S3: una barra o un `..` en un codigo seria escribir en la carpeta de otro.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

# El telefono las achica antes de guardarlas (1600 px, calidad 80): salen de
# 300 a 600 KB. Cuatro megas es margen de sobra y es el techo de lo que se
# acepta: una foto de 12 MB por datos moviles en un lote no sube nunca.
MAX_BYTES_FOTO = 4 * 1024 * 1024

_CODIGO = r"^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$"


class FotoPedido(BaseModel):
    """El telefono quiere subir una foto: pide a donde."""

    # UUID que genero el telefono para la foto. Reintentar no duplica.
    codigo: str = Field(pattern=_CODIGO)
    # El punto al que pertenece. Tiene que haber subido antes.
    waypoint_codigo: str = Field(pattern=_CODIGO)
    proyecto_codigo: str = Field(min_length=1, max_length=64)
    tamano_bytes: int = Field(gt=0, le=MAX_BYTES_FOTO)


class FotoSubida(BaseModel):
    """A donde subirla: un PUT a `url`, con ese `content_type`, antes de que
    venza."""

    url: str
    llave: str
    content_type: str = "image/jpeg"
    vence_en_s: int


class FotoConfirmacion(BaseModel):
    """El telefono avisa que la foto ya esta en el bucket."""

    waypoint_codigo: str = Field(pattern=_CODIGO)
    proyecto_codigo: str = Field(min_length=1, max_length=64)
    # Cuando se tomo, con la hora del telefono.
    tomada_en: datetime | None = None


class FotoConfirmada(BaseModel):
    codigo: str
    # La llave en el bucket. El telefono la guarda: es la que identifica la
    # foto del lado del servidor.
    llave: str
