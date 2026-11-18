plugins {
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.android") apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    pluginManager.withPlugin("com.android.library") {
        extensions.getByType<com.android.build.api.variant.LibraryAndroidComponentsExtension>()
            .finalizeDsl { library ->
                if (library.compileSdkPreview == null && (library.compileSdk ?: 0) < 36) {
                    library.compileSdk = 36
                }
            }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 10.2.4 compiles Java for JVM 11 and leaves Kotlin at JVM 1.8.
project(":file_picker") {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
