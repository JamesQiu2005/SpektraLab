// Versions: the latest stable releases at least two weeks old on 2026-11-20.
// AGP 9 compiles Kotlin itself; the Kotlin Android plugin is only declared (not applied) so the Compose
// compiler plugin and AGP's built-in Kotlin use the same Kotlin, 2.4.21.
plugins {
    id("com.android.application") version "9.5.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
}
