from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Todo lo que el backend necesita saber y la app nunca puede ver.

    La regla que ordena este archivo: ninguna de estas cadenas puede terminar
    dentro del APK. El telefono conoce la URL del backend y su propia
    APP_API_KEY, y nada mas.
    """

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_api_key: str = ""

    # --- Airtable --------------------------------------------------------
    airtable_token: str = ""
    airtable_base_id: str = ""
    airtable_tabla_usuarios: str = "Usuarios"
    airtable_tabla_dispositivos: str = "Dispositivos"
    airtable_tabla_proyectos: str = "Proyectos"
    airtable_tabla_mapas: str = "Mapas"
    airtable_tabla_trazados: str = "Trazados"
    airtable_tabla_waypoints: str = "Waypoints"
    airtable_tabla_archivos: str = "Archivos"
    airtable_tabla_sincronizaciones: str = "Sincronizaciones"

    # --- Identidad: Google + Airtable ------------------------------------
    # Registro abierto con cuenta de Google. No hay proveedor de identidad de
    # por medio: este backend verifica el ID token contra el JWKS de Google y
    # guarda la persona en Airtable. Ninguna contrasena existe en el sistema.

    # El client id de tipo **Web** del proyecto de Google Cloud. Es el que la
    # app manda como `serverClientId` y el que aparece en el `aud` del token.
    # El gran tropiezo de Android: sin este, `google_sign_in` entrega la sesion
    # pero NO entrega idToken, y el backend se queda sin nada que verificar.
    google_client_id_web: str = ""

    # El client id de tipo Android. No viaja en el token, pero tiene que existir
    # en Google Cloud con la huella SHA-1 de la firma del APK o el login falla
    # en el telefono con un error que no explica nada (ApiException: 10).
    google_client_id_android: str = ""

    # Secreto con el que se firman NUESTROS JWT. No tiene nada que ver con
    # Google. Rotarlo cierra todas las sesiones abiertas, que es justamente lo
    # que se quiere si alguna vez se filtra.
    # Generar con: python -c "import secrets; print(secrets.token_urlsafe(48))"
    jwt_secret: str = ""

    # Cuanto dura nuestro JWT. Largo a proposito: es lo que permite entrar con
    # senal una vez y trabajar un mes en el monte sin volver a ver un login.
    # El de Google vence en una hora y no serviria para eso.
    jwt_ttl_dias: int = 30

    # Techo de almacenamiento por cuenta. Lo mismo: con registro abierto, el
    # limite tiene que existir antes de que exista el primer abuso.
    cuota_mb_por_usuario: int = 2048

    # --- AWS S3 ----------------------------------------------------------
    aws_access_key_id: str = ""
    aws_secret_access_key: str = ""

    # Region real, no "auto": eso era de Cloudflare R2. S3 firma con la region
    # y una equivocada responde SignatureDoesNotMatch, que no dice que el
    # problema sea la region.
    aws_region: str = "us-east-1"
    s3_bucket: str = "sirius-geo-maps"

    # CloudFront, si lo hay. Vacio = todo sale por URL prefirmada, que es lo
    # correcto para un bucket privado.
    s3_cloudfront_url: str = ""

    # Lectura larga porque bajar 400 MB de MBTiles sobre red rural tarda: si la
    # URL vence a mitad, la descarga reanudable reintenta contra una URL
    # muerta y el error que ve el usuario no dice nada util.
    s3_ttl_lectura: int = 86400
    s3_ttl_escritura: int = 3600

    # --- Actualizaciones del APK -----------------------------------------
    # El manifiesto de la version vigente. Lo escribe tools/publicar_apk.py y
    # lo lee services/version_app.py. Los dias de gracia viajan adentro del
    # manifiesto, asi que cambiarlos no pide redeploy.
    s3_llave_manifiesto_app: str = "app/version.json"


@lru_cache
def get_settings() -> Settings:
    return Settings()
