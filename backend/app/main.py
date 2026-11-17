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

    POST /v1/sesion/renovar  Cambia un JWT vigente por uno nuevo, con lo que
                             la cuenta tenga hoy en Airtable (perfiles, rol).

## Versiones de la app

Toda llamada de la app trae `X-App-Version` (el versionCode del APK). Si esa
version ya esta bloqueada, el middleware responde 426 antes de llegar al
endpoint. `GET /v1/version` dice cual es la vigente y de donde bajarla; ver
`services/version_app.py`. `GET /descargar` es el enlace fijo del codigo QR:
siempre lleva al APK vigente.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import (
    HTMLResponse,
    JSONResponse,
    PlainTextResponse,
    RedirectResponse,
    Response,
)
from pydantic import BaseModel

from . import paginas
from .config import Settings, get_settings
from .schemas_camiones import (
    ConfirmarRequest,
    ConfirmarResponse,
    MiViajeResponse,
    SeguimientoRequest,
    SeguimientoResponse,
    SoltarResponse,
    VueltasResponse,
)
from .schemas_errores import ErroresRequest, ErroresResponse
from .schemas_sync import SyncRequest, SyncResponse
from .services import (
    airtable,
    almacenamiento,
    auth,
    camiones,
    cuenta,
    errores_app,
    sincronizacion,
    version_app,
)

app = FastAPI(title="GeoMaps API", version="0.1.0")

# Lo que responde aunque la version del telefono este bloqueada: el ping, y la
# consulta de version, que es justo lo que una app bloqueada necesita para
# salir del bloqueo.
_RUTAS_SIN_CHEQUEO_DE_VERSION = {
    "/health",
    "/v1/version",
    "/descargar",
    "/privacidad",
    "/eliminar-cuenta",
    "/docs",
    "/openapi.json",
}


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
    # Que herramientas ve en la app: `plantacion`, `camiones`. Ver auth.PERFILES.
    perfiles: list[str]


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
        perfiles=list(identidad.perfiles),
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
    # La misma regla que en la puerta de clave: suspender una cuenta no sirve
    # de nada si por Google se sigue entrando.
    if campos_existentes.get("Estado") == "Suspendida":
        raise HTTPException(
            status_code=403,
            detail="Esta cuenta esta suspendida. Escribinos para reactivarla.",
        )
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
        perfiles=auth.perfiles_de_campos(campos_existentes),
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
            await auth.anotar_intento_fallido(settings, campos)
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
        perfiles=auth.perfiles_de_campos(campos),
    )
    return _armar_sesion(identidad, "Correo", settings)


