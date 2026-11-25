import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("io.sentry.android.gradle")
}

// Release signing comes from android/key.properties, which CI writes from repository secrets and which is never
// committed. Without it a local release build is signed with the debug key; CI sets BLACKPEARL_REQUIRE_SIGNING so a
// tag build can't quietly do that.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keyProperties.getProperty("storeFile") != null
if (!hasReleaseKey && System.getenv("BLACKPEARL_REQUIRE_SIGNING") == "1") {
    throw GradleException("android/key.properties is missing, so the release can't be signed.")
}

android {
    namespace = "io.github.svovoniks.blackpearlmobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.svovoniks.blackpearlmobile"
        // flutter_secure_storage needs 24; flutter_webrtc needs 21 and mobile_scanner 23.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    // Compresses the native libraries (libmpv, libwebrtc, Flutter's engine) in the APK, which halves its download.
    // Android then unpacks them on install instead of loading them straight from the APK, which takes more storage.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Sentry's Gradle plugin, for one thing only: R8 renames the release build's Java and Kotlin classes, so the plugin
// writes a mapping id into the APK (Sentry's Android SDK sends it with each crash) and uploads the R8 mapping under that
// id, which turns the crash's frames back into the real names. It uploads only where SENTRY_AUTH_TOKEN is set, which
// only CI's tag build does; elsewhere it just writes the id. Everything else it would do by default is off: it adds no
// SDK integrations, changes no bytecode, uploads no sources or native symbols and sends no telemetry, so reports stay
// as lib/diagnostics/crash_reports.dart describes.
val sentryAuthToken: String? = System.getenv("SENTRY_AUTH_TOKEN")?.takeIf { it.isNotBlank() }

sentry {
    org.set("svovolabs")
    projectName.set("blackpearl-mobile")
    authToken.set(sentryAuthToken)
    includeProguardMapping.set(true)
    autoUploadProguardMapping.set(sentryAuthToken != null)
    uploadNativeSymbols.set(false)
    includeNativeSources.set(false)
    includeSourceContext.set(false)
    includeDependenciesReport.set(false)
    telemetry.set(false)
    autoInstallation {
        enabled.set(false)
    }
    tracingInstrumentation {
        enabled.set(false)
        features.set(emptySet())
        logcat {
            enabled.set(false)
        }
    }
    runtimeOptimizations {
        enabled.set(false)
    }
    sizeAnalysis {
        enabled.set(false)
    }
    distribution {
        enabled.set(false)
    }
    snapshots {
        enabled.set(false)
    }
}

dependencies {
    // FileProvider, for handing a downloaded update to the installer.
    implementation("androidx.core:core:1.13.1")
}
