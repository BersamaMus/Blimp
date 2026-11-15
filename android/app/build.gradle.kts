import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Blimp's release key, described in android/key.properties (kept out of
// version control, as is the key it points to). Every APK on the GitHub
// releases and every upload to Google Play must be signed with it, or Android
// won't let it update the Blimp already installed. So a release build without
// a usable key.properties stops with an error rather than quietly signing
// with the debug key. To try out a release build anyway, set
// BLIMP_DEBUG_SIGNED_RELEASE=1.
val keystoreProperties = Properties()
val releaseKeyProblem: String? = run {
    val file = rootProject.file("key.properties")
    if (!file.exists()) return@run "android/key.properties is missing."
    file.inputStream().use { keystoreProperties.load(it) }
    val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) return@run "android/key.properties has no ${missing.joinToString()}."
    val store = project.file(keystoreProperties.getProperty("storeFile"))
    if (!store.exists()) return@run "The key in android/key.properties isn't there: $store"
    null
}
val debugSignedReleaseAllowed = System.getenv("BLIMP_DEBUG_SIGNED_RELEASE") == "1"

android {
    namespace = "com.blimp.app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent once published on Google Play.
        applicationId = "com.blimp.app"
        // Android 7, as the README promises. Pinned rather than following
        // Flutter's default, which can rise with a Flutter upgrade.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // From the version in pubspec.yaml: name+code, e.g. 1.0.0+1.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (releaseKeyProblem == null) {
            create("upload") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// Debug builds never need the release key; only stop a release build that
// would otherwise be signed with the debug key.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { it.project == project && it.name.endsWith("Release") }
    if (buildsRelease && releaseKeyProblem != null && !debugSignedReleaseAllowed) {
        throw GradleException(
            "Can't sign a release build with Blimp's key: $releaseKeyProblem " +
                "Set BLIMP_DEBUG_SIGNED_RELEASE=1 to sign it with the debug key instead (never publish that build)."
        )
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
    // JVM tests for the Kotlin code that doesn't need a device (EmbeddedLyrics).
    testImplementation("junit:junit:4.13.2")
    // A device test that browses the library as Android Auto does (CarBrowsingTest).
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.media:media:1.7.0")
}
