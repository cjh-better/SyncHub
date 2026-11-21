import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "xyz.synchub.android"
    compileSdk = 36 // pinned: AGP 8.11 cannot resolve android-37.0
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "xyz.synchub.android"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("keystore.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }
    fun signingProp(name: String, env: String): String? {
        val fromFile = keystoreProperties.getProperty(name)?.trim().orEmpty()
        if (fromFile.isNotEmpty()) return fromFile
        val fromEnv = System.getenv(env)?.trim().orEmpty()
        return fromEnv.ifEmpty { null }
    }

    signingConfigs {
        create("release") {
            val store = signingProp("storeFile", "SYNCHUB_KEYSTORE_FILE")
            val storePw = signingProp("storePassword", "SYNCHUB_KEYSTORE_PASSWORD")
            val alias = signingProp("keyAlias", "SYNCHUB_KEY_ALIAS")
            val keyPw = signingProp("keyPassword", "SYNCHUB_KEY_PASSWORD")
            if (store != null && storePw != null && alias != null && keyPw != null) {
                storeFile = rootProject.file(store)
                storePassword = storePw
                keyAlias = alias
                keyPassword = keyPw
            }
        }
    }

    buildTypes {
        release {
            val releaseSigning = signingConfigs.getByName("release")
            if (releaseSigning.storeFile != null) {
                signingConfig = releaseSigning
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    buildFeatures {
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/java", "src/main/kotlin")
        }
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/*.kotlin_module",
            "META-INF/AL2.0",
            "META-INF/LGPL2.1"
        )
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
        disable += setOf("ProtectedPermissions", "QueryAllPackagesPermission")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    compileOnly("de.robv.android.xposed:api:82")
}

flutter {
    source = "../.."
}
