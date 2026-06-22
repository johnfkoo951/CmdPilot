using System.Diagnostics;

namespace MacPilot.Windows.Apps;

/// <summary>
/// Launches an app / file / .lnk / URL / custom scheme. Unlike the macOS launch() which branches on
/// a leading "/", Windows uses ShellExecute semantics uniformly: Process.Start with UseShellExecute
/// resolves file paths, Start-Menu .lnk shortcuts, http(s) URLs, and custom schemes the same way.
/// A bad target must never crash the server, so everything is wrapped in try/catch.
/// </summary>
public static class AppLauncher
{
    public static void Launch(string? target)
    {
        if (string.IsNullOrWhiteSpace(target)) return;
        try
        {
            using var _ = Process.Start(new ProcessStartInfo
            {
                FileName = target,
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Diagnostics.Log.Warn($"launch failed for '{target}': {ex.Message}");
        }
    }
}
