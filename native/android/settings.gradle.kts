val coreOnly = System.getenv("SMARTMENUKJ_CORE_ONLY") != null

pluginManagement {
    repositories {
        if (System.getenv("SMARTMENUKJ_CORE_ONLY") == null) google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.android.application") version "8.7.3"
    }
}

dependencyResolutionManagement {
    repositories {
        // repo1 is the same Maven Central, for machines where the main address limits how often it may be asked.
        if (coreOnly) maven("https://repo1.maven.org/maven2") else google()
        mavenCentral()
    }
}

rootProject.name = "SmartMenuKJ"

// core is plain Kotlin (models, device drivers, the home store) and builds anywhere. The Android app needs the
// Android SDK; set SMARTMENUKJ_CORE_ONLY=1 to build and test only core on a machine without it.
include(":core")
if (!coreOnly) include(":app")
