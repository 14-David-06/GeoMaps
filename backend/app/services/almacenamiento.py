"""AWS S3: donde vive todo lo que puede crecer.

La linea divisoria con Airtable no es binario vs. texto, es **si el dato tiene
techo**. Un GeoJSON es texto plano y aun asi vive aca, porque una jornada
grabada cada 5 segundos son decenas de miles de vertices y el `Long text` de
Airtable topa en 100.000 caracteres.

Airtable guarda la `Llave S3`, no la URL. La llave es estable; la URL es
prefirmada y vence. Guardar una URL vencida en la base produce filas que
apuntan a un 403 y nadie sabe por que.

## Estructura

Todo cuelga del proyecto, para que borrarlo sea un solo delete por prefijo y no
una caceria de archivos sueltos:

    proyectos/<codigo proyecto>/
      mapas/<codigo mapa>.mbtiles
      mapas/originales/<codigo mapa>.pdf
      geometrias/<codigo trazado>.geojson
      kml/<nombre>.kml
      gpx/<nombre>.gpx
      pdf/<nombre>.pdf
      fotos/<codigo waypoint>/<uuid>.jpg

La unica excepcion es el APK de la app, que no es de ningun proyecto:

    app/
      version.json                  el manifiesto de la version vigente
      geomaps-<nombre>+<code>.apk   uno por version publicada

## El bucket es privado

Nada se sirve publico. El telefono nunca tiene credenciales de AWS adentro del
APK: pide una URL prefirmada al backend y sube o baja contra ella.

- **Escritura**: prefirmada de PUT, TTL corto.
- **Lectura**: prefirmada de GET, TTL largo (una descarga de 400 MB sobre red
  rural tarda; si vence a mitad, la reanudacion reintenta contra una URL
  muerta).
- **Airtable**: recibe una prefirmada de lectura solo para los `Attachment`.
  Airtable **copia** el archivo a su propio almacenamiento al escribir, asi que
  el adjunto sobrevive a la expiracion de la URL.

## Configuracion del bucket que no es opcional

1. **Versionado activo.** Editar un trazado reescribe su `.geojson`. Sin
   versiones, un lindero borrado por error no se recupera sin volver a
   caminarlo.
2. **Block Public Access activo.** Si algo tiene que salir a internet, sale
   prefirmado o por CloudFront, nunca por un ACL publico.
3. **Cifrado en reposo (SSE-S3).** Un plano de predio con linderos es dato de
   un cliente.
4. **Regla de ciclo de vida sobre `mapas/originales/`**: a Glacier a los 90
   dias. El GeoPDF original se guarda para poder reconvertir, no para
   consultarlo, y es lo mas pesado que hay en el bucket.
"""

from __future__ import annotations

from functools import lru_cache

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError

from ..config import Settings


@lru_cache
def _cliente(access_key: str, secret_key: str, region: str):
    """Un cliente por proceso. Los timeouts son cortos porque esto corre dentro
    de un request: un S3 lento no puede colgar la respuesta al telefono."""
    return boto3.client(
        "s3",
        aws_access_key_id=access_key or None,
        aws_secret_access_key=secret_key or None,
        region_name=region,
        config=BotoConfig(
            connect_timeout=3,
            read_timeout=5,
            retries={"max_attempts": 2},
            signature_version="s3v4",
        ),
    )


def cliente(settings: Settings):
    return _cliente(
        settings.aws_access_key_id,
        settings.aws_secret_access_key,
        settings.aws_region,
    )


def leer(settings: Settings, llave: str) -> bytes | None:
    """El contenido de un objeto, o None si no existe. Cualquier otro error
    (credenciales, red) se propaga: no es lo mismo que "no hay nada"."""
    try:
        r = cliente(settings).get_object(Bucket=settings.s3_bucket, Key=llave)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            return None
        raise
    return r["Body"].read()


def url_lectura(settings: Settings, llave: str, ttl: int | None = None) -> str:
    """URL prefirmada de GET. Se arma localmente, sin llamar a AWS."""
    return cliente(settings).generate_presigned_url(
        "get_object",
        Params={"Bucket": settings.s3_bucket, "Key": llave},
        ExpiresIn=ttl or settings.s3_ttl_lectura,
    )


def subir(settings: Settings, llave: str, contenido: bytes, content_type: str) -> str:
    """Escribe un objeto y devuelve su llave.

    Es para lo que llega por el backend y pesa poco, como el GeoJSON de una
    ruta. Lo pesado -MBTiles, fotos- va directo del telefono con prefirmada.
    Que `put_object` vuelva sin excepcion es la confirmacion que pide la regla
    de "primero S3, despues Airtable": no hace falta un `existe` aparte.
    """
    cliente(settings).put_object(
        Bucket=settings.s3_bucket,
        Key=llave,
        Body=contenido,
        ContentType=content_type,
    )
    return llave


