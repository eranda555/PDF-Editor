plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    namespace = "com.hundredpercentpdf.hundred_percent_pdf"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.hundredpercentpdf.hundred_percent_pdf"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DPDF_PREBUILT_ROOT=${project.projectDir}/../../native/prebuilt/android",
                    "-DANDROID_STL=c++_shared",
                )
            }
        }
    }
    externalNativeBuild {
        cmake { path = file("../../native/CMakeLists.txt"); version = "3.22.1" }
    }
    buildTypes {
        release {
            val keyPath = System.getenv("PDF_SIGNING_KEYSTORE")
            if (keyPath != null) {
                signingConfig = signingConfigs.create("distribution") {
                    storeFile = file(keyPath)
                    storePassword = System.getenv("PDF_SIGNING_STORE_PASSWORD")
                    keyAlias = System.getenv("PDF_SIGNING_KEY_ALIAS")
                    keyPassword = System.getenv("PDF_SIGNING_KEY_PASSWORD")
                }
            }
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
