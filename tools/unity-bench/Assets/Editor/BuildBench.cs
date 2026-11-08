// Builds the UiBench player (tools/unity-bench/run.py calls it):
//   Unity.exe -batchmode -quit -projectPath tools/unity-bench
//     -executeMethod BuildBench.Build -buildOut <dir>/UnityBench.exe -backend il2cpp|mono
// Windows x64 standalone, release (not a development build), windowed
// 1280x800, runs in the background, no splash screen. IL2CPP: compiler
// configuration Release, code generation for speed.

using System;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class BuildBench
{
    static string Arg(string name, string def)
    {
        var a = Environment.GetCommandLineArgs();
        for (int i = 0; i < a.Length - 1; i++) if (a[i] == name) return a[i + 1];
        return def;
    }

    public static void Build()
    {
        string outPath = Arg("-buildOut", "Builds/il2cpp/UnityBench.exe");
        bool il2cpp = Arg("-backend", "il2cpp") == "il2cpp";

        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var cam = new GameObject("Camera").AddComponent<Camera>();
        cam.clearFlags = CameraClearFlags.SolidColor;
        cam.backgroundColor = Color.black;
        EditorSceneManager.SaveScene(scene, "Assets/Bench.unity");

        var target = NamedBuildTarget.Standalone;
        PlayerSettings.SetScriptingBackend(target, il2cpp ? ScriptingImplementation.IL2CPP : ScriptingImplementation.Mono2x);
        PlayerSettings.SetIl2CppCompilerConfiguration(target, Il2CppCompilerConfiguration.Release);
        PlayerSettings.SetIl2CppCodeGeneration(target, Il2CppCodeGeneration.OptimizeSpeed);
        PlayerSettings.SetManagedStrippingLevel(target, ManagedStrippingLevel.Minimal);
        PlayerSettings.fullScreenMode = FullScreenMode.Windowed;
        PlayerSettings.defaultScreenWidth = 1280;
        PlayerSettings.defaultScreenHeight = 800;
        PlayerSettings.resizableWindow = false;
        PlayerSettings.runInBackground = true;
        PlayerSettings.visibleInBackground = true;
        PlayerSettings.usePlayerLog = true;
        PlayerSettings.SplashScreen.show = false;
        PlayerSettings.productName = "UnityBench";

        var opts = new BuildPlayerOptions
        {
            scenes = new[] { "Assets/Bench.unity" },
            locationPathName = outPath,
            target = BuildTarget.StandaloneWindows64,
            options = BuildOptions.None,
        };
        var report = BuildPipeline.BuildPlayer(opts);
        Debug.Log("[unity-bench] build " + report.summary.result + " -> " + outPath);
        if (report.summary.result != BuildResult.Succeeded) EditorApplication.Exit(1);
    }
}
