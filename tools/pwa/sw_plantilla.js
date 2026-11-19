// Service worker de GeoMaps web (la app del iPhone).
//
// Lo escribe tools/compilar_pwa.py a partir de tools/pwa/sw_plantilla.js, con
// la lista real de archivos del build. No se edita el sw.js publicado.
//
// Que hace:
// - Al instalarse guarda la app ENTERA en el telefono. Si un solo archivo
//   falla, la instalacion falla completa y se reintenta la proxima vez: una
//   app guardada a medias abre en el lote y se cae en la primera pantalla.
// - Sirve la app desde lo guardado, con o sin senal. Toda pagina de la app es
//   index.html (las pantallas van despues del #), salvo instalar.html.
// - No toca el API (/v1/...) ni las imagenes del mapa de otros dominios: de
//   eso se encarga la app.
// - Cada version guarda en su propia cache y, al activarse, borra las de
//   versiones anteriores. Nunca borra `geomaps-teselas`, donde la app guarda
//   las imagenes del mapa, ni el almacen de la base local.
// - Una version nueva espera a que la persona toque "Actualizar".
'use strict';

const VERSION = '__VERSION__';

// [ruta relativa al alcance, bytes, sha256 del contenido]
const ARCHIVOS = __ARCHIVOS__;

const PREFIJO = 'geomaps-app-';
const CACHE = PREFIJO + VERSION;
const EN_PARALELO = 4;

const ALCANCE = self.registration.scope;
const direccion = (ruta) => new URL(ruta, ALCANCE).href;

async function avisar(mensaje) {
  const ventanas = await self.clients.matchAll({
    includeUncontrolled: true,
    type: 'window',
  });
  for (const v of ventanas) v.postMessage(mensaje);
}

// La copia de [ruta] que ya guardo una version anterior, si tiene el mismo
// contenido. Asi una actualizacion baja solo lo que cambio (main.dart.js) y
// no otra vez los 7 MB de CanvasKit por senal rural.
async function copiaVieja(url, hash) {
  for (const nombre of await caches.keys()) {
    if (!nombre.startsWith(PREFIJO) || nombre === CACHE) continue;
    const vieja = await (await caches.open(nombre)).match(url);
    if (vieja && vieja.headers.get('x-geomaps-sha256') === hash) return vieja;
  }
  return null;
}

// Una respuesta lista para guardar: completa, sin redireccion (Safari no
// acepta servir una respuesta "redirected" a una navegacion) y marcada con su
// hash para la proxima actualizacion.
async function limpia(r, hash) {
  const cabeceras = new Headers(r.headers);
  cabeceras.set('x-geomaps-sha256', hash);
  return new Response(await r.blob(), {
    status: 200,
    statusText: 'OK',
    headers: cabeceras,
  });
}

async function guardarTodo() {
  const cache = await caches.open(CACHE);
  const total = ARCHIVOS.reduce((s, a) => s + a[1], 0);
  let hechos = 0;
  let siguiente = 0;
  let ultimoAviso = 0;

  async function trabajador() {
    while (siguiente < ARCHIVOS.length) {
      const [ruta, bytes, hash] = ARCHIVOS[siguiente++];
      const url = direccion(ruta);
      let r = await copiaVieja(url, hash);
      if (!r) {
        // no-cache: pregunta al servidor si cambio. Si es lo mismo que la app
        // acaba de bajar, contesta 304 y no se vuelve a bajar.
        const red = await fetch(new Request(url, { cache: 'no-cache' }));
        if (!red.ok) throw new Error(`${ruta}: el servidor respondio ${red.status}`);
        r = await limpia(red, hash);
      }
      await cache.put(url, r);
      hechos += bytes;
      const ahora = Date.now();
      if (ahora - ultimoAviso > 250 || hechos === total) {
        ultimoAviso = ahora;
        await avisar({ tipo: 'progreso', version: VERSION, hechos, total });
      }
    }
  }

  await Promise.all(Array.from({ length: EN_PARALELO }, trabajador));
}

self.addEventListener('install', (e) => {
  e.waitUntil(
    guardarTodo().catch(async (error) => {
      // Nada a medias: se borra lo que alcanzo a guardar y la instalacion
      // falla. El navegador la reintenta en la proxima visita con senal.
      await caches.delete(CACHE);
      await avisar({ tipo: 'fallo', version: VERSION, mensaje: String(error) });
      throw error;
    })
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    (async () => {
      for (const nombre of await caches.keys()) {
        if (nombre.startsWith(PREFIJO) && nombre !== CACHE) {
          await caches.delete(nombre);
        }
      }
      // La primera vez toma la pagina abierta: queda lista para usar sin
      // senal sin tener que recargar.
      await self.clients.claim();
    })()
  );
});

self.addEventListener('message', (e) => {
  const m = e.data || {};
  if (m.tipo === 'activar') {
    // La persona toco "Actualizar".
    self.skipWaiting();
  } else if (m.tipo === 'version' && e.ports[0]) {
    e.ports[0].postMessage(VERSION);
  }
});

async function responder(req, url) {
  const cache = await caches.open(CACHE);
  if (req.mode === 'navigate') {
    const propia = await cache.match(url.origin + url.pathname);
    if (propia && !url.pathname.endsWith('/')) return propia;
    const indice = await cache.match(direccion('index.html'));
    if (indice) return indice;
    return fetch(req);
  }
  // ignoreSearch: Flutter pide version.json?cachebuster=... y CanvasKit con
  // su hash en la consulta.
  const guardada = await cache.match(req, { ignoreSearch: true });
  return guardada || fetch(req);
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (!url.pathname.startsWith(new URL(ALCANCE).pathname)) return;
  e.respondWith(responder(req, url));
});
