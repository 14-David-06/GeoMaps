// GeoMaps como app web instalada en el iPhone (PWA).
//
// Lo que solo se puede hacer en JavaScript y la app de Flutter usa a traves de
// `window.geomapsPwa` (ver lib/platform/pwa_web.dart):
//
// - Registrar el service worker (`sw.js`, lo escribe tools/compilar_pwa.py),
//   que guarda la app entera en el telefono para que abra sin senal.
// - Avisar cuando hay una version nueva. Nunca recarga sola: se aplica cuando
//   la persona toca "Actualizar", no en mitad de un recorrido.
// - Guardar las imagenes del mapa base en la Cache API (`geomaps-teselas`),
//   que el service worker no borra al actualizar.
// - Pedir que el navegador no borre lo guardado y mantener la pantalla
//   encendida mientras se mira el mapa.
//
// Nada de esto pide a otro dominio: la app tiene que arrancar en modo avion.
(function () {
  'use strict';

  var CACHE_TESELAS = 'geomaps-teselas';
  var LLAVE_GUARDADA = 'geomaps.guardadaEl';
  var LLAVE_VERSION = 'geomaps.version';

  var oyentes = [];
  var registro = null;
  var pidioActualizar = false;
  var bloqueo = null;
  var quiereEncendida = false;

  var estado = {
    listaSinSenal: false,
    guardando: false,
    hechos: 0,
    total: 0,
    actualizacion: false,
    error: null,
    guardadaEl: leerFecha(),
  };

  function leerFecha() {
    try {
      var v = localStorage.getItem(LLAVE_GUARDADA);
      return v ? Number(v) : null;
    } catch (_) {
      return null;
    }
  }

  function avisar() {
    for (var i = 0; i < oyentes.length; i++) {
      try {
        oyentes[i]();
      } catch (_) {}
    }
  }

  function base() {
    return document.baseURI;
  }

  function instalada() {
    return (
      navigator.standalone === true ||
      (!!window.matchMedia &&
        window.matchMedia('(display-mode: standalone)').matches)
    );
  }

  function esIphone() {
    return (
      /iPhone|iPad|iPod/.test(navigator.userAgent) ||
      // iPadOS se presenta como un Mac de escritorio.
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
    );
  }

  // ---- Service worker -------------------------------------------------------

  // La app quedo guardada. La fecha es la de la primera vez que esta pagina
  // ve correr cada version: es lo que dice el aviso de "sin senal".
  function listo() {
    estado.listaSinSenal = true;
    estado.guardando = false;
    estado.error = null;
    avisar();
    versionSw().then(function (v) {
      try {
        if (v && localStorage.getItem(LLAVE_VERSION) !== v) {
          localStorage.setItem(LLAVE_VERSION, v);
          localStorage.setItem(LLAVE_GUARDADA, String(Date.now()));
        }
      } catch (_) {}
      estado.guardadaEl = leerFecha() || Date.now();
      avisar();
    });
  }

  function vigilar(reg) {
    if (reg.waiting && navigator.serviceWorker.controller) {
      estado.actualizacion = true;
      avisar();
    }
    reg.addEventListener('updatefound', function () {
      var nuevo = reg.installing;
      if (!nuevo) return;
      nuevo.addEventListener('statechange', function () {
        if (nuevo.state === 'installed' && navigator.serviceWorker.controller) {
          // Una version nueva bajo completa y espera a que la acepten.
          estado.actualizacion = true;
          avisar();
        } else if (nuevo.state === 'redundant' && !estado.listaSinSenal) {
          estado.guardando = false;
          estado.error =
            'No se pudo guardar la app completa en el telefono. Se vuelve a ' +
            'intentar la proxima vez que se abra con senal.';
          avisar();
        }
      });
    });
  }

  function alMensaje(e) {
    var m = e.data || {};
    if (m.tipo === 'progreso' && !estado.listaSinSenal) {
      estado.guardando = true;
      estado.hechos = m.hechos;
      estado.total = m.total;
      estado.error = null;
      avisar();
    }
  }

  function buscarVersion() {
    if (registro && navigator.onLine !== false) {
      registro.update().catch(function () {});
    }
  }

  function registrar() {
    if (!('serviceWorker' in navigator)) return;
    var sw = navigator.serviceWorker;
    sw.addEventListener('message', alMensaje);
    sw.addEventListener('controllerchange', function () {
      if (pidioActualizar) {
        window.location.reload();
      } else {
        // Primera instalacion: el service worker tomo esta pagina.
        listo();
      }
    });
    sw.register(new URL('sw.js', base()).href, {
      scope: new URL('./', base()).pathname,
      updateViaCache: 'none',
    })
      .then(function (reg) {
        registro = reg;
        vigilar(reg);
        if (sw.controller && reg.active) listo();
        document.addEventListener('visibilitychange', function () {
          if (document.visibilityState === 'visible') buscarVersion();
        });
        setInterval(buscarVersion, 30 * 60 * 1000);
      })
      .catch(function () {
        // Sin sw.js (un `flutter run`) o sin permiso: la app abre igual,
        // pero no queda guardada para usar sin senal.
      });
  }

  // Se registra despues del primer cuadro: la app ya bajo lo suyo y lo que
  // el service worker pide vuelve del cache del navegador sin gastar datos.
  var registrado = false;
  function registrarUnaVez() {
    if (registrado) return;
    registrado = true;
    registrar();
  }
  window.addEventListener('flutter-first-frame', registrarUnaVez);
  window.addEventListener('load', function () {
    setTimeout(registrarUnaVez, 8000);
  });

  // Que el navegador no borre lo guardado cuando le falte espacio. Safari lo
  // concede a las apps instaladas en la pantalla de inicio.
  try {
    if (navigator.storage && navigator.storage.persist) {
      navigator.storage.persist().catch(function () {});
    }
  } catch (_) {}

  function actualizar() {
    if (!registro) return Promise.resolve(false);
    return registro
      .update()
      .catch(function () {})
      .then(function () {
        var esperando = registro.waiting;
        if (!esperando) return false;
        pidioActualizar = true;
        esperando.postMessage({ tipo: 'activar' });
        return true;
      });
  }

  function versionSw() {
    var c = navigator.serviceWorker && navigator.serviceWorker.controller;
    if (!c) return Promise.resolve(null);
    return new Promise(function (ok) {
      var canal = new MessageChannel();
      var espera = setTimeout(function () {
        ok(null);
      }, 3000);
      canal.port1.onmessage = function (e) {
        clearTimeout(espera);
        ok(e.data || null);
      };
      c.postMessage({ tipo: 'version' }, [canal.port2]);
    });
  }

  function espacio() {
    if (!navigator.storage || !navigator.storage.estimate) {
      return Promise.resolve(null);
    }
    return navigator.storage.estimate().then(function (e) {
      return { usado: e.usage || 0, cuota: e.quota || 0 };
    });
  }

  // ---- Imagenes del mapa ----------------------------------------------------

  function leerTesela(url) {
    if (!('caches' in window)) return Promise.resolve(null);
    return caches
      .open(CACHE_TESELAS)
      .then(function (c) {
        return c.match(url);
      })
      .then(function (r) {
        if (!r) return null;
        var h = r.headers;
        return r.arrayBuffer().then(function (b) {
          var modificada = h.get('x-geomaps-modificada');
          return {
            bytes: new Uint8Array(b),
            vence: Number(h.get('x-geomaps-vence')) || 0,
            modificada: modificada ? Number(modificada) : null,
            etag: h.get('x-geomaps-etag'),
          };
        });
      });
  }

  function guardarTesela(url, bytes, vence, modificada, etag) {
    if (!('caches' in window)) return Promise.resolve();
    return caches.open(CACHE_TESELAS).then(function (c) {
      var cuerpo = bytes
        ? Promise.resolve(bytes)
        : c.match(url).then(function (vieja) {
            // Sin imagen nueva solo se corre el vencimiento; si no habia
            // copia no hay nada que correr.
            return vieja ? vieja.arrayBuffer() : null;
          });
      return cuerpo.then(function (b) {
        if (!b) return;
        var h = new Headers({
          'content-type': 'application/octet-stream',
          'x-geomaps-vence': String(vence),
        });
        if (modificada != null) h.set('x-geomaps-modificada', String(modificada));
        if (etag) h.set('x-geomaps-etag', etag);
        return c.put(url, new Response(b, { headers: h }));
      });
    });
  }

  function contarTeselas() {
    if (!('caches' in window)) return Promise.resolve(0);
    return caches
      .open(CACHE_TESELAS)
      .then(function (c) {
        return c.keys();
      })
      .then(function (k) {
        return k.length;
      });
  }

  // ---- Pantalla encendida ---------------------------------------------------

  function pantallaEncendida(si) {
    quiereEncendida = si;
    if (!('wakeLock' in navigator)) return Promise.resolve();
    if (!si) {
      var b = bloqueo;
      bloqueo = null;
      return b ? b.release().catch(function () {}) : Promise.resolve();
    }
    if (bloqueo) return Promise.resolve();
    return navigator.wakeLock
      .request('screen')
      .then(function (b) {
        bloqueo = b;
        b.addEventListener('release', function () {
          if (bloqueo === b) bloqueo = null;
        });
      })
      .catch(function () {});
  }

  // El navegador suelta el bloqueo al esconder la app; al volver se pide de
  // nuevo si el mapa sigue abierto.
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible' && quiereEncendida && !bloqueo) {
      pantallaEncendida(true);
    }
  });

  window.geomapsPwa = {
    base: base,
    instalada: instalada,
    esIphone: esIphone,
    navegador: function () {
      return navigator.userAgent;
    },
    estado: function () {
      return estado;
    },
    alCambiar: function (f) {
      oyentes.push(f);
    },
    actualizar: actualizar,
    espacio: espacio,
    versionSw: versionSw,
    leerTesela: leerTesela,
    guardarTesela: guardarTesela,
    contarTeselas: contarTeselas,
    pantallaEncendida: pantallaEncendida,
  };
})();
