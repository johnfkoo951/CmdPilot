using System.Text;
using MacPilot.Windows.Diagnostics;

namespace MacPilot.Windows.Storage;

/// <summary>
/// Persists the deck (shortcut/macro layout) so phones share one deck, mirroring DeckStore.swift.
/// Location: %LOCALAPPDATA%\MacPilot\deck.json. The raw string is read/written verbatim and served
/// UNQUOTED in the getDeck reply, so it MUST be UTF-8 WITHOUT a BOM (a BOM would corrupt the JSON
/// the client parses and break the Korean deck).
/// </summary>
public sealed class DeckStore
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);
    private readonly string _path;
    private readonly object _gate = new();

    public DeckStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "MacPilot", "deck.json");
    }

    /// <summary>Returns the stored deck JSON string, or null if absent/empty.</summary>
    public string? LoadString()
    {
        try
        {
            lock (_gate)
            {
                if (!File.Exists(_path)) return null;
                var s = File.ReadAllText(_path, Utf8NoBom);
                return string.IsNullOrWhiteSpace(s) ? null : s;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"deck load failed: {ex.Message}");
            return null;
        }
    }

    public void Save(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return;
        try
        {
            lock (_gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                File.WriteAllText(_path, json, Utf8NoBom);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"deck save failed: {ex.Message}");
        }
    }
}
