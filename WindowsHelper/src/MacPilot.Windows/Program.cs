using System.Runtime.Versioning;
using MacPilot.Windows.Apps;
using MacPilot.Windows.Commands;
using MacPilot.Windows.Config;
using MacPilot.Windows.Diagnostics;
using MacPilot.Windows.Input;
using MacPilot.Windows.Net;
using MacPilot.Windows.Server;
using MacPilot.Windows.Storage;
using MacPilot.Windows.Tray;

namespace MacPilot.Windows;

[SupportedOSPlatform("windows")]
internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        // Per-Monitor-V2 so SetCursorPos / absolute SendInput coordinates are physical pixels
        // and stay correct across mixed-DPI multi-monitor setups (configured here, not in the manifest).
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var settings = AppSettings.Load(args);

        var auth = new PairingAuth(settings.PairingEnabled, settings.Pin);
        var status = new ServerStatus
        {
            Port = settings.Port,
            PairingEnabled = auth.Enabled,
            Pin = auth.Pin,
        };
        var injector = new Win32InputInjector();
        var deck = new DeckStore();
        var apps = new AppListProvider();

        // Fresh dispatcher per connection; the injector (with its serial worker) is shared.
        var server = new HttpStaticServer(
            settings, injector,
            () => new CommandDispatcher(injector, deck, apps),
            status, auth);

        server.Start();
        UpdateUrls(status, settings);

        // Pre-warm the installed-app list (Start-Menu scan + icon extraction) off the request path,
        // so the first getApps reply is served from cache instead of stalling a connection.
        _ = Task.Run(() => { try { apps.GetJson(); } catch { /* best-effort */ } });

        Log.Info($"MacPilot Windows Helper started — running={status.IsRunning}, url={status.Url}, pairing={(auth.Enabled ? "ON" : "OFF")}");

        using var tray = new TrayApp(status, settings, server);
        Application.Run(tray);

        server.Stop();
        injector.Dispose();
    }

    private static void UpdateUrls(ServerStatus status, AppSettings settings)
    {
        if (settings.LocalhostOnly)
        {
            status.Url = $"http://localhost:{settings.Port}";
            status.IpFallbackUrl = "";
            return;
        }

        var ip = NetworkInfo.PrimaryIPv4();
        var host = NetworkInfo.LocalHostName();

        // Primary URL = LAN IPv4 (most reliable on Windows); .local shown as a best-effort hint.
        if (ip is not null)
        {
            status.Url = $"http://{ip}:{settings.Port}";
            status.IpFallbackUrl = $"http://{host}:{settings.Port} (mDNS, 환경에 따라 미해석)";
        }
        else
        {
            status.Url = $"http://{host}:{settings.Port}";
            status.IpFallbackUrl = $"http://localhost:{settings.Port}";
        }
    }
}
