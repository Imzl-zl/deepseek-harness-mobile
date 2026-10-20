plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.dsh_mobile"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.dsh_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
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

dependencies {
    // `androidx.core.content.FileProvider` —— 拍照要用它把
    // `cacheDir/dsh_photo/` 下的临时文件授权给相机应用写
    // （`ACTION_IMAGE_CAPTURE` 在 API 24+ 必须收 `content://` 的 EXTRA_OUTPUT，
    // 给 `file://` 会抛 FileUriExposedException）。
    //
    // 这是本仓**唯一**手写的 Android 依赖：Flutter 的 embedding 不带
    // `androidx.core` 的 provider 部分，所以显式声明。版本取 1.13.1 ——
    // 与 `flutter.compileSdkVersion`（36）兼容的常用稳定版；不追最新，
    // 追新只会让"下次构建能不能过"变成运气问题。
    implementation("androidx.core:core:1.13.1")
}
