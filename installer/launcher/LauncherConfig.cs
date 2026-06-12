using System.Text.Json.Serialization;

namespace TacticalRadio.Launcher;

public sealed class LauncherConfig
{
    [JsonPropertyName("baseUrl")]
    public string BaseUrl { get; set; } = string.Empty;

    [JsonPropertyName("placeId")]
    public string PlaceId { get; set; } = "16489784096";

    [JsonPropertyName("jobId")]
    public string JobId { get; set; } = "studio-local";

    [JsonPropertyName("mumblePath")]
    public string MumblePath { get; set; } = LauncherService.GetDefaultMumblePath();
}
