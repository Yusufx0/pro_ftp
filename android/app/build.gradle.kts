import java.io.FileInputStream
import java.util.Properties

// 1. İMZA YAPILANDIRMASI İÇİN PROPERTIES DOSYASINI OKUMA BÖLÜMÜ
val keystoreProperties = Properties()
val keystorePropertiesFile = file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
} else {
    println("Uyarı: key.properties dosyası bulunamadı! Eğer release (sürüm) alıyorsanız GitHub Actions üzerinden ayarlanacaktır.")
}

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.corebyte.ftpcore"
    compileSdk = 34
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.corebyte.ftpcore"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 2. İMZA YAPILANDIRMASI OLUŞTURMA BÖLÜMÜ
    signingConfigs {
        create("release") {
            // Sadece dosya varsa imza bilgilerini ata, yoksa hata verme
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 3. OLUŞTURULAN İMZAYI RELEASE İÇİN KULLANMA
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

dependencies {
    implementation("commons-net:commons-net:3.10.0") 
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3") 
}
