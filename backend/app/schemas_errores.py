"""Lo que viaja en `POST /v1/errores`: los fallos que la app anoto en el telefono.

Los topes de largo no son prolijidad. La traza de un error puede traer cientos
de renglones y el telefono manda de a veinte: sin tope, una tanda sola pesa mas
de lo que una funcion serverless acepta en el cuerpo.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

# Cuantos informes por llamada. Del otro lado son dos escrituras en Airtable,
# que acepta diez filas por vez.
MAXIMO_POR_TANDA = 20


class ErrorApp(BaseModel):
    """Un fallo, tal como lo anoto el telefono.

    Si el mismo fallo se repite mientras espera subir, no viaja varias veces:
    viaja una, con `veces`. Una pantalla que falla al dibujarse falla en cada
    cuadro, y sesenta filas iguales por segundo no le sirven a nadie.
    """

    # UUID que genero el telefono. Reintentar una subida cortada no duplica.
    codigo: str = Field(min_length=8, max_length=64)
    mensaje: str = Field(min_length=1, max_length=2000)
    traza: str | None = Field(default=None, max_length=8000)

    # En que parte de la app salto, cuando Flutter lo sabe ("widgets library",
    # "al dibujar la tarjeta de ruta").
    donde: str | None = Field(default=None, max_length=300)

    # La hora del telefono, que sin senal es la unica que hay.
    ocurrio_en: datetime
    veces: int = Field(default=1, ge=1, le=1_000_000)

    version_code: int | None = Field(default=None, ge=0)
    version_nombre: str | None = Field(default=None, max_length=40)

    # Marca, modelo y version de Android: un fallo que solo pasa en un modelo
    # no se encuentra sin esto.
    sistema: str | None = Field(default=None, max_length=200)


class ErroresRequest(BaseModel):
    errores: list[ErrorApp] = Field(min_length=1, max_length=MAXIMO_POR_TANDA)


class ErroresResponse(BaseModel):
    # Los codigos que quedaron guardados: el telefono borra esos y nada mas.
    recibidos: list[str]