@app.post("/v1/sesion/renovar", response_model=EntrarResponse)
async def renovar_sesion(
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> EntrarResponse:
    """Cambia un JWT vigente por uno nuevo, leyendo la cuenta de Airtable.

    Existe por dos cosas que el JWT de 30 dias no resuelve solo:

    - **Los perfiles viajan adentro del token.** Darle a alguien el perfil de
      camiones en Airtable no le llegaba hasta que cerrara sesion y volviera a
      entrar, y a un conductor no se le puede pedir eso por telefono. Con esto
      le llega la proxima vez que abre la app con senal.
    - **El plazo se corre.** Quien abre la app con senal cada tanto no vuelve a
      ver el login nunca: los 30 dias cuentan desde la ultima renovacion.

    Es la unica llamada de sesion que si consulta Airtable; la app la hace a lo
    sumo una vez cada tantas horas. Una cuenta suspendida o borrada no renueva.
    """
    settings = get_settings()
    fila = await airtable.buscar_uno(
        settings,
        settings.airtable_tabla_usuarios,
        airtable.formula_codigo("Auth UID", identidad.auth_uid),
    )
    if not fila:
        raise HTTPException(
            status_code=403,
            detail="Tu cuenta ya no esta en la base. Escribinos para revisarla.",
        )
    campos = fila.get("fields", {})
    if campos.get("Estado") == "Suspendida":
        raise HTTPException(
            status_code=403,
            detail="Esta cuenta esta suspendida. Escribinos para reactivarla.",
        )

    correo = campos.get("Correo") or identidad.correo
    completa = auth.Identidad(
        auth_uid=identidad.auth_uid,
        correo=correo,
        nombre=campos.get("Nombre") or correo.split("@")[0],
        foto=campos.get("Foto"),
        codigo_usuario=campos.get("Codigo usuario") or identidad.codigo_usuario,
        rol=campos.get("Rol") or "Usuario",
        perfiles=auth.perfiles_de_campos(campos),
    )
    proveedor = campos.get("Proveedor") or (
        "Correo" if campos.get("Hash clave") else "Google"
    )
    return _armar_sesion(completa, proveedor, settings)


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


@app.get("/descargar", include_in_schema=False)
async def descargar():
    """El enlace del codigo QR: redirige al APK vigente.

    El QR se imprime una vez y no cambia; lo que cambia es el manifiesto que
    escribe `tools/publicar_apk.py`, asi que escanearlo siempre baja la ultima
    version. No pide `X-API-Key` porque lo abre el navegador del telefono, que
    no la tiene: es el mismo APK que ya se reparte a mano.
    """
    settings = get_settings()
    manifiesto = await version_app.manifiesto_vigente(settings)
    if manifiesto is None:
        return PlainTextResponse(
            "Todavia no hay una version de GeoMaps publicada.", status_code=503
        )
    try:
        apk_url = almacenamiento.url_lectura(settings, manifiesto.llave_apk)
    except Exception:  # noqa: BLE001
        return PlainTextResponse(
            "No se pudo preparar la descarga. Intenta de nuevo en un rato.",
            status_code=503,
        )
    # 302 y no 301: un 301 lo cachea el navegador y se quedaria con el APK
    # (y la firma vencida) de la primera vez.
    return RedirectResponse(
        apk_url, status_code=302, headers={"Cache-Control": "no-store"}
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


@app.delete("/v1/cuenta", status_code=204)
async def eliminar_cuenta(
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> Response:
    """Borra la cuenta y todo lo que subio. Ver `services/cuenta.py`.

    El JWT sigue siendo valido hasta que vence, pero ya no hay fila a la que
    colgarle nada: la sincronizacion responde 403. La app borra su copia local
    y cierra la sesion apenas recibe el 204.
    """
    await cuenta.eliminar(get_settings(), identidad)
    return Response(status_code=204)


@app.get("/privacidad", include_in_schema=False)
async def privacidad() -> HTMLResponse:
    """La politica de privacidad. Publica: la enlaza la ficha de Play."""
    return HTMLResponse(paginas.privacidad(get_settings()))


@app.get("/eliminar-cuenta", include_in_schema=False)
async def pagina_eliminar_cuenta() -> HTMLResponse:
    """Como borrar la cuenta. Play pide una URL para quien ya no tiene la app."""
    return HTMLResponse(paginas.eliminar_cuenta(get_settings()))


@app.post("/v1/sync", response_model=SyncResponse)
async def sync(
    req: SyncRequest,
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> SyncResponse:
    """Sube lo que el telefono guardo sin senal: trazados y puntos marcados.

    Responde 200 aunque algun trazado no haya quedado: el detalle va por item,
    y el telefono reintenta solo esos. Un error de la tanda entera seria pedirle
    que vuelva a mandar tambien lo que ya subio.
    """
    return await sincronizacion.sincronizar(get_settings(), identidad, req)


@app.post("/v1/errores", response_model=ErroresResponse)
async def errores(
    req: ErroresRequest,
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> ErroresResponse:
    """Recibe los fallos que la app anoto en el telefono. Ver
    `services/errores_app.py`.

    Pide sesion: sin ella cualquiera con la llave del APK podria llenar la
    tabla. Un fallo de antes de entrar espera en el telefono y sube despues.
    """
    return await errores_app.registrar(get_settings(), identidad, req)


@app.get("/v1/camiones/vueltas", response_model=VueltasResponse)
async def vueltas_pendientes(
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> VueltasResponse:
    """Las vueltas por recoger de la planilla de SiriusFleet. Lo que abre el QR.

    Trae tambien `conductor` -a nombre de quien quedan y si hay que pedirle
    clave- y `viaje_abierto`: la vuelta que esta cuenta tomo y no finalizo.
    Mientras tenga una no puede tomar otra.
    """
    auth.exigir_perfil(identidad, "camiones")
    return await camiones.pendientes(get_settings(), identidad)


@app.post("/v1/camiones/vueltas/{vuelta_id}/confirmar", response_model=ConfirmarResponse)
async def confirmar_vuelta(
    vuelta_id: uuid.UUID,
    req: ConfirmarRequest,
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> ConfirmarResponse:
    """El conductor toma una vuelta: queda anotado como salido en la planilla.

    `vuelta_id` se tipa como UUID para que FastAPI lo valide: va a parar a un
    filtro de PostgREST, y una cadena libre ahi es un filtro inyectado.
    """
    auth.exigir_perfil(identidad, "camiones")
    return await camiones.confirmar(get_settings(), identidad, str(vuelta_id), req)


@app.post("/v1/camiones/vueltas/{vuelta_id}/soltar", response_model=SoltarResponse)
async def soltar_vuelta(
    vuelta_id: uuid.UUID,
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> SoltarResponse:
    """El conductor devuelve a la lista una vuelta que tomo y no va a hacer."""
    auth.exigir_perfil(identidad, "camiones")
    return SoltarResponse(
        vuelta=await camiones.soltar(get_settings(), identidad, str(vuelta_id))
    )


@app.get("/v1/camiones/viaje", response_model=MiViajeResponse)
async def mi_viaje(
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> MiViajeResponse:
    """La vuelta sin finalizar de esta cuenta, segun el servidor."""
    auth.exigir_perfil(identidad, "camiones")
    return await camiones.mi_viaje(get_settings(), identidad)


@app.post(
    "/v1/camiones/viajes/{codigo}/seguimiento", response_model=SeguimientoResponse
)
async def seguimiento_viaje(
    codigo: uuid.UUID,
    req: SeguimientoRequest,
    identidad: auth.Identidad = Depends(auth.identidad_de_request),
    _: None = Depends(auth.verificar_api_key),
) -> SeguimientoResponse:
    """El telefono avisa por donde va la vuelta: llego, volvio, la finalizo.

    Es el aviso en vivo, para cuando hay senal. El que no se pierde es el que
    viaja con el recorrido grabado en `/v1/sync`: trae lo mismo y sube solo.
    """
    auth.exigir_perfil(identidad, "camiones")
    return await camiones.seguimiento(get_settings(), identidad, str(codigo), req)


# TODO: GET  /v1/proyectos         espejo del directorio, filtrado por dueno
# TODO: GET  /v1/mapas             fichas de mapas en estado Listo
# TODO: GET  /v1/mapas/{id}/descarga   URL prefirmada del MBTiles
# TODO: POST /v1/mapas             sube el original y encola la conversion
# TODO: POST /v1/archivos          sube KML/GPX/PDF/foto a S3
