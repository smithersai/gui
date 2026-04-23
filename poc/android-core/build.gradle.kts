// Root Gradle build file — intentionally empty of plugins; :app carries the
// Android Gradle Plugin. Keeps the root thin.

plugins {
    // Plugin versions declared here so subprojects can `apply` them.
    id("com.android.application") version "8.4.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.23" apply false
}
