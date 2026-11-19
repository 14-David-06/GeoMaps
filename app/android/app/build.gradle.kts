import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// La llave de release. Vive FUERA del repo (key.properties y el .jks estan en
// .gitignore) y es la misma para siempre: Android solo instala un APK encima
// de otro si los dos estan firmados con la misma llave. Con otra, la
// actualizacion se rechaza y la unica salida es desinstalar, que borra la
// base local con todo lo que no se sincronizo. Perderla es no poder
// actualizar nunca mas. Ver docs/despliegue.md, "Firma del APK".
val archivoFirma = rootProject.file("key.properties")
val firma = Properties().apply {
    if (archivoFirma.exists()) FileInputStream(archivoFirma).use { load(it) }
}
val hayFirma = archivoFirma.exists()

// El .aab solo existe para Play Store; el APK es el que se reparte directo y
// se actualiza solo con ota_update. Play no acepta una app que se instale
// versiones por fuera de la tienda, asi que al compilar un bundle se suma
// src/play/AndroidManifest.xml, que quita REQUEST_INSTALL_PACKAGES y el
// provider de ota_update. La app detecta en runtime que vino de Play y manda a
// la tienda en vez de bajar el APK. Ver docs/despliegue.md, "Play Store".
val esParaPlay = gradle.startParameter.taskNames.any {
    it.contains("bundle", ignoreCase = true)
}

android {
    namespace = "com.siriusregenerative.geomaps"
    // Fijado en 37 y no heredado de flutter.compileSdkVersion (36) porque algun
    // plugin ya se compila contra 37. Contra 37 no cambia el comportamiento en
    // runtime: eso lo define targetSdk. Es el mismo ajuste que en sirius_agro.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Lo pide ota_update (el que baja e instala el APK nuevo).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Lo pide ota_update, que usa APIs de java.time. Sin esto el build
        // falla en checkDebugAarMetadata antes de compilar una sola clase.
        // Hace falta porque minSdk es 24: de 26 en adelante esas APIs ya vienen
        // en el sistema, pero bajar la compatibilidad a 26 dejaria afuera los
        // telefonos de campo mas viejos, que es justo para quienes es la app.
        isCoreLibraryDesugaringEnabled = true
    }

    if (esParaPlay) {
        // El manifiesto de un build type pesa mas que el de main y que los de
        // los plugins, asi que sus tools:node="remove" ganan.
        sourceSets.getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.siriusregenerative.geomaps"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 24 (Android 7). Por debajo no hay telefono en campo, y subirlo solo
        // dejaria gente afuera sin ganar nada.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hayFirma) {
                keyAlias = firma.getProperty("keyAlias")
                keyPassword = firma.getProperty("keyPassword")
                storeFile = file(firma.getProperty("storeFile"))
                storePassword = firma.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Sin key.properties se firma con la de debug para que
            // `flutter run --release` ande en cualquier maquina. Ese APK NO se
            // reparte: tools/publicar_apk.py se niega a publicarlo.
            signingConfig = if (hayFirma) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "GeoMaps: falta android/key.properties. El APK de release " +
                        "sale firmado con la llave de DEBUG y no sirve para repartir.",
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Solo las arquitecturas de telefonos de verdad. `--target-platform` saca el
// x86_64 de Flutter, pero los plugins con codigo nativo (el lector de QR,
// SQLite) traen el suyo igual: otros 7 MB que ningun telefono usa y que cada
// actualizacion bajaria por senal rural.
//
// Se saca al empaquetar y solo en release: el emulador, que si es x86_64,
// corre la compilacion de debug. No sirve un `abiFilters` en el buildType
// porque el plugin de Flutter pone los suyos en defaultConfig -con x86_64
// adentro- y Gradle une las dos listas en vez de reemplazar una por otra.
androidComponents {
    onVariants(selector().withBuildType("release")) { variante ->
        variante.packaging.jniLibs.excludes.add("**/x86_64/**")
        variante.packaging.jniLibs.excludes.add("**/x86/**")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
