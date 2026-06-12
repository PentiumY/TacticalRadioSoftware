using System;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TacticalRadio.Launcher;

public sealed class GitHubUpdateService
{
    private readonly string owner;
    private readonly string repository;
    private readonly string installerAssetPattern;

    public GitHubUpdateService(
        string owner,
        string repository,
        string installerAssetPattern
    )
    {
        this.owner = owner;
        this.repository = repository;
        this.installerAssetPattern = installerAssetPattern;
    }

    public async Task<UpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        var currentVersionText = GetCurrentVersionText();
        var currentVersion = ParseVersion(currentVersionText);

        using var httpClient = new HttpClient();

        httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("TacticalRadioLauncher");
        httpClient.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        httpClient.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");

        var url = $"https://api.github.com/repos/{owner}/{repository}/releases/latest";

        using var response = await httpClient.GetAsync(url, cancellationToken);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(cancellationToken);

        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        var tagName = ReadString(root, "tag_name");
        var releaseName = ReadString(root, "name");
        var releasePageUrl = ReadString(root, "html_url");

        var latestVersionText = NormalizeVersionText(tagName);
        var latestVersion = ParseVersion(latestVersionText);

        string installerDownloadUrl = "";
        string installerAssetName = "";

        if (root.TryGetProperty("assets", out var assets) &&
            assets.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in assets.EnumerateArray())
            {
                var assetName = ReadString(asset, "name");
                var browserDownloadUrl = ReadString(asset, "browser_download_url");

                if (string.IsNullOrWhiteSpace(assetName) ||
                    string.IsNullOrWhiteSpace(browserDownloadUrl))
                {
                    continue;
                }

                if (IsInstallerAsset(assetName))
                {
                    installerAssetName = assetName;
                    installerDownloadUrl = browserDownloadUrl;
                    break;
                }
            }
        }

        var isUpdateAvailable = latestVersion > currentVersion;

        return new UpdateCheckResult
        {
            CurrentVersion = currentVersionText,
            LatestVersion = latestVersionText,
            ReleaseName = string.IsNullOrWhiteSpace(releaseName) ? tagName : releaseName,
            ReleasePageUrl = releasePageUrl,
            InstallerDownloadUrl = installerDownloadUrl,
            InstallerAssetName = installerAssetName,
            IsUpdateAvailable = isUpdateAvailable
        };
    }

    private bool IsInstallerAsset(string assetName)
    {
        if (Regex.IsMatch(assetName, installerAssetPattern, RegexOptions.IgnoreCase))
        {
            return true;
        }

        return assetName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) &&
               assetName.Contains("TacticalRadioSetup", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetCurrentVersionText()
    {
        var assembly = Assembly.GetExecutingAssembly();

        var informationalVersion = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        if (!string.IsNullOrWhiteSpace(informationalVersion))
        {
            return NormalizeVersionText(informationalVersion);
        }

        var assemblyVersion = assembly.GetName().Version;

        if (assemblyVersion is not null)
        {
            return $"{assemblyVersion.Major}.{assemblyVersion.Minor}.{assemblyVersion.Build}";
        }

        return "0.0.0";
    }

    private static string NormalizeVersionText(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "0.0.0";
        }

        value = value.Trim();

        if (value.StartsWith("v", StringComparison.OrdinalIgnoreCase))
        {
            value = value[1..];
        }

        var plusIndex = value.IndexOf('+');

        if (plusIndex >= 0)
        {
            value = value[..plusIndex];
        }

        var dashIndex = value.IndexOf('-');

        if (dashIndex >= 0)
        {
            value = value[..dashIndex];
        }

        return value.Trim();
    }

    private static Version ParseVersion(string value)
    {
        value = NormalizeVersionText(value);

        var parts = value
            .Split('.', StringSplitOptions.RemoveEmptyEntries)
            .Select(part =>
            {
                var digits = new string(part.TakeWhile(char.IsDigit).ToArray());
                return int.TryParse(digits, out var parsed) ? parsed : 0;
            })
            .ToList();

        while (parts.Count < 4)
        {
            parts.Add(0);
        }

        return new Version(parts[0], parts[1], parts[2], parts[3]);
    }

    private static string ReadString(JsonElement root, string propertyName)
    {
        if (root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty(propertyName, out var property) &&
            property.ValueKind == JsonValueKind.String)
        {
            return property.GetString() ?? "";
        }

        return "";
    }
}

public sealed class UpdateCheckResult
{
    public string CurrentVersion { get; init; } = "0.0.0";
    public string LatestVersion { get; init; } = "0.0.0";
    public string ReleaseName { get; init; } = "";
    public string ReleasePageUrl { get; init; } = "";
    public string InstallerDownloadUrl { get; init; } = "";
    public string InstallerAssetName { get; init; } = "";
    public bool IsUpdateAvailable { get; init; }

    public string BestUpdateUrl
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(InstallerDownloadUrl))
            {
                return InstallerDownloadUrl;
            }

            return ReleasePageUrl;
        }
    }
}