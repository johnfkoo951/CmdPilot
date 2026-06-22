using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.Versioning;
using System.Text.Json;
using MacPilot.Windows.Diagnostics;

namespace MacPilot.Windows.Apps;

/// <summary>
/// Enumerates installed apps from the Start Menu (.lnk shortcuts) and returns a JSON array of
/// {name, path, icon} — the SAME shape AppList.swift returns, so the web app picker is reused
/// unchanged. <c>path</c> is the .lnk path (ShellExecute resolves it); <c>icon</c> is an optional
/// 36px PNG data URI. Built once and cached (icon extraction over hundreds of apps is slow).
///
/// Scope notes (documented as partial): UWP/Store apps live under shell:AppsFolder, not as .lnk
/// files, and are NOT enumerated here — a follow-up item.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class AppListProvider
{
    private readonly object _gate = new();
    private string? _cachedJson;

    public string GetJson()
    {
        lock (_gate)
        {
            if (_cachedJson is not null) return _cachedJson;
            _cachedJson = Build();
            return _cachedJson;
        }
    }

    private static string Build()
    {
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
        };

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var apps = new List<Dictionary<string, string>>();

        foreach (var root in roots)
        {
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) continue;
            IEnumerable<string> links;
            try { links = Directory.EnumerateFiles(root, "*.lnk", SearchOption.AllDirectories); }
            catch (Exception ex) { Log.Warn($"start-menu scan failed for {root}: {ex.Message}"); continue; }

            foreach (var lnk in links)
            {
                var name = Path.GetFileNameWithoutExtension(lnk);
                if (string.IsNullOrWhiteSpace(name) || !seen.Add(name)) continue;
                apps.Add(new Dictionary<string, string>
                {
                    ["name"] = name,
                    ["path"] = lnk,
                    ["icon"] = TryIconDataUri(lnk) ?? "",
                });
            }
        }

        apps.Sort((a, b) => string.Compare(a["name"], b["name"], StringComparison.OrdinalIgnoreCase));

        try { return JsonSerializer.Serialize(apps); }
        catch { return "[]"; }
    }

    /// <summary>Extract the associated icon, scale to 36px, encode as a base64 PNG data URI.</summary>
    private static string? TryIconDataUri(string path)
    {
        try
        {
            using var raw = Icon.ExtractAssociatedIcon(path);
            if (raw is null) return null;
            using var src = raw.ToBitmap();
            using var bmp = new Bitmap(36, 36);
            using (var g = Graphics.FromImage(bmp))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(src, 0, 0, 36, 36);
            }
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Png);
            return "data:image/png;base64," + Convert.ToBase64String(ms.ToArray());
        }
        catch
        {
            return null; // icon is optional
        }
    }
}
