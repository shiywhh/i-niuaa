plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.eleven.nuaa"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.eleven.nuaa"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode 从 versionName 派生：major*10000 + minor*100 + patch。
        // v2.0.0 官方包 versionCode=2001（当时手工 +N 的遗留口径），Android
        // 只比较整数，后续任何构建都必须高过它；派生后 2.0.0→20000、
        // 2.2.0→20200，永远不会再撞上"已安装更高版本"
        val vParts = flutter.versionName.split(".")
        versionCode = vParts[0].toInt() * 10000 + vParts[1].toInt() * 100 +
            (vParts.getOrNull(2)?.toIntOrNull() ?: 0)
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
