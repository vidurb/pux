import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun keystoreProperty(name: String): String =
    requireNotNull(keystoreProperties.getProperty(name)) {
        "android/key.properties is missing $name (see key.properties.example)"
    }

android {
    namespace = "xyz.vidur.pux"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperty("keyAlias")
                keyPassword = keystoreProperty("keyPassword")
                storeFile = file(keystoreProperty("storeFile"))
                storePassword = keystoreProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "xyz.vidur.pux"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Never fall back to the debug key: a debug-signed release cannot be
            // updated by a properly signed one later.
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Debug builds (CI) work without key.properties; release builds fail before
// any task runs.
gradle.taskGraph.whenReady {
    if (!hasReleaseKeystore && allTasks.any { it.project == project && it.name == "preReleaseBuild" }) {
        throw GradleException(
            "Release builds need a release keystore: copy android/key.properties.example " +
                "to android/key.properties and point it at your keystore. " +
                "Use `flutter build apk --debug` for test builds.",
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // PackageManagerCompat and IntentCompat, for app hibernation. Plugins already
    // bring in this version; ListenableFuture is its status call's return type.
    implementation("androidx.core:core:1.13.1")
    implementation("com.google.guava:listenablefuture:1.0")
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
