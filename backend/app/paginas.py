"""Las dos paginas publicas que pide Play: privacidad y baja de cuenta.

Viven en el backend y no en un sitio aparte porque es la unica URL de GeoMaps
que ya existe y no depende de nadie mas. Son HTML fijo, sin plantillas ni
JavaScript: se leen desde el navegador de cualquier telefono y desde el
revisor de Google.

Lo que dicen tiene que ser cierto respecto del codigo. Si la app empieza a
juntar algo nuevo (fotos de waypoints, por ejemplo), se agrega aca y en el
formulario de seguridad de datos de Play Console el mismo dia.
"""

from __future__ import annotations

from html import escape

from .config import Settings

ACTUALIZADA = "17 de noviembre de 2026"

_ESTILO = """
:root { color-scheme: light dark; --fondo: #fff; --texto: #1d1d1f;
  --suave: #5f6368; --acento: #0057ad; --borde: #e3e3e3; }
@media (prefers-color-scheme: dark) { :root { --fondo: #121212;
  --texto: #ececec; --suave: #a8a8a8; --acento: #6fb1ff; --borde: #2c2c2c; } }
body { margin: 0; background: var(--fondo); color: var(--texto);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 32px 16px 64px; }
h1 { font-size: 1.7rem; line-height: 1.25; margin: 0 0 4px; }
h2 { font-size: 1.15rem; margin: 32px 0 8px; }
p, li { margin: 0 0 10px; }
ul, ol { padding-left: 22px; }
a { color: var(--acento); }
.fecha { color: var(--suave); margin-bottom: 24px; }
table { border-collapse: collapse; width: 100%; margin: 8px 0 16px; }
th, td { text-align: left; vertical-align: top; padding: 8px;
  border-bottom: 1px solid var(--borde); }
th { font-weight: 600; }
"""


def _pagina(titulo: str, cuerpo: str) -> str:
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{titulo}</title>
<style>{_ESTILO}</style>
</head>
<body><main>
{cuerpo}
</main></body>
</html>"""


def _correo(settings: Settings) -> str:
    c = escape(settings.contacto_privacidad)
    return f'<a href="mailto:{c}">{c}</a>'


def privacidad(settings: Settings) -> str:
    correo = _correo(settings)
    return _pagina(
        "Privacidad - Sirius GeoMaps",
        f"""
<h1>Política de privacidad de Sirius GeoMaps</h1>
<p class="fecha">Última actualización: {ACTUALIZADA}</p>

<p>Sirius GeoMaps es la aplicación de campo de <strong>Sirius Regenerative
Solutions</strong> (en adelante, “Sirius”) para trabajar con mapas, recorridos
GPS y viajes de camiones en predios agrícolas. Sirius es el responsable del
tratamiento de los datos que se describen aquí, conforme a la Ley 1581 de 2012
de Colombia y sus decretos reglamentarios.</p>

<h2>Qué datos recogemos</h2>
<table>
<tr><th>Dato</th><th>Para qué</th></tr>
<tr><td>Nombre, correo y foto de perfil (si entras con Google), o nombre,
correo y contraseña (si creas la cuenta con correo)</td>
<td>Crear y administrar tu cuenta. La contraseña se guarda cifrada con bcrypt;
nunca la vemos ni la guardamos en texto.</td></tr>
<tr><td>Ubicación precisa (GPS)</td>
<td>Mostrar dónde estás en el mapa, grabar recorridos y polígonos, y calcular
rutas. Solo se usa mientras la app está abierta o mientras grabas un viaje de
camión que tú iniciaste; en ese caso Android muestra una notificación fija
todo el tiempo que dura la grabación. La app no pide ubicación en segundo
plano.</td></tr>
<tr><td>Recorridos y polígonos que guardas</td>
<td>Sincronizarlos con tu cuenta para que no se pierdan si el teléfono se
daña.</td></tr>
<tr><td>Número de cédula (solo módulo de camiones)</td>
<td>Identificarte como conductor en la planilla de viajes de Sirius
(SiriusFleet) cuando confirmas una vuelta.</td></tr>
<tr><td>Versión de la app</td>
<td>Avisar cuando hay que actualizar.</td></tr>
<tr><td>Informes de error de la app: el mensaje técnico del fallo, la versión
de la app, y la marca, el modelo y la versión de Android del teléfono</td>
<td>Encontrar y corregir fallos. Se guardan con tu cuenta en nuestra base de
datos; no pasan por servicios de terceros.</td></tr>
</table>

<p>La app <strong>no</strong> recoge contactos, fotos, archivos, mensajes,
audio, datos de salud o financieros, ni identificadores de publicidad. No
muestra anuncios ni usa servicios de analítica o de reporte de fallos de
terceros.</p>

<p>La cámara se usa únicamente para leer el código QR de las vueltas
pendientes; la imagen no se guarda ni se envía.</p>

