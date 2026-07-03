using System.Net;
using MacPilot.Windows.Server;

namespace MacPilot.Windows.Config;

/// <summary>
/// Runtime settings. Port defaults to 8765 (same as macOS) and is overridable. Binds to all
/// interfaces by default so phones on the LAN can connect (the whole point); a localhost-only mode
/// is available for users who only want loopback. No TLS for MVP — LAN/localhost only.
///
/// Resolution order: CLI args (--port N, --localhost) → env vars (MACPILOT_PORT, MACPILOT_LOCALHOST)
/// → defaults.
/// </summary>
public sealed class AppSettings
{
    public int Port { get; private set; } = 8765;
    public bool LocalhostOnly { get; private set; }

    /// <summary>Optional PIN pairing (Phase 2). Off by default — fully backward compatible.</summary>
    public bool PairingEnabled { get; private set; }
    public string Pin { get; private set; } = "";

    public IPAddress BindAddress => LocalhostOnly ? IPAddress.Loopback : IPAddress.Any;

    public static AppSettings Load(string[] args)
    {
        var s = new AppSettings();

        // env first, args override
        if (int.TryParse(Environment.GetEnvironmentVariable("MACPILOT_PORT"), out var envPort) && IsValidPort(envPort))
            s.Port = envPort;
        if (string.Equals(Environment.GetEnvironmentVariable("MACPILOT_LOCALHOST"), "1", StringComparison.Ordinal))
            s.LocalhostOnly = true;

        var envPin = Environment.GetEnvironmentVariable("MACPILOT_PIN");
        if (!string.IsNullOrWhiteSpace(envPin)) { s.PairingEnabled = true; s.Pin = envPin.Trim(); }

        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port" or "-p" when i + 1 < args.Length && int.TryParse(args[i + 1], out var p) && IsValidPort(p):
                    s.Port = p; i++; break;
                case "--localhost":
                    s.LocalhostOnly = true; break;
                case "--pin":
                    // "--pin 123456" sets a fixed PIN; bare "--pin" auto-generates one.
                    s.PairingEnabled = true;
                    if (i + 1 < args.Length && IsAllDigits(args[i + 1])) { s.Pin = args[i + 1]; i++; }
                    else if (string.IsNullOrEmpty(s.Pin)) { s.Pin = PairingAuth.GeneratePin(); }
                    break;
            }
        }

        return s;
    }

    private static bool IsValidPort(int p) => p is > 0 and < 65536;
    private static bool IsAllDigits(string v) => v.Length is > 0 and <= 12 && v.All(char.IsDigit);
}
