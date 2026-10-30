import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发版签名：**有 `android/key.properties` 就用它，没有就退到 debug 签名**。
// 密钥本体（*.jks）与 key.properties 都不进库；CI 从 Secrets 解出来（见 docs/cookbook/release.md）。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "io.github.imzlzl.dsh_mobile"
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
        // **第一次发版后不能再改**：applicationId 就是 Android 眼里的应用身份，改了等于另一个应用
        // （老用户装不上更新）。这里按仓库的 GitHub handle 取反域名。
        applicationId = "io.github.imzlzl.dsh_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 没配密钥时用 debug 签名：本机构建照常、CI 也能出包，但这种 APK
            // **不能覆盖升级**（换了机器/换了密钥就是签名不一致）—— 发版必须配密钥。
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
