plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.designxdevelop.luma.wear"
    compileSdk { version = release(36) { minorApiLevel = 1 } }
    defaultConfig {
        applicationId = "com.designxdevelop.luma" // Same package as the phone app, as Wear OS pairing requires.
        minSdk = 30
        targetSdk = 36
        // Play needs a unique versionCode per bundle: the watch sits 100000 above the phone build.
        versionCode = 100_000 + (findProperty("versionCode") as String? ?: System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "1.0"
    }
    // Same upload key as the phone app (docs/PLAY.md). Without it, release builds are unsigned.
    val uploadKeystore = System.getenv("LUMA_UPLOAD_KEYSTORE")?.takeIf { it.isNotBlank() }?.let(::file)?.takeIf { it.isFile }
    signingConfigs {
        if (uploadKeystore != null) create("upload") {
            storeFile = uploadKeystore
            storePassword = System.getenv("LUMA_UPLOAD_PASSWORD")
            keyAlias = System.getenv("LUMA_UPLOAD_ALIAS") ?: "luma-upload"
            keyPassword = System.getenv("LUMA_UPLOAD_PASSWORD")
        }
    }
    buildTypes { release { isMinifyEnabled = false; signingConfigs.findByName("upload")?.let { signingConfig = it } } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildFeatures { compose = true }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.12.01"))
    implementation("androidx.wear.compose:compose-material3:1.6.2")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
}
