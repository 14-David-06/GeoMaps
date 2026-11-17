package com.siriusregenerative.geomaps

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /** Elegir y dibujar planos en PDF. Ver [PlanosNativos]. */
    private var planos: PlanosNativos? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        planos = PlanosNativos(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // El selector de planos se abre desde aca y no desde un plugin, asi que
        // su vuelta hay que atajarla antes de pasarsela a Flutter.
        if (planos?.alVolver(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
