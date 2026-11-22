import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// supabase.properties = the hosted project; supabase.local.properties (git-ignored, optional)
// overrides it, e.g. to point a build at the local stack from backend/.
val supabaseProps = Properties().apply {
    for (name in listOf("supabase.properties", "supabase.local.properties")) {
        val f = rootProject.file(name)
        if (f.exists()) f.inputStream().use { load(it) }
    }
}

android {
    // The Kotlin package / R / BuildConfig keep the old name; only the installed app id changed (0.1.2).
    namespace = "com.mansfera.lynxreminders"
    compileSdk = 36

    defaultConfig {
        applicationId = "xyz.etherlynx.reminders"
        minSdk = 29
        targetSdk = 36
        versionCode = 7
        versionName = "0.3.0"
        buildConfigField("String", "SUPABASE_URL", "\"${supabaseProps.getProperty("supabase.url", "http://10.0.2.2:54321")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${supabaseProps.getProperty("supabase.anonKey", "")}\"")
    }

    buildTypes {
        release {
            // No release key yet: the shrunk build is signed with the debug key, so it installs over the
            // debug-signed APKs released up to 0.2.0 and keeps their data.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        // native-image: GraalVM reflection config from the Anthropic SDK (4 MB), unused on Android.
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/INDEX.LIST", "META-INF/*.kotlin_module", "META-INF/native-image/**")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        optIn.addAll("androidx.compose.material3.ExperimentalMaterial3Api", "androidx.compose.foundation.layout.ExperimentalLayoutApi")
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.work.runtime)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.play.services.location)
    // Passkeys (SPEC §9); the Play Services provider covers Android 9–13.
    implementation(libs.androidx.credentials)
    implementation(libs.androidx.credentials.play.services)
    // Claude (SPEC §7a): the official Anthropic SDK, called with the user's own API key.
    implementation(libs.anthropic.java)
    // On-device quick add (SPEC §7a): Gemini Nano through ML Kit's Prompt API, where AICore has it.
    implementation(libs.genai.prompt)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.supabase.realtime)
    implementation(libs.ktor.client.okhttp)
    // OkHttp 5.4+ requires compileSdk 37; 5.3.2 keeps the app on compileSdk 36 (same 5.x API Ktor uses).
    implementation(libs.okhttp) { version { strictly(libs.versions.okhttp.get()) } }
}

configurations.all {
    resolutionStrategy {
        // Supabase pulls lifecycle 2.11 (compileSdk 37 for the compose artifacts); stay on 2.10.
        force("androidx.lifecycle:lifecycle-runtime-compose:${libs.versions.lifecycle.get()}")
        force("androidx.lifecycle:lifecycle-viewmodel-compose:${libs.versions.lifecycle.get()}")
    }
}
