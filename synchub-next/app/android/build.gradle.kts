allprojects {
    repositories {
        google()
        mavenCentral()
        maven("https://api.xposed.info/") {
            content { includeGroup("de.robv.android.xposed") }
        }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Plugin modules default to flutter.compileSdkVersion (37), which AGP 8.11 cannot resolve.
subprojects {
    val pin: Project.() -> Unit = {
        extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.compileSdkVersion(36)
    }
    // :app is already evaluated here (it pins compileSdk itself); our hook is
    // registered before AGP's own afterEvaluate in plugin modules, so it wins.
    if (!state.executed) afterEvaluate { pin() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