<h2>Dónde se guardan</h2>
<p>Lo que haces sin señal se guarda primero en tu teléfono y se sube cuando
hay conexión. En nuestros servidores, los datos se almacenan con proveedores
que los procesan por cuenta de Sirius:</p>
<ul>
<li><strong>Vercel</strong>: el servidor de la app.</li>
<li><strong>Airtable</strong>: la base de datos de cuentas y recorridos.</li>
<li><strong>Amazon Web Services (S3)</strong>, en Estados Unidos: la geometría
completa de los recorridos, en un almacenamiento privado y cifrado.</li>
<li><strong>Supabase</strong>: la planilla de viajes de SiriusFleet (solo
módulo de camiones).</li>
</ul>
<p>Google interviene cuando inicias sesión con tu cuenta de Google. Para
dibujar el mapa, la app pide imágenes a <strong>Esri</strong> y a
<strong>OpenStreetMap</strong>; esos servicios reciben la zona del mapa que
estás viendo y la dirección IP de tu conexión, pero no tu ubicación GPS ni tu
cuenta.</p>

<h2>Con quién se comparten</h2>
<p>No vendemos tus datos ni los compartimos con terceros para publicidad ni
para ningún otro fin. Solo los ven los proveedores de arriba, para prestar el
servicio, y el personal de Sirius que lo necesita para operar.</p>

<h2>Seguridad</h2>
<p>Toda la comunicación entre la app y nuestros servidores va cifrada (HTTPS).
El almacenamiento de archivos es privado y cifrado, y cada cuenta solo puede
ver lo suyo.</p>

<h2>Cuánto tiempo se guardan</h2>
<p>Mientras tu cuenta exista. Si la eliminas, borramos tu cuenta, tus
recorridos, tus proyectos y tus informes de error de inmediato; las copias de
respaldo del
almacenamiento se purgan en un máximo de 30 días. Los viajes de camión que
confirmaste quedan en la planilla operativa de SiriusFleet, porque son
registros de la operación de la empresa, pero ya no quedan ligados a tu
cuenta. Ver <a href="/eliminar-cuenta">cómo eliminar tu cuenta</a>.</p>

<h2>Tus derechos</h2>
<p>Puedes conocer, actualizar, rectificar y suprimir tus datos, y revocar la
autorización para tratarlos, escribiendo a {correo}. Respondemos en los
plazos de la Ley 1581 de 2012: hasta 10 días hábiles para consultas y 15 para
reclamos.</p>

<h2>Menores de edad</h2>
<p>Sirius GeoMaps es una herramienta de trabajo para mayores de 18 años. No
está dirigida a menores ni recogemos a sabiendas datos de menores.</p>

<h2>Cambios</h2>
<p>Si esta política cambia, publicaremos la nueva versión en esta misma
dirección con su fecha de actualización.</p>

<h2>Contacto</h2>
<p>Sirius Regenerative Solutions · {correo}</p>
""",
    )


def eliminar_cuenta(settings: Settings) -> str:
    correo = _correo(settings)
    return _pagina(
        "Eliminar tu cuenta - Sirius GeoMaps",
        f"""
<h1>Eliminar tu cuenta de Sirius GeoMaps</h1>
<p class="fecha">Sirius Regenerative Solutions</p>

<h2>Desde la app</h2>
<ol>
<li>Abre Sirius GeoMaps con conexión a internet.</li>
<li>En la pantalla de inicio, toca tu foto o tus iniciales, arriba a la
derecha.</li>
<li>Toca <strong>Eliminar mi cuenta</strong> y confirma.</li>
</ol>
<p>La cuenta se borra en el momento y la app cierra la sesión.</p>

<h2>Sin la app</h2>
<p>Escribe a {correo} desde el correo de tu cuenta, con el asunto
<strong>“Eliminar mi cuenta de GeoMaps”</strong>. La eliminamos en un máximo
de 10 días hábiles y te confirmamos por correo.</p>

<h2>Qué se borra</h2>
<ul>
<li>Tu cuenta: nombre, correo, foto, contraseña y número de cédula.</li>
<li>Tus recorridos, polígonos y proyectos, en la base de datos y en el
almacenamiento de archivos.</li>
<li>El historial de sincronizaciones y los informes de error de tu
cuenta.</li>
<li>Lo guardado en el teléfono, si la eliminas desde la app.</li>
</ul>
<p>Las copias de respaldo del almacenamiento se purgan en un máximo de 30
días.</p>

<h2>Qué se conserva</h2>
<p>Los viajes de camión que confirmaste quedan en la planilla operativa de
SiriusFleet, porque son registros de la operación de la empresa. Ya no quedan
ligados a tu cuenta de GeoMaps.</p>

<p>Más detalles en la <a href="/privacidad">política de privacidad</a>.</p>
""",
    )
