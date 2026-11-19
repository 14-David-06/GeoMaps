{{flutter_js}}
{{flutter_build_config}}

// GeoMaps web. Lo que cambia frente al arranque por defecto de Flutter:
//
// - Sin `serviceWorkerSettings`: el service worker de Flutter esta en desuso.
//   El de GeoMaps es `sw.js` y lo registra geomaps_pwa.js.
// - `canvasKitVariant: "full"`: siempre la misma CanvasKit, la que corre en
//   Safari. Asi el service worker guarda una sola y no las cuatro variantes.
// - `fontFallbackBaseUrl` en el mismo dominio: por defecto Flutter baja Roboto
//   de fonts.gstatic.com al arrancar, y en modo avion la app abria sin letras.
//   tools/compilar_pwa.py deja la fuente en la ruta que el motor pide.
// - `hostElement`: Flutter dibuja dentro de #geomaps, que se aparta de los
//   bordes del iPhone (ver index.html).
(function () {
  var config = {
    canvasKitVariant: 'full',
    fontFallbackBaseUrl: new URL('fuentes/', document.baseURI).href,
  };
  _flutter.loader.load({
    config: config,
    onEntrypointLoaded: async function (motor) {
      var app = await motor.initializeEngine(
        Object.assign({}, config, {
          hostElement: document.getElementById('geomaps'),
        })
      );
      await app.runApp();
    },
  });
})();
