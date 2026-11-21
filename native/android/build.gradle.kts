// The Android plugin sits on the same classpath as the Kotlin plugin, which needs to see it. It is left out when only
// core is built (SMARTMENUKJ_CORE_ONLY), so core builds on machines without Google's Maven.
buildscript {
    if (System.getenv("SMARTMENUKJ_CORE_ONLY") == null) {
        repositories {
            google()
            mavenCentral()
        }
        dependencies {
            classpath("com.android.tools.build:gradle:8.7.3")
        }
    }
}

plugins {
    kotlin("jvm") version "2.1.0" apply false
    kotlin("android") version "2.1.0" apply false
    kotlin("plugin.serialization") version "2.1.0" apply false
    kotlin("plugin.compose") version "2.1.0" apply false
}
