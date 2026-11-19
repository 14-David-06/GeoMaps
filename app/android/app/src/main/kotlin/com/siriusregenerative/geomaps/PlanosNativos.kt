package com.siriusregenerative.geomaps

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Elegir un plano en PDF y dibujarlo, sin que el archivo ni sus pixeles pasen
 * por la memoria de Dart. El porque esta contado en `lib/core/motor_planos.dart`.
 *
 * Todo el trabajo pesado va a un hilo propio: copiar un PDF de 80 MB o dibujar
 * una hoja cartografica tarda segundos, y en el hilo principal eso es una app
 * congelada que Android ofrece cerrar.
 */
class PlanosNativos(
    private val actividad: Activity,
    mensajero: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val canal = MethodChannel(mensajero, "geomaps/planos")
    private val hilo = Executors.newSingleThreadExecutor()
    private val principal = Handler(Looper.getMainLooper())

    /** La respuesta que espera Dart mientras el selector esta abierto. */
    private var eleccionPendiente: MethodChannel.Result? = null

    init {
        canal.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "elegir" -> elegir(result)
            "hoja" -> enHilo(result) {
                hoja(call.argument<String>("ruta")!!, call.argument<Int>("pagina")!!)
            }
            "dibujar" -> enHilo(result) { dibujar(call) }
            else -> result.notImplemented()
        }
    }

    // --- Elegir ---------------------------------------------------------------

    private fun elegir(result: MethodChannel.Result) {
        if (eleccionPendiente != null) {
            result.error("ocupado", "Ya hay un selector abierto", null)
            return
        }
        // No se filtra solo por `application/pdf`: un PDF que llego por
        // WhatsApp o que alguien renombro suele venir sin tipo, y con el
        // filtro estricto aparece gris en el selector, imposible de tocar.
        // Que sea un PDF de verdad lo comprueba Dart al leerlo.
        val pedido = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/pdf", "application/x-pdf", "application/octet-stream"),
            )
        }
        eleccionPendiente = result
        try {
            actividad.startActivityForResult(pedido, CODIGO_ELEGIR)
        } catch (e: ActivityNotFoundException) {
            eleccionPendiente = null
            result.error("sin_selector", e.message, null)
        }
    }

    /** Lo llama la actividad cuando vuelve el selector. True si era para aca. */
    fun alVolver(codigo: Int, resultado: Int, datos: Intent?): Boolean {
        if (codigo != CODIGO_ELEGIR) return false
        val result = eleccionPendiente ?: return true
        eleccionPendiente = null

        val uri = datos?.data
        if (resultado != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        enHilo(result) { copiar(uri) }
        return true
    }

    /**
     * Copia lo elegido a la carpeta temporal de la app.
     *
     * Hace falta un archivo de verdad: lo que entrega el selector es una
     * direccion `content://` que puede salir de Drive o de WhatsApp, y el motor
     * de PDF necesita poder moverse por el archivo, cosa que esos proveedores
     * no siempre permiten. Se copia por bloques, sin cargarlo en memoria.
     */
    private fun copiar(uri: Uri): Map<String, Any?> {
        val carpeta = File(actividad.cacheDir, "planos")
        // Lo de la importacion anterior ya no sirve, y son megas.
        carpeta.deleteRecursively()
        carpeta.mkdirs()

        val destino = File(carpeta, "elegido.pdf")
        try {
            val entrada = actividad.contentResolver.openInputStream(uri)
                ?: throw IOException("El proveedor no entrego el archivo")
            entrada.use { desde ->
                FileOutputStream(destino).use { hacia -> desde.copyTo(hacia, 1 shl 16) }
            }
        } catch (e: IOException) {
            throw Falla("copia", e.message)
        } catch (e: SecurityException) {
            throw Falla("copia", e.message)
        }
        return mapOf("ruta" to destino.absolutePath, "nombre" to nombreDe(uri))
    }

    private fun nombreDe(uri: Uri): String? = try {
        actividad.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    // --- Dibujar --------------------------------------------------------------

    private fun hoja(ruta: String, pagina: Int): Map<String, Any?> = abrir(ruta) { lector ->
        if (pagina < 0 || pagina >= lector.pageCount) {
            throw Falla("ilegible", "El PDF no tiene la hoja ${pagina + 1}")
        }
        lector.openPage(pagina).use { h ->
            mapOf("paginas" to lector.pageCount, "ancho" to h.width, "alto" to h.height)
        }
    }

    /**
     * Dibuja un rectangulo de la hoja a un PNG.
     *
     * La matriz hace las dos cosas a la vez: corre el origen a la esquina del
     * rectangulo y lo escala al tamano pedido. Asi el mapa de bits es solo del
     * tamano de lo que se va a guardar, y no de la hoja entera.
     *
     * El mapa de bits no se pinta de blanco antes: lo que el PDF no dibuja
     * queda transparente, y eso deja ver el satelital por debajo del plano.
     *
     * El color del papel se puede recibir ya decidido (`papel`). Es para los
     * cuadros de detalle de un plano grande: cada uno es un pedazo de la hoja,
     * y si cada pedazo eligiera su papel por su cuenta, uno lleno de relleno
     * no encontraria ninguno y quedaria opaco al lado de sus vecinos. El papel
     * se decide una vez, mirando la hoja entera, y de ahi en mas se dice.
     */
    private fun dibujar(call: MethodCall): Map<String, Any?> {
        val ruta = call.argument<String>("ruta")!!
        val pagina = call.argument<Int>("pagina")!!
        val x = call.argument<Double>("x")!!.toFloat()
        val y = call.argument<Double>("y")!!.toFloat()
        val ancho = call.argument<Double>("ancho")!!.toFloat()
        val alto = call.argument<Double>("alto")!!.toFloat()
        val anchoPx = call.argument<Int>("anchoPx")!!
        val altoPx = call.argument<Int>("altoPx")!!
        val destino = File(call.argument<String>("destino")!!)
        val destinoSinFondo = call.argument<String>("destinoSinFondo")?.let { File(it) }
        val papelDado = call.argument<List<Int>>("papel")
            ?.takeIf { it.size == 3 }
            ?.toIntArray()

        return abrir(ruta) { lector ->
            lector.openPage(pagina).use { h ->
                val mapa = Bitmap.createBitmap(anchoPx, altoPx, Bitmap.Config.ARGB_8888)
                try {
                    val matriz = Matrix().apply {
                        setTranslate(-x, -y)
                        postScale(anchoPx / ancho, altoPx / alto)
                    }
                    h.render(mapa, null, matriz, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    guardar(mapa, destino)

                    // La segunda copia, sin el papel: se trabaja sobre el mismo
                    // mapa de bits, despues de haber guardado la primera, para
                    // no tener dos hojas enteras en memoria a la vez.
                    var sinFondo = false
                    val fondo = if (destinoSinFondo == null) {
                        null
                    } else {
                        papelDado ?: colorDelPapel(mapa)
                    }
                    if (fondo != null && destinoSinFondo != null) {
                        quitarPapel(mapa, fondo)
                        guardar(mapa, destinoSinFondo)
                        sinFondo = true
                    }
                    mapOf("sinFondo" to sinFondo, "papel" to fondo?.toList())
                } finally {
                    mapa.recycle()
                }
            }
        }
    }

    private fun guardar(mapa: Bitmap, destino: File) {
        FileOutputStream(destino).use { salida ->
            if (!mapa.compress(Bitmap.CompressFormat.PNG, 100, salida)) {
                throw IOException("No se pudo escribir la imagen")
            }
        }
    }

    // --- Quitar el papel ------------------------------------------------------

    /**
     * El color del papel del plano, o null si no tiene uno.
     *
     * Un plano se dibuja sobre una hoja blanca -o crema, si es un escaneo-, y
     * esa hoja puesta encima del mapa tapa justo lo que se queria ver: el
     * terreno entre las lineas. El papel se reconoce porque es **un solo color
     * claro que ocupa buena parte de la hoja**.
     *
     * Cuando no hay tal color no se toca nada. Es el caso de un mapa con una
     * ortofoto de fondo -ahi el "fondo" es la informacion- y el de un plano que
     * ya viene sin papel, que el motor deja transparente.
     */
    private fun colorDelPapel(mapa: Bitmap): IntArray? {
        val ancho = mapa.width
        val alto = mapa.height
        // Con medio millon de muestras alcanza; mirar los trece millones de
        // pixeles para decidir un color es tiempo que la persona espera.
        val paso = max(1, sqrt(ancho.toDouble() * alto / 500_000).toInt())
        val fila = IntArray(ancho)

        // Los colores agrupados de a 16 niveles por canal: 4096 cajones.
        val cuenta = IntArray(4096)
        val rojos = LongArray(4096)
        val verdes = LongArray(4096)
        val azules = LongArray(4096)
        var opacos = 0L
        var muestras = 0L

        var y = 0
        while (y < alto) {
            mapa.getPixels(fila, 0, ancho, 0, y, ancho, 1)
            var x = 0
            while (x < ancho) {
                val p = fila[x]
                muestras++
                if ((p ushr 24) >= 250) {
                    val r = (p shr 16) and 255
                    val g = (p shr 8) and 255
                    val b = p and 255
                    val cajon = ((r shr 4) shl 8) or ((g shr 4) shl 4) or (b shr 4)
                    cuenta[cajon]++
                    rojos[cajon] += r.toLong()
                    verdes[cajon] += g.toLong()
                    azules[cajon] += b.toLong()
                    opacos++
                }
                x += paso
            }
            y += paso
        }
        // Casi todo transparente: el plano ya viene sin papel.
        if (opacos < muestras / 20) return null

        var mejor = 0
        for (i in 1 until 4096) if (cuenta[i] > cuenta[mejor]) mejor = i

        // El papel de un escaneo no es un color exacto: cae repartido entre
        // cajones vecinos. Se suman para no quedarse corto al contarlo.
        var n = 0L
        var r = 0L
        var g = 0L
        var b = 0L
        for (dr in -1..1) for (dg in -1..1) for (db in -1..1) {
            val cr = (mejor shr 8) + dr
            val cg = ((mejor shr 4) and 15) + dg
            val cb = (mejor and 15) + db
            if (cr !in 0..15 || cg !in 0..15 || cb !in 0..15) continue
            val i = (cr shl 8) or (cg shl 4) or cb
            n += cuenta[i]
            r += rojos[i]
            g += verdes[i]
            b += azules[i]
        }
        if (n == 0L || n < opacos * PARTE_MINIMA_DE_PAPEL) return null

        val color = intArrayOf((r / n).toInt(), (g / n).toInt(), (b / n).toInt())
        // Un color oscuro que domina no es papel: es una foto o un relleno.
        if (color.min() < 190) return null
        // El blanco de un PDF vectorial es blanco exacto.
        for (i in 0..2) if (color[i] >= 250) color[i] = 255
        return color
    }

    /**
     * Saca el papel y deja solo lo dibujado.
     *
     * No es "borrar lo que sea blanco": eso deja un borde blancuzco alrededor
     * de cada linea, porque el borde de una linea es una mezcla de su color con
     * el del papel. Se deshace la mezcla: de cada pixel se calcula cuanto papel
     * tiene, esa parte se vuelve transparencia, y lo que queda es el color de
     * la tinta. Una linea negra sale negra con el borde suave, y un relleno
     * amarillo palido sale como un velo amarillo que deja ver el terreno.
     */
    private fun quitarPapel(mapa: Bitmap, papel: IntArray) {
        val ancho = mapa.width
        val alto = mapa.height
        val tanda = 32
        val bufer = IntArray(ancho * tanda)
        val pr = papel[0].toFloat()
        val pg = papel[1].toFloat()
        val pb = papel[2].toFloat()

        var y = 0
        while (y < alto) {
            val filas = min(tanda, alto - y)
            mapa.getPixels(bufer, 0, ancho, 0, y, ancho, filas)
            for (i in 0 until ancho * filas) {
                val p = bufer[i]
                val a = p ushr 24
                if (a == 0) continue
                val r = (p shr 16) and 255
                val g = (p shr 8) and 255
                val b = p and 255

                // Cuanta tinta hay: lo mas que se aparta del papel algun canal.
                val tinta = max(lejos(r, pr), max(lejos(g, pg), lejos(b, pb)))
                if (tinta <= RUIDO_DEL_PAPEL) {
                    bufer[i] = 0
                    continue
                }
                val nr = sinPapel(r, pr, tinta)
                val ng = sinPapel(g, pg, tinta)
                val nb = sinPapel(b, pb, tinta)
                // El ruido se descuenta de forma pareja, para que no quede un
                // escalon entre lo que se borro y lo que no.
                val visible = (tinta - RUIDO_DEL_PAPEL) / (1f - RUIDO_DEL_PAPEL)
                val na = (a * visible + 0.5f).toInt().coerceIn(0, 255)
                bufer[i] = (na shl 24) or (nr shl 16) or (ng shl 8) or nb
            }
            mapa.setPixels(bufer, 0, ancho, 0, y, ancho, filas)
            y += filas
        }
    }

    /** Que tan lejos esta un canal del papel, de 0 (es papel) a 1 (lo opuesto). */
    private fun lejos(c: Int, papel: Float): Float = when {
        c > papel -> if (papel >= 255f) 0f else (c - papel) / (255f - papel)
        c < papel -> (papel - c) / papel
        else -> 0f
    }

    /** El color de la tinta sola, sabiendo cuanta hay mezclada con el papel. */
    private fun sinPapel(c: Int, papel: Float, tinta: Float): Int =
        ((c - papel) / tinta + papel + 0.5f).toInt().coerceIn(0, 255)

    private fun <T> abrir(ruta: String, usar: (PdfRenderer) -> T): T {
        val descriptor = try {
            ParcelFileDescriptor.open(File(ruta), ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (e: IOException) {
            throw Falla("ilegible", e.message)
        }
        val lector = try {
            PdfRenderer(descriptor)
        } catch (e: SecurityException) {
            // Asi avisa Android que el PDF pide clave para abrirse.
            descriptor.close()
            throw Falla("protegido", e.message)
        } catch (e: IOException) {
            descriptor.close()
            throw Falla("ilegible", e.message)
        }
        // El lector se queda con el descriptor y lo cierra con el.
        return lector.use(usar)
    }

    // --- Hilo y respuestas ----------------------------------------------------

    /** Corre [tarea] fuera del hilo principal y le contesta a Dart en el. */
    private fun enHilo(result: MethodChannel.Result, tarea: () -> Any?) {
        hilo.execute {
            try {
                val valor = tarea()
                principal.post { result.success(valor) }
            } catch (e: Falla) {
                principal.post { result.error(e.codigo, e.message, null) }
            } catch (e: OutOfMemoryError) {
                principal.post { result.error("memoria", e.message, null) }
            } catch (e: Throwable) {
                principal.post { result.error("fallo", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private class Falla(val codigo: String, mensaje: String?) : Exception(mensaje)

    companion object {
        private const val CODIGO_ELEGIR = 0x6D50

        /** De lo pintado, cuanto tiene que ser de un mismo color claro para ser papel. */
        private const val PARTE_MINIMA_DE_PAPEL = 0.30

        /**
         * Hasta donde se considera papel lo que casi lo es. Un escaneo o una
         * imagen comprimida no tienen el papel parejo: sin este margen quedaria
         * una niebla de puntitos sobre todo el plano.
         */
        private const val RUIDO_DEL_PAPEL = 0.06f
    }
}
