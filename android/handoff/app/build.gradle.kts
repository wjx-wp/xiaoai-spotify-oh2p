plugins {
    id("com.android.application")
}

val releaseSigningEnvironment = linkedMapOf(
    "XIAOAI_ANDROID_KEYSTORE" to System.getenv("XIAOAI_ANDROID_KEYSTORE"),
    "XIAOAI_ANDROID_KEY_ALIAS" to System.getenv("XIAOAI_ANDROID_KEY_ALIAS"),
    "XIAOAI_ANDROID_STORE_PASSWORD" to System.getenv("XIAOAI_ANDROID_STORE_PASSWORD"),
    "XIAOAI_ANDROID_KEY_PASSWORD" to System.getenv("XIAOAI_ANDROID_KEY_PASSWORD"),
)

val publicRuntimeEnvironment = linkedMapOf(
    "XIAOAI_SPOTIFY_CLIENT_ID" to System.getenv("XIAOAI_SPOTIFY_CLIENT_ID"),
    "XIAOAI_SPEAKER_HOST_KEY_SHA256" to System.getenv("XIAOAI_SPEAKER_HOST_KEY_SHA256"),
)

fun javaStringLiteral(value: String): String = "\"" +
    value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val spotifyClientId = publicRuntimeEnvironment["XIAOAI_SPOTIFY_CLIENT_ID"].orEmpty()
val speakerHostKeySha256 = publicRuntimeEnvironment["XIAOAI_SPEAKER_HOST_KEY_SHA256"].orEmpty()

if (spotifyClientId.isNotEmpty() && !spotifyClientId.matches(Regex("^[A-Za-z0-9]{16,64}$"))) {
    throw GradleException("XIAOAI_SPOTIFY_CLIENT_ID has an invalid format")
}
if (speakerHostKeySha256.isNotEmpty()
    && !speakerHostKeySha256.matches(Regex("^SHA256:[A-Za-z0-9+/]{43}$"))) {
    throw GradleException("XIAOAI_SPEAKER_HOST_KEY_SHA256 has an invalid format")
}

val releasePackagingTaskPaths = setOf(
    "${project.path}:assembleRelease",
    "${project.path}:bundleRelease",
    "${project.path}:packageRelease",
    "${project.path}:installRelease",
)

gradle.taskGraph.whenReady {
    if (releasePackagingTaskPaths.any(::hasTask)) {
        val missingSigning = releaseSigningEnvironment
            .filterValues { it.isNullOrBlank() }
            .keys
        val missingRuntime = publicRuntimeEnvironment
            .filterValues { it.isNullOrBlank() }
            .keys
        val missing = missingSigning + missingRuntime
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Release packaging requires environment variables: " +
                    missing.joinToString(", "),
            )
        }
    }
}

android {
    namespace = "io.xiaoaimusic.handoff"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.xiaoaimusic.handoff"
        minSdk = 28
        targetSdk = 36
        versionCode = 7
        versionName = "1.0.0"

        buildConfigField("String", "SPOTIFY_CLIENT_ID", javaStringLiteral(spotifyClientId))
        buildConfigField(
            "String",
            "SPEAKER_HOST_KEY_SHA256",
            javaStringLiteral(speakerHostKeySha256),
        )

        testInstrumentationRunner = "android.app.Instrumentation"
    }

    val releaseStore = releaseSigningEnvironment["XIAOAI_ANDROID_KEYSTORE"]
    val releaseAlias = releaseSigningEnvironment["XIAOAI_ANDROID_KEY_ALIAS"]
    val releaseStorePassword = releaseSigningEnvironment["XIAOAI_ANDROID_STORE_PASSWORD"]
    val releaseKeyPassword = releaseSigningEnvironment["XIAOAI_ANDROID_KEY_PASSWORD"]

    signingConfigs {
        if (!releaseStore.isNullOrBlank() && !releaseAlias.isNullOrBlank()
            && !releaseStorePassword.isNullOrBlank() && !releaseKeyPassword.isNullOrBlank()) {
            create("releaseFromEnvironment") {
                storeFile = file(releaseStore)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (signingConfigs.names.contains("releaseFromEnvironment")) {
                signingConfig = signingConfigs.getByName("releaseFromEnvironment")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
    }
}

dependencies {
    implementation("com.github.mwiede:jsch:2.28.4")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}
