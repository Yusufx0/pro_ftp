import java.io.FileInputStream
import java.util.Properties

// 1. İMZA YAPILANDIRMASI İÇİN PROPERTIES DOSYASINI OKUMA BÖLÜMÜ
val keystoreProperties = Properties()
val keystorePropertiesFile = file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
} else {
    println("Uyarı: keystore.properties dosyası bulunamadı!")
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.[span_0](start_span)[span_0](end_span)
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ftp.pro_ftp"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).[span_1](start_span)[span_1](end_span)
        applicationId = "com.ftp.pro_ftp"
        // You can update the following values to match your application needs.[span_2](start_span)[span_2](end_span)
        // For more information, see: https://flutter.dev/to/review-gradle-config.[span_3](start_span)[span_3](end_span)
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION[span_4](start_span)[span_4](end_span)
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)[span_5](start_span)[span_5](end_span)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`[span_6](start_span)[span_6](end_span)
        // flag during build.[span_7](start_span)[span_7](end_span)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 2. İMZA YAPILANDIRMASI OLUŞTURMA BÖLÜMÜ
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = file(keystoreProperties.getProperty("storeFile"))
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // 3. OLUŞTURULAN İMZAYI RELEASE (SÜRÜM) İÇİN KULLANMA
            signingConfig = signingConfigs.getByName("release")
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
