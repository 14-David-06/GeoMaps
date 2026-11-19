package com.siriusregenerative.geomaps

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** Elegir y dibujar planos en PDF. Ver [PlanosNativos]. */
    private var planos: PlanosNativos? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        planos = PlanosNativos(this, flutterEngine.dartExecutor.binaryMessenger)

        // Que telefono es, para los informes de error (lib/core/telefono.dart):
        // un fallo que solo pasa en un modelo no se encuentra sin saber cual.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "geomaps/telefono")
            .setMethodCallHandler { llamada, resultado ->
                if (llamada.method == "descripcion") {
                    val marca = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                    resultado.success("$marca ${Build.MODEL} · Android ${Build.VERSION.RELEASE}")
                } else {
                    resultado.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // El selector de planos se abre desde aca y no desde un plugin, asi que
        // su vuelta hay que atajarla antes de pasarsela a Flutter.
        if (planos?.alVolver(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