def borrar_prefijo(settings: Settings, prefijo: str) -> int:
    """Borra todo lo que cuelga de `prefijo`, con sus versiones anteriores.

    El bucket tiene versionado: un `delete_objects` comun solo pone una marca
    de borrado y el dato sigue ahi, recuperable. Para una baja de cuenta eso no
    es borrar, asi que se recorren las versiones y se borra cada una.

    Si la llave de AWS no tiene permiso sobre las versiones, se borra la
    version vigente y las anteriores quedan para la regla de ciclo de vida que
    expira versiones no vigentes a los 30 dias (ver docs/despliegue.md). Fallar
    aca dejaria la cuenta sin poder borrarse nunca, que es peor.

    Devuelve cuantos objetos (o versiones) borro.
    """
    if not prefijo.endswith("/") or prefijo.count("/") < 2:
        # Un prefijo vacio o de un solo nivel ("proyectos/") borraria el bucket
        # entero. No hay ningun caso legitimo para eso.
        raise ValueError(f"Prefijo demasiado amplio para borrar: {prefijo!r}")

    s3 = cliente(settings)
    borrados = 0
    try:
        paginas = s3.get_paginator("list_object_versions").paginate(
            Bucket=settings.s3_bucket, Prefix=prefijo
        )
        for pagina in paginas:
            objetos = [
                {"Key": v["Key"], "VersionId": v["VersionId"]}
                for v in pagina.get("Versions", []) + pagina.get("DeleteMarkers", [])
            ]
            borrados += _borrar_lote(s3, settings.s3_bucket, objetos)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "AccessDenied":
            raise
        for pagina in s3.get_paginator("list_objects_v2").paginate(
            Bucket=settings.s3_bucket, Prefix=prefijo
        ):
            objetos = [{"Key": o["Key"]} for o in pagina.get("Contents", [])]
            borrados += _borrar_lote(s3, settings.s3_bucket, objetos)
    return borrados


def _borrar_lote(s3, bucket: str, objetos: list[dict]) -> int:
    # delete_objects acepta hasta 1000, que es justo lo que trae cada pagina.
    if not objetos:
        return 0
    r = s3.delete_objects(Bucket=bucket, Delete={"Objects": objetos, "Quiet": True})
    if r.get("Errors"):
        primero = r["Errors"][0]
        raise RuntimeError(
            f"S3 no borro {len(r['Errors'])} objeto(s); el primero: "
            f"{primero.get('Key')} ({primero.get('Code')})."
        )
    return len(objetos)


def url_escritura(
    settings: Settings, llave: str, content_type: str, ttl: int | None = None
) -> str:
    """URL prefirmada de PUT. Se arma localmente, sin llamar a AWS.

    Es por donde sube lo pesado directo desde el telefono. El tipo de
    contenido va firmado: quien la use tiene que mandar ese mismo
    `Content-Type`, o S3 la rechaza. El tamano no se puede firmar en un PUT,
    asi que quien la pide lo revisa despues con `tamano`.
    """
    return cliente(settings).generate_presigned_url(
        "put_object",
        Params={
            "Bucket": settings.s3_bucket,
            "Key": llave,
            "ContentType": content_type,
        },
        ExpiresIn=ttl or settings.s3_ttl_escritura,
    )


def tamano(settings: Settings, llave: str) -> int | None:
    """Cuantos bytes pesa un objeto, o None si no existe. Es tambien la forma
    de saber si lo que el telefono dijo que subio de verdad llego."""
    try:
        r = cliente(settings).head_object(Bucket=settings.s3_bucket, Key=llave)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
            return None
        raise
    return int(r["ContentLength"])


def borrar(settings: Settings, llave: str) -> None:
    """Borra un objeto. Con el bucket versionado deja una marca de borrado;
    las versiones viejas las expira la regla de ciclo de vida."""
    cliente(settings).delete_object(Bucket=settings.s3_bucket, Key=llave)


def llave_foto(codigo_proyecto: str, codigo_waypoint: str, codigo_foto: str) -> str:
    """Donde vive la foto de un punto marcado.

    Cuelga del proyecto, como todo, para que borrar el proyecto -o la cuenta-
    se la lleve; y del punto, para encontrar las de un punto sin consultar
    Airtable.
    """
    return f"proyectos/{codigo_proyecto}/fotos/{codigo_waypoint}/{codigo_foto}.jpg"


def llave_geometria(codigo_proyecto: str, codigo_trazado: str) -> str:
    """Donde vive el GeoJSON de un trazado.

    Un solo lugar arma esta cadena porque la usan tres partes: el que sube, el
    campo `Llave geometria` de Airtable y el que consulta. Si se arman por
    separado, el dia que cambie el prefijo quedan filas apuntando al vacio.
    """
    return f"proyectos/{codigo_proyecto}/geometrias/{codigo_trazado}.geojson"


def llave_mapa(codigo_proyecto: str, codigo_mapa: str) -> str:
    """El MBTiles que descarga el telefono."""
    return f"proyectos/{codigo_proyecto}/mapas/{codigo_mapa}.mbtiles"


def llave_mapa_original(
    codigo_proyecto: str, codigo_mapa: str, extension: str
) -> str:
    """El archivo tal como lo mando topografia.

    Se conserva para poder reconvertir con otros parametros -mas DPI, otro
    remuestreo- sin volver a pedirselo a nadie. La extension viaja como
    parametro porque el original puede ser PDF, TIFF o KMZ y perderla obliga a
    adivinar el formato al releerlo.
    """
    ext = extension.lower().lstrip(".")
    return f"proyectos/{codigo_proyecto}/mapas/originales/{codigo_mapa}.{ext}"


def llave_miniatura_mapa(codigo_proyecto: str, codigo_mapa: str) -> str:
    """La imagen chica que Airtable copia al campo `Miniatura`.

    Vive en S3 y no solo en Airtable porque Airtable guarda una copia, no el
    original: si alguien borra el adjunto, sin esto habria que reconvertir el
    mapa entero para recuperar una imagen de 40 KB.
    """
    return f"proyectos/{codigo_proyecto}/mapas/miniaturas/{codigo_mapa}.png"
