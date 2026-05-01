// Canary Android app module (ticket 0104).
//
// Responsibilities:
//   1. Invoke `zig build --release=small` for the aarch64-linux-android
//      target, producing `libsmithers_core.so`.
//   2. Stage that .so under `src/main/jniLibs/arm64-v8a/` so the Android
//      Gradle Plugin packs it into the APK.
//   3. Build a tiny single-Activity APK that exercises the FFI via JNI.
//
// What's intentionally absent:
//   - Jetpack Compose. Views + a classic Activity keep the build graph
//     small (no Compose compiler, no Kotlin metadata bloat) and the
//     canary stays focused on the Zig↔JNI boundary.
//   - Release signing config. The canary's purpose is `assembleDebug`
//     in CI; signing comes with a real Android release (out of scope).

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.smithers.androidcore"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.smithers.androidcore"
        // API 29 matches the `android_api` constant in ../build.zig. Both
        // sides MUST move together — the NDK sysroot is level-gated.
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "0.0.1-canary"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            // Canary: no ProGuard/R8. The .so is what we care about.
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("build/generated/zig-jniLibs")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
}

// ---------------------------------------------------------------------------
// Zig integration.
//
// The Zig build is invoked as an external process, NOT via a Gradle-native
// toolchain. This keeps the logic identical to what a developer runs on
// the CLI and avoids reinventing Android ABI mapping inside Gradle.
// ---------------------------------------------------------------------------

val zigProjectDir: File = projectDir.parentFile
val zigOutDir: File = File(zigProjectDir, "zig-out/lib")
val zigSoName = "libsmithers_core.so"
val stagedJniLibsDir: File = File(buildDir, "generated/zig-jniLibs/arm64-v8a")

val buildZigNative by tasks.registering(Exec::class) {
    group = "build"
    description = "Build libsmithers_core.so for aarch64-linux-android via Zig."
    workingDir = zigProjectDir
    // --release=small -> smaller .so; matches the size figure in README.
    commandLine("zig", "build", "--release=small")

    // Propagate NDK location. The Zig build script reads these.
    val env = environment
    val ndkHome = System.getenv("ANDROID_NDK_ROOT")
        ?: System.getenv("ANDROID_NDK_HOME")
        ?: android.ndkDirectory.absolutePath
    env["ANDROID_NDK_ROOT"] = ndkHome

    inputs.dir(File(zigProjectDir, "src"))
    inputs.file(File(zigProjectDir, "build.zig"))
    inputs.file(File(zigProjectDir, "build.zig.zon"))
    // ffi_poc.zig lives outside this module; track it so edits re-trigger.
    inputs.file(File(zigProjectDir.parentFile, "zig-swift-ffi/src/ffi_poc.zig"))
    outputs.file(File(zigOutDir, zigSoName))
}

val stageZigSo by tasks.registering(Copy::class) {
    group = "build"
    description = "Copy libsmithers_core.so into the AGP jniLibs staging dir."
    dependsOn(buildZigNative)
    from(zigOutDir) {
        include(zigSoName)
    }
    into(stagedJniLibsDir)
}

// Wire the staging task into every variant's pre-build. AGP's task name
// for packaging jniLibs depends on variant, but `preBuild` runs before
// all of them.
tasks.named("preBuild").configure {
    dependsOn(stageZigSo)
}
