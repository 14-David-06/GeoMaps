"""Puntos de entrada HTTP.

Todos piden `X-API-Key` salvo `/health`.

Lo que este backend hace y lo que no:

- **Hace**: guardar las llaves, verificar la identidad, convertir mapas a
  MBTiles, firmar URLs de S3 y escribir en Airtable con upsert por UUID.
- **No hace**: ser necesario para trabajar. La app funciona completa con este
  servicio caido; lo unico que no puede es sincronizar, bajar mapas nuevos ni
  renovar la sesion — y la sesion dura 30 dias justamente por eso.

## Las tres puertas de entrada

    POST /v1/sesion        Google: ID token -> sesion. Registra si no existia.
    POST /v1/registro      Correo + clave: crea la cuenta y la deja adentro.
    POST /v1/sesion/clave  Correo + clave: entra a una cuenta que ya existe.

Las tres devuelven exactamente el mismo `EntrarResponse`. La app tiene dos
formularios antes del login y un solo camino despues.

## Versiones de la app

Toda llamada de la app trae `X-App-Version` (el versionCode del APK). Si esa
version ya esta bloqueada, el middleware responde 426 antes de llegar al
endpoint. `GET /v1/version` dice cual es la vigente y de donde bajarla; ver
`services/version_app.py`.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .config import Settings, get_settings
from .services import airtable, almacenamiento, auth, version_app

app = FastAPI(title="GeoMaps API", version="0.1.0")

# Lo que responde aunque la version del telefono este bloqueada: el ping, y la
# consulta de version, que es justo lo que una app bloqueada necesita para
# salir del bloqueo.
_RUTAS_SIN_CHEQUEO_DE_VERSION = {"/health", "/v1/version", "/docs", "/openapi.json"}


@app.middleware("http")
async def rechazar_versiones_bloqueadas(request: Request, call_next):
    """426 a una version del APK que ya paso su plazo.

    La app se bloquea sola con la misma regla, pero no se le cree: una version
    vieja que no se entero (o a la que le atrasaron el reloj) no puede subir
    datos con un formato que el backend ya no espera. Sin cabecera se deja
    pasar: son curl, pruebas y herramientas, no telefonos.
    """
    version = version_app.version_de_header(request.headers.get("x-app-version"))
    if version is not None and request.url.path not in _RUTAS_SIN_CHEQUEO_DE_VERSION:
        manifiesto = await version_app.manifiesto_vigente(get_settings())
        if manifiesto and (
            version_app.evaluar(version, manifiesto, datetime.now(timezone.utc))
            == "bloqueada"
        ):
            return JSONResponse(
                status_code=426,
                content={
                    "detail": "Esta version de GeoMaps ya no se puede usar. "
                    f"Actualiza a la {manifiesto.version_nombre} desde la app; "
                    "lo que tenes guardado en el telefono no se pierde."
                },
            )
    return await call_next(request)


@app.get("/health")
async def health() -> dict[str, str]:
    """Ping. Es el unico endpoint sin llave: sirve para saber si el servicio
    esta vivo desde cualquier lado, incluido el telefono antes de tener sesion.
    """
    return {"estado": "ok"}


class EntrarRequest(BaseModel):
    """Login con Google: lo unico que viaja es el ID token."""

    id_token: str


class EntrarClaveRequest(BaseModel):
    """Login con correo y clave."""

    correo: str
    clave: str


class RegistroRequest(BaseModel):
    """Alta de cuenta con clave. El unico endpoint donde viaja un nombre."""

    nombre: str
    correo: str
    clave: str


class EntrarResponse(BaseModel):
    """La misma respuesta para las tres puertas.

    Que Google y la clave devuelvan esto mismo es lo que deja a la app con una
    sola nocion de sesion: dos formularios antes del login, un solo camino
    despues. `proveedor` esta para poder mostrar "entraste con Google" en el
    perfil, no para que la app decida nada distinto segun el valor.
    """

    token: str
    vence_en: datetime
    auth_uid: str
    codigo_usuario: str
    nombre: str
    correo: str
    foto: str | None
    rol: str
    proveedor: str


def _armar_sesion(
    identidad: auth.Identidad, proveedor: str, settings: Settings
) -> EntrarResponse:
    """Firma el JWT y arma la respuesta. No consulta ni escribe nada.

    Existe para que las tres puertas no tengan tres versiones distintas de como
    se ve una sesion: el dia que se agregue un campo, se agrega una sola vez.
    """
    token, vence = auth.emitir_jwt(identidad, settings)
    return EntrarResponse(
        token=token,
        vence_en=vence,
        auth_uid=identidad.auth_uid,
        codigo_usuario=identidad.codigo_usuario or "",
        nombre=identidad.nombre,
        correo=identidad.correo,
        foto=identidad.foto,
        rol=identidad.rol,
        proveedor=proveedor,
    )


@app.post("/v1/sesion", response_model=EntrarResponse)
async def entrar(
    req: EntrarRequest, _: None = Depends(auth.verificar_api_key)
) -> EntrarResponse:
    """Login y registro con Google. Son el mismo evento.

    La primera vez que llega un `Auth UID` que no existe en `Usuarios`, se crea
    la fila. No hay endpoint de registro con Google porque no hay nada que
    pedirle a la persona que Google no haya dado ya — a diferencia de la puerta
    de clave, donde el nombre hay que preguntarlo.
    """
    settings = get_settings()
    identidad = auth.verificar_id_token_google(req.id_token, settings)

    # Upsert por Auth UID. El codigo de usuario se genera solo la primera vez:
    # si se regenerara en cada login, los enlaces de sus proyectos apuntarian a
    # un usuario que ya no existe.
    existente = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        f"{{Auth UID}}='{identidad.auth_uid.replace(chr(39), '')}'",
    )

    # Si el correo ya lo tiene una cuenta con clave, Google no puede quedarselo:
    # serian dos filas con el mismo correo y la de clave quedaria inalcanzable.
    if not existente:
        choque = await airtable.buscar_uno(
            settings,
            settings.airtable_tabla_usuarios,
            auth.formula_por_correo(identidad.correo),
        )
        if choque:
            raise HTTPException(
                status_code=409,
                detail="Ese correo ya tiene una cuenta con clave. Entra con tu "
                "correo y clave en vez de con Google.",
            )

    campos_existentes = (existente or {}).get("fields", {})
    codigo_usuario = campos_existentes.get("Codigo usuario") or str(uuid.uuid4())
    rol = campos_existentes.get("Rol") or "Usuario"
    ahora = datetime.now(timezone.utc).isoformat()

    campos = {
        "Codigo usuario": codigo_usuario,
        "Nombre": identidad.nombre,
        "Correo": auth.normalizar_correo(identidad.correo),
        "Rol": rol,
        "Estado": campos_existentes.get("Estado") or "Activa",
        "Ultimo acceso": ahora,
        "Proveedor": "Google",
        # Google ya lo verifico. Es la ventaja concreta de esta puerta sobre la
        # de clave, donde el campo nace en falso y por ahora se queda asi.
        "Correo verificado": True,
    }
    if identidad.foto:
        campos["Foto"] = identidad.foto
    if not existente:
        campos["Registrado en"] = ahora

    await airtable.upsert(
        settings,
        settings.airtable_tabla_usuarios,
        "Auth UID",
        identidad.auth_uid,
        campos,
    )

    completa = auth.Identidad(
        auth_uid=identidad.auth_uid,
        correo=identidad.correo,
        nombre=identidad.nombre,
        foto=identidad.foto,
        codigo_usuario=codigo_usuario,
        rol=rol,
    )
    return _armar_sesion(completa, "Google", settings)


@app.post("/v1/registro", response_model=EntrarResponse, status_code=201)
async def registrar(
    req: RegistroRequest, _: None = Depends(auth.verificar_api_key)
) -> EntrarResponse:
    """Crea una cuenta con correo y clave, y la deja adentro.

    Devuelve sesion en vez de mandar a la persona a escribir lo mismo otra vez
    en el formulario de al lado. Registrarse con red disponible y quedar afuera
    es la forma exacta de desperdiciar el unico rato con senal que alguien va a
    tener ese dia.

    Lo que **no** hace: mandar correo de verificacion. `Correo verificado` nace
    en falso y nada depende de el todavia. Ver el encabezado de `auth.py`.
    """
    settings = get_settings()
    correo = auth.validar_correo(req.correo)
    auth.validar_clave(req.clave)
    nombre = req.nombre.strip() or correo.split("@")[0]

    existente = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        auth.formula_por_correo(correo),
    )
    if existente:
        # Decir cual es la puerta correcta, no "correo en uso" a secas. Quien se
        # registro con Google hace seis meses no se acuerda, y sin este mensaje
        # se queda probando claves que nunca existieron.
        if existente.get("fields", {}).get("Proveedor") == "Google":
            raise HTTPException(
                status_code=409,
                detail="Ese correo ya entra con Google. Usa el boton "
                "'Continuar con Google'.",
            )
        raise HTTPException(
            status_code=409,
            detail="Ese correo ya tiene cuenta. Entra con tu clave.",
        )

    auth_uid = auth.nuevo_auth_uid_correo()
    codigo_usuario = str(uuid.uuid4())
    ahora = datetime.now(timezone.utc).isoformat()

    await airtable.upsert(
        settings,
        settings.airtable_tabla_usuarios,
        "Auth UID",
        auth_uid,
        {
            "Codigo usuario": codigo_usuario,
            "Nombre": nombre,
            "Correo": correo,
            "Rol": "Usuario",
            "Estado": "Activa",
            "Proveedor": "Correo",
            "Correo verificado": False,
            # Lo unico que se guarda de la clave. El texto en claro no llega a
            # Airtable, ni a un log, ni vuelve en la respuesta.
            "Hash clave": auth.hash_clave(req.clave),
            "Intentos fallidos": 0,
            "Registrado en": ahora,
            "Ultimo acceso": ahora,
        },
    )

    identidad = auth.Identidad(
        auth_uid=auth_uid,
        correo=correo,
        nombre=nombre,
        foto=None,
        codigo_usuario=codigo_usuario,
        rol="Usuario",
    )
    return _armar_sesion(identidad, "Correo", settings)


@app.post("/v1/sesion/clave", response_model=EntrarResponse)
async def entrar_con_clave(
    req: EntrarClaveRequest, _: None = Depends(auth.verificar_api_key)
) -> EntrarResponse:
    """Login con correo y clave.

    Un correo que no existe y una clave equivocada dan **el mismo** 401. La
    diferencia solo le sirve a quien esta probando correos para averiguar quien
    tiene cuenta; a quien de verdad se equivoco no le cambia nada.

    La excepcion es la cuenta de Google: ahi si se dice cual es la puerta, y a
    proposito. Esa fila no tiene clave ni la va a tener, asi que el mensaje no
    revela nada que el boton de Google no revele igual, y sin el la persona se
    queda probando claves inexistentes hasta bloquearse sola.
    """
    settings = get_settings()
    correo = auth.normalizar_correo(req.correo)

    fila = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        auth.formula_por_correo(correo),
    )
    campos = (fila or {}).get("fields", {})

    if fila:
        auth.revisar_bloqueo(campos)
        if campos.get("Proveedor") == "Google":
            raise HTTPException(
                status_code=409,
                detail="Esa cuenta entra con Google. Usa el boton 'Continuar "
                "con Google'.",
            )

    # Se corre siempre, exista o no la fila: `verificar_clave` compara contra un
    # senuelo cuando no hay hash, para que el tiempo de respuesta no delate
    # cuales correos estan registrados.
    if not auth.verificar_clave(req.clave, campos.get("Hash clave")):
        if fila:
            await _anotar_intento_fallido(settings, campos)
        raise HTTPException(status_code=401, detail="Correo o clave incorrectos.")

    if campos.get("Estado") == "Suspendida":
        raise HTTPException(
            status_code=403,
            detail="Esta cuenta esta suspendida. Escribinos para reactivarla.",
        )

    auth_uid = campos["Auth UID"]
    codigo_usuario = campos.get("Codigo usuario") or str(uuid.uuid4())

    await airtable.upsert(
        settings,
        settings.airtable_tabla_usuarios,
        "Auth UID",
        auth_uid,
        {
            "Codigo usuario": codigo_usuario,
            "Ultimo acceso": datetime.now(timezone.utc).isoformat(),
            # Entrar bien limpia el contador: ocho errores de tipeo repartidos a
            # lo largo de un mes no tienen por que dejar a nadie afuera.
            "Intentos fallidos": 0,
        },
    )

    identidad = auth.Identidad(
        auth_uid=auth_uid,
        correo=campos.get("Correo") or correo,
        nombre=campos.get("Nombre") or correo.split("@")[0],
        foto=campos.get("Foto"),
        codigo_usuario=codigo_usuario,
        rol=campos.get("Rol") or "Usuario",
    )
    return _armar_sesion(identidad, "Correo", settings)


async def _anotar_intento_fallido(settings: Settings, campos: dict) -> None:
    """Suma uno al contador de fallos. Nunca hace fallar el login.

    Si Airtable no responde, el 401 que sigue tiene que salir igual: un contador
    caido no puede convertirse en un 500 que deje a todo el mundo sin entrar.
    """
    try:
        await airtable.upsert(
            settings,
            settings.airtable_tabla_usuarios,
            "Auth UID",
            campos["Auth UID"],
            {
                "Intentos fallidos": (campos.get("Intentos fallidos") or 0) + 1,
                "Ultimo intento fallido": datetime.now(timezone.utc).isoformat(),
            },
        )
    except Exception:  # noqa: BLE001
        pass


class VersionResponse(BaseModel):
    """Lo que la app necesita para decidir si se bloquea, y para bajar el APK.

    `estado` es la regla aplicada a la version que mando el telefono; la app
    la vuelve a aplicar por su cuenta con `minima` y `bloquea_en` cuando no
    tiene red. `ahora` es la hora del servidor: con ella la app se protege de
    un reloj atrasado a mano para esquivar el bloqueo.
    """

    publicada: bool
    estado: version_app.Estado | None = None
    version_code: int | None = None
    version_nombre: str | None = None
    minima: int | None = None
    bloquea_en: datetime | None = None
    notas: str | None = None
    tamano_bytes: int | None = None
    # Con `publicada` en falso: por que no se pudo leer el manifiesto (un codigo
    # de AWS como NoSuchBucket), o nulo si de verdad no hay nada publicado.
    falla: str | None = None
    sha256: str | None = None
    apk_url: str | None = None
    ahora: datetime


@app.get("/v1/version", response_model=VersionResponse)
async def version(
    x_app_version: str | None = Header(default=None),
    _: None = Depends(auth.verificar_api_key),
) -> VersionResponse:
    """La version vigente del APK. No pide sesion: una app bloqueada o con la
    sesion vencida igual tiene que poder actualizarse."""
    settings = get_settings()
    ahora = datetime.now(timezone.utc)
    manifiesto = await version_app.manifiesto_vigente(settings)
    if manifiesto is None:
        return VersionResponse(
            publicada=False, ahora=ahora, falla=version_app.ultima_falla
        )

    local = version_app.version_de_header(x_app_version)
    try:
        # Prefirmada y no publica: el bucket es privado. Firmarla es local, no
        # cuesta una llamada a AWS.
        apk_url = almacenamiento.url_lectura(settings, manifiesto.llave_apk)
    except Exception:  # noqa: BLE001
        apk_url = None

    return VersionResponse(
        publicada=True,
        estado=(
            version_app.evaluar(local, manifiesto, ahora) if local is not None else None
        ),
        version_code=manifiesto.version_code,
        version_nombre=manifiesto.version_nombre,
        minima=manifiesto.minima,
        bloquea_en=manifiesto.bloquea_en,
        notas=manifiesto.notas,
        tamano_bytes=manifiesto.tamano_bytes,
        sha256=manifiesto.sha256,
        apk_url=apk_url,
        ahora=ahora,
    )


@app.get("/v1/yo")
async def yo(
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
) -> dict[str, str | None]:
    """Quien soy, segun mi token. No consulta Airtable.

    Sirve para que la app compruebe en un solo request si su sesion sigue
    valiendo, sin gastar cupo de la API de Airtable.
    """
    return {
        "auth_uid": identidad.auth_uid,
        "codigo_usuario": identidad.codigo_usuario,
        "correo": identidad.correo,
        "rol": identidad.rol,
    }


# TODO: GET  /v1/proyectos         espejo del directorio, filtrado por dueno
# TODO: GET  /v1/mapas             fichas de mapas en estado Listo
# TODO: GET  /v1/mapas/{id}/descarga   URL prefirmada del MBTiles
# TODO: POST /v1/mapas             sube el original y encola la conversion
# TODO: POST /v1/archivos          sube KML/GPX/PDF/foto a S3
# TODO: POST /v1/sync              upsert por UUID de todo lo pendiente
