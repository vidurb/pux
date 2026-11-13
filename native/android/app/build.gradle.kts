import java.io.File
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
}

val propVersionCode = (project.findProperty("versionCode") ?: project.findProperty("buildNumber"))?.toString()?.toIntOrNull()
val propVersionName = project.findProperty("versionName")?.toString() ?: "0.1.0"
val puxServerUrl = project.findProperty("puxServerUrl")?.toString() ?: "https://pux.vidur.xyz"

val keyPropertiesFile = if (project.hasProperty("keyProperties")) {
    file(project.property("keyProperties") as String)
} else {
    rootProject.file("key.properties")
}

val keystoreProperties = Properties()
val hasReleaseKeystore = keyPropertiesFile.exists()
if (hasReleaseKeystore) {
    keyPropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun keystoreProperty(name: String): String =
    requireNotNull(keystoreProperties.getProperty(name)) {
        "${keyPropertiesFile.path} is missing $name (see key.properties.example)"
    }

android {
    namespace = "xyz.vidur.pux"
    compileSdk = 37

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperty("keyAlias")
                keyPassword = keystoreProperty("keyPassword")
                val storeFilePath = keystoreProperty("storeFile")
                val rawFile = File(storeFilePath)
                storeFile = if (rawFile.isAbsolute) {
                    rawFile
                } else {
                    keyPropertiesFile.parentFile.resolve(storeFilePath)
                }
                storePassword = keystoreProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "xyz.vidur.pux"
        minSdk = 24
        targetSdk = 36
        versionCode = propVersionCode ?: 1
        versionName = propVersionName

        buildConfigField("String", "DEFAULT_SERVER_URL", "\"$puxServerUrl\"")

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            // Default stubs break org.json on non-Robolectric JVM tests (PuxCryptoTest, ApiClientTest).
            isReturnDefaultValues = false
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // AndroidX & Core
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("com.google.guava:listenablefuture:1.0")

    // Jetpack Compose BOM & UI
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // Security & Keystore
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Bouncy Castle for Wire-Compatible libsodium sealed box crypto
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")

    // Networking & HTTP
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Firebase (FCM + Installations)
    implementation("com.google.firebase:firebase-messaging:26.0.1")
    implementation("com.google.firebase:firebase-installations:18.0.0")

    // CameraX & ML Kit Barcode Scanning
    implementation("androidx.camera:camera-core:1.4.1")
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // QR Code Generation
    implementation("com.google.zxing:core:3.5.3")

    // Testing
    testImplementation("junit:junit:4.13.2")
    // JVM unit tests (non-Robolectric) need a real org.json; RelayNotificationTest uses android org.json via Robolectric.
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.activity:activity-compose:1.9.3")
    testImplementation("org.bouncycastle:bcprov-jdk18on:1.79")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// Robolectric against SDK 36+ must run on JDK 21; serial forks avoid sandbox deadlocks.
tasks.withType<Test>().configureEach {
    javaLauncher.set(
        javaToolchains.launcherFor {
            languageVersion.set(JavaLanguageVersion.of(21))
        }
    )
    maxParallelForks = 1
    jvmArgs(
        "--add-opens=java.base/java.io=ALL-UNNAMED",
        "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
    )
}

gradle.taskGraph.whenReady {
    val releaseRequested = allTasks.any {
        it.project == project && it.name in setOf(
            "assembleRelease", "bundleRelease", "packageRelease", "validateSigningRelease", "lintVitalRelease"
        )
    }
    if (releaseRequested && propVersionCode == null) {
        throw GradleException(
            "Release builds require an explicit versionCode (e.g. -PversionCode=<build number> or -PbuildNumber=<n>). " +
                "Debug builds may omit it and default to 1."
        )
    }
    if (!hasReleaseKeystore && releaseRequested) {
        throw GradleException(
            "Release builds require a release keystore configuration: create native/android/key.properties " +
                "(see key.properties.example) or pass -PkeyProperties=/path/to/key.properties."
        )
    }
}
