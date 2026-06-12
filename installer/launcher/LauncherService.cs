using System.Diagnostics;
using System.Text.Json;

namespace TacticalRadio.Launcher;

public sealed class LauncherService
{
    private static readonly string[] OldPluginNames =
    {
        "tactical_radio_mumble_plugin.dll",
        "tactical-radio-bridge_mumble_plugin.dll",
        "tactical-radio-bridge.mumble_plugin.dll"
    };

    private readonly JsonSerializerOptions jsonOptions = new()
    {
        WriteIndented = true
    };

    public LauncherService(string appDir)
    {
        AppDir = appDir;
        ConfigPath = Path.Combine(AppDir, "config.json");
        PluginSourceDir = Path.Combine(AppDir, "plugin");
        BinDir = Path.Combine(AppDir, "bin");
        PluginDestDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Mumble",
            "Mumble",
            "Plugins"
        );
    }

    public string AppDir { get; }

    public string ConfigPath { get; }

    public string PluginSourceDir { get; }

    public string PluginDestDir { get; }

    public string BinDir { get; }

    public LauncherConfig LoadConfig()
    {
        var config = new LauncherConfig
        {
            BaseUrl = string.Empty,
            PlaceId = "16489784096",
            JobId = "studio-local",
            MumblePath = GetDefaultMumblePath()
        };

        if (!File.Exists(ConfigPath))
        {
            return config;
        }

        try
        {
            var json = File.ReadAllText(ConfigPath);
            var loaded = JsonSerializer.Deserialize<LauncherConfig>(json, jsonOptions);
            if (loaded is null)
            {
                return config;
            }

            if (loaded.BaseUrl is not null)
            {
                config.BaseUrl = loaded.BaseUrl;
            }

            if (!string.IsNullOrWhiteSpace(loaded.PlaceId))
            {
                config.PlaceId = loaded.PlaceId;
            }

            if (!string.IsNullOrWhiteSpace(loaded.JobId))
            {
                config.JobId = loaded.JobId;
            }

            if (!string.IsNullOrWhiteSpace(loaded.MumblePath))
            {
                config.MumblePath = loaded.MumblePath;
            }
        }
        catch
        {
            // Match the PowerShell launcher behavior: bad config should not prevent startup.
        }

        return config;
    }

    public void SaveConfig(LauncherConfig config)
    {
        NormalizeAndValidateConfig(config);

        Directory.CreateDirectory(AppDir);
        var json = JsonSerializer.Serialize(config, jsonOptions);
        File.WriteAllText(ConfigPath, json);
    }

    public void InstallPlugin()
    {
        Directory.CreateDirectory(PluginDestDir);

        if (!Directory.Exists(PluginSourceDir))
        {
            throw new DirectoryNotFoundException($"No plugin folder was found at: {PluginSourceDir}");
        }

        var plugins = Directory
            .EnumerateFiles(PluginSourceDir, "*.dll", SearchOption.TopDirectoryOnly)
            .ToList();

        if (plugins.Count == 0)
        {
            throw new FileNotFoundException($"No plugin DLL was found in: {PluginSourceDir}");
        }

        foreach (var oldName in OldPluginNames)
        {
            var oldPath = Path.Combine(PluginDestDir, oldName);
            TryDeleteFile(oldPath);
        }

        foreach (var pluginPath in plugins)
        {
            var destPath = Path.Combine(PluginDestDir, Path.GetFileName(pluginPath));
            File.Copy(pluginPath, destPath, overwrite: true);
            UnblockFile(destPath);
        }

        UnblockDirectory(AppDir);
    }

    public void LaunchMumble(LauncherConfig config)
    {
        SaveConfig(config);
        InstallPlugin();

        var mumblePath = config.MumblePath.Trim();
        if (!File.Exists(mumblePath))
        {
            throw new FileNotFoundException($"Mumble was not found at: {mumblePath}");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = mumblePath,
            WorkingDirectory = Path.GetDirectoryName(mumblePath) ?? Environment.CurrentDirectory,
            UseShellExecute = false
        };

        if (Directory.Exists(BinDir))
        {
            var currentPath = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            startInfo.Environment["PATH"] = $"{BinDir};{currentPath}";
        }

        startInfo.Environment["TRADIO_BASE_URL"] = config.BaseUrl.Trim();
        startInfo.Environment["TRADIO_PLACE_ID"] = config.PlaceId.Trim();
        startInfo.Environment["TRADIO_JOB_ID"] = config.JobId.Trim();

        var process = Process.Start(startInfo);
        if (process is null)
        {
            throw new InvalidOperationException("Mumble could not be started.");
        }
    }

    public static string GetDefaultMumblePath()
    {
        var candidates = new List<string>();

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrWhiteSpace(programFiles))
        {
            candidates.Add(Path.Combine(programFiles, "Mumble", "Client", "mumble.exe"));
        }

        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        if (!string.IsNullOrWhiteSpace(programFilesX86))
        {
            candidates.Add(Path.Combine(programFilesX86, "Mumble", "Client", "mumble.exe"));
        }

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return @"C:\Program Files\Mumble\Client\mumble.exe";
    }

    private static void NormalizeAndValidateConfig(LauncherConfig config)
    {
        config.BaseUrl = config.BaseUrl.Trim();
        config.PlaceId = config.PlaceId.Trim();
        config.JobId = config.JobId.Trim();
        config.MumblePath = config.MumblePath.Trim();

        if (!string.IsNullOrWhiteSpace(config.BaseUrl) &&
            !config.BaseUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !config.BaseUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Base URL must start with http:// or https://, or be left empty.");
        }
    }

    private static void UnblockDirectory(string directory)
    {
        if (!Directory.Exists(directory))
        {
            return;
        }

        try
        {
            foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
            {
                UnblockFile(file);
            }
        }
        catch
        {
            // Best effort only, same as PowerShell's -ErrorAction SilentlyContinue.
        }
    }

    private static void UnblockFile(string filePath)
    {
        try
        {
            if (File.Exists(filePath))
            {
                File.Delete(filePath + ":Zone.Identifier");
            }
        }
        catch
        {
            // Best effort only. The file copy/launch should continue if ADS removal fails.
        }
    }

    private static void TryDeleteFile(string filePath)
    {
        try
        {
            if (File.Exists(filePath))
            {
                File.Delete(filePath);
            }
        }
        catch
        {
            // Match Remove-Item -ErrorAction SilentlyContinue for old plugin cleanup.
        }
    }
}
