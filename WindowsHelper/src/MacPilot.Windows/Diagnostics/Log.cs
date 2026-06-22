namespace MacPilot.Windows.Diagnostics;

/// <summary>
/// Minimal thread-safe file logger. Because the app is a WinExe (no console), startup/bind errors
/// and injection warnings go here: %LOCALAPPDATA%\MacPilot\helper.log. Never throws.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private static readonly string LogPath = BuildPath();

    private static string BuildPath()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "MacPilot");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "helper.log");
        }
        catch
        {
            return Path.Combine(Path.GetTempPath(), "macpilot-helper.log");
        }
    }

    public static string Path_ => LogPath;

    public static void Info(string msg) => Write("INFO", msg);
    public static void Warn(string msg) => Write("WARN", msg);
    public static void Error(string msg) => Write("ERROR", msg);

    private static void Write(string level, string msg)
    {
        try
        {
            var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{level}] {msg}{Environment.NewLine}";
            lock (Gate) File.AppendAllText(LogPath, line);
        }
        catch
        {
            // logging must never throw
        }
    }
}
