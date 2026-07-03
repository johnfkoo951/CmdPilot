using System.Text.Json;
using System.Text.Json.Serialization;

namespace MacPilot.Windows.Commands;

/// <summary>
/// The flat JSON command the browser client sends over the WebSocket. Mirrors the macOS
/// InboundCommand.swift one-for-one so the existing web client (MacHelper/Web/app.js) is
/// reused UNCHANGED. Every command type carries the union of all optional fields; semantics
/// depend on <see cref="T"/>.
/// </summary>
public sealed class InboundCommand
{
    [JsonPropertyName("t")] public string? T { get; set; }
    [JsonPropertyName("dx")] public double? Dx { get; set; }
    [JsonPropertyName("dy")] public double? Dy { get; set; }
    [JsonPropertyName("button")] public string? Button { get; set; }
    [JsonPropertyName("count")] public int? Count { get; set; }
    [JsonPropertyName("keyCode")] public int? KeyCode { get; set; }   // macOS virtual key code
    [JsonPropertyName("mods")] public string[]? Mods { get; set; }    // command/control/shift/option
    [JsonPropertyName("name")] public string? Name { get; set; }      // hello (unused, parity only)
    [JsonPropertyName("target")] public string? Target { get; set; }  // launch
    [JsonPropertyName("dir")] public string? Dir { get; set; }        // gesture/zoom/volume/brightness
    [JsonPropertyName("text")] public string? Text { get; set; }      // text (Korean/emoji)
    [JsonPropertyName("steps")] public MacroStep[]? Steps { get; set; } // macro
    [JsonPropertyName("deckJson")] public string? DeckJson { get; set; } // saveDeck

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    /// <summary>Parse one WebSocket text frame. Returns null on malformed JSON (safe to ignore).</summary>
    public static InboundCommand? TryParse(string json)
    {
        try
        {
            var cmd = JsonSerializer.Deserialize<InboundCommand>(json, Options);
            return cmd is { T: not null } ? cmd : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>One macro step. The active fields depend on <see cref="Type"/> (key/text/launch/delay).</summary>
public sealed class MacroStep
{
    [JsonPropertyName("type")] public string? Type { get; set; }
    [JsonPropertyName("keyCode")] public int? KeyCode { get; set; }
    [JsonPropertyName("mods")] public string[]? Mods { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("target")] public string? Target { get; set; }
    [JsonPropertyName("ms")] public int? Ms { get; set; }
}
