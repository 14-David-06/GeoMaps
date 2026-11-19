/// La version web de GeoMaps: la que se instala en un iPhone desde Safari
/// ("Agregar a pantalla de inicio"), porque no hay cuenta de Apple para
/// publicarla en la App Store.
///
/// Lo que la web hace distinto del telefono Android vive detras de esta
/// fachada: el service worker que la deja abrir sin senal, la cache de las
/// imagenes del mapa, las fuentes empaquetadas y saber si la app corre
/// instalada o en una pestana de Safari.
///
/// En Android y en las pruebas se usa `pwa_movil.dart`, donde todo es inerte:
/// ningun flujo del telefono pasa por aca. En el navegador se usa
/// `pwa_web.dart`, que habla con `web/geomaps_pwa.js`.
library;

export 'pwa_tipos.dart';
export 'pwa_movil.dart' if (dart.library.js_interop) 'pwa_web.dart';
