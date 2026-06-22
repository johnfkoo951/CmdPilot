using System.Reflection;

namespace MacPilot.Windows.Server;

/// <summary>A resolved static asset ready to write as an HTTP body.</summary>
public readonly record struct StaticAsset(byte[] Bytes, string ContentType);

/// <summary>
/// Serves the reused web client (MacHelper/Web) from embedded resources. The path→asset map mirrors
/// the macOS HTTPWebSocketConnection.serveStatic switch EXACTLY, including the favicon/apple-touch
/// aliases to logo.png. Only an explicit allowlist of paths resolves, so path traversal is impossible.
/// </summary>
public static class StaticAssets
{
    private static readonly Assembly Asm = typeof(StaticAssets).Assembly;

    // path (query-stripped) → (embedded resource logical name, content type)
    private static readonly Dictionary<string, (string Resource, string ContentType)> Map = new(StringComparer.Ordinal)
    {
        ["/"] = ("web/index.html", "text/html; charset=utf-8"),
        ["/index.html"] = ("web/index.html", "text/html; charset=utf-8"),
        ["/app.js"] = ("web/app.js", "application/javascript; charset=utf-8"),
        ["/style.css"] = ("web/style.css", "text/css; charset=utf-8"),
        ["/logo.png"] = ("web/logo.png", "image/png"),
        ["/favicon.ico"] = ("web/logo.png", "image/png"),
        ["/apple-touch-icon.png"] = ("web/logo.png", "image/png"),
        ["/apple-touch-icon-precomposed.png"] = ("web/logo.png", "image/png"),
        ["/logo-mark.png"] = ("web/logo-mark.png", "image/png"),
        ["/logo-mark-dark.png"] = ("web/logo-mark-dark.png", "image/png"),
    };

    /// <summary>Resolve a request path to an asset, or null for 404. Query string is ignored.</summary>
    public static StaticAsset? Resolve(string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        var clean = path.Split('?', 2)[0];
        if (!Map.TryGetValue(clean, out var entry)) return null;

        var bytes = Read(entry.Resource);
        return bytes is null ? null : new StaticAsset(bytes, entry.ContentType);
    }

    private static byte[]? Read(string resource)
    {
        using var s = Asm.GetManifestResourceStream(resource);
        if (s is null) return null;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }
}
