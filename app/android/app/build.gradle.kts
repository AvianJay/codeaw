plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePath = providers.environmentVariable("KEYSTORE_PATH").orNull
val releaseKeystoreAlias = providers.environmentVariable("KEYSTORE_ALIAS").orNull
val releaseKeystorePassword = providers.environmentVariable("KEYSTORE_PASSWORD").orNull
val releaseSigningValues = listOf(releaseKeystorePath, releaseKeystoreAlias, releaseKeystorePassword)
val hasReleaseSigning = releaseSigningValues.any { !it.isNullOrBlank() }
require(!hasReleaseSigning || releaseSigningValues.all { !it.isNullOrBlank() }) {
    "Release signing requires KEYSTORE_PATH, KEYSTORE_ALIAS, and KEYSTORE_PASSWORD."
}

val abiForPlatform = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val targetAbis = providers.gradleProperty("target-platform")
    .getOrElse("android-arm,android-arm64,android-x64")
    .split(",")
    .map { platform -> requireNotNull(abiForPlatform[platform]) { "Unsupported Android target: $platform" } }
val splitPerAbi = providers.gradleProperty("split-per-abi").getOrElse("false").toBoolean()

android {
    namespace = "tw.avianjay.codeaw"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "tw.avianjay.codeaw"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeystoreAlias
                keyPassword = releaseKeystorePassword
            }
        }
    }

    buildTypes {
        configureEach {
            // Flutter otherwise includes dependencies for every supported ABI,
            // even when --target-platform builds the engine for just one ABI.
            if (!splitPerAbi) {
                ndk.abiFilters.clear()
                ndk.abiFilters.addAll(targetAbis)
            }
        }
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
