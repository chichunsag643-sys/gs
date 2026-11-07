import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.gs.gs_note"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.gs.gs_note"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 9+ (all current Galaxy devices); needed for BiometricPrompt.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release builds must always be signed with the same key, or Android
    // refuses to install an update over the existing app (and the only way
    // out would be uninstalling, which deletes the on-device notes).
    // CI provides the key through two repository secrets:
    //   ANDROID_KEYSTORE_BASE64   - base64 of the PKCS12 keystore (alias "gsnote")
    //   ANDROID_KEYSTORE_PASSWORD - its password
    // Without them, release builds fall back to the local debug key.
    val keystoreBase64 = System.getenv("ANDROID_KEYSTORE_BASE64")?.trim()
    val keystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")?.trim()
    val hasReleaseKey = !keystoreBase64.isNullOrEmpty() && !keystorePassword.isNullOrEmpty()

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                val file = layout.buildDirectory.file("release.p12").get().asFile
                file.parentFile.mkdirs()
                file.writeBytes(Base64.getMimeDecoder().decode(keystoreBase64))
                storeFile = file
                storeType = "PKCS12"
                storePassword = keystorePassword
                keyAlias = "gsnote"
                keyPassword = keystorePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
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
