plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.designxdevelop.luma"
    compileSdk { version = release(36) { minorApiLevel = 1 } }
    defaultConfig {
        applicationId = "com.designxdevelop.luma"
        minSdk = 26
        targetSdk = 36
        // Release rule: versionName stays 1.0; every Play upload needs a higher versionCode.
        versionCode = (findProperty("versionCode") as String? ?: System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "1.0"
    }
    // Play upload key, kept outside the repo (see docs/PLAY.md). Without it, release builds are unsigned.
    val uploadKeystore = System.getenv("LUMA_UPLOAD_KEYSTORE")?.let(::file)?.takeIf { it.exists() }
    signingConfigs {
        if (uploadKeystore != null) create("upload") {
            storeFile = uploadKeystore
            storePassword = System.getenv("LUMA_UPLOAD_PASSWORD")
            keyAlias = System.getenv("LUMA_UPLOAD_ALIAS") ?: "luma-upload"
            keyPassword = System.getenv("LUMA_UPLOAD_PASSWORD")
        }
    }
    buildTypes {
        // ponytail: R8 off; enabling it needs kotlinx-serialization keep rules.
        release {
            isMinifyEnabled = false
            signingConfigs.findByName("upload")?.let { signingConfig = it }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true; buildConfig = true }
    testOptions.unitTests.all {
        // Shared test vectors live with the desktop app so every client replays the same files.
        it.systemProperty("luma.fixtures", rootProject.file("../desktop/src/test/fixtures").absolutePath)
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    val bom = platform("androidx.compose:compose-bom:2025.12.01")
    implementation(bom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}
