using System.Diagnostics;
using System.Runtime.Versioning;
using MacPilot.Windows.Config;
using MacPilot.Windows.Diagnostics;
using MacPilot.Windows.Server;

namespace MacPilot.Windows.Tray;

/// <summary>
/// WinForms NotifyIcon tray for the MVP. Shows server status, the connect URL + IP fallback, port,
/// live client count, a Windows permission/limitation note, and Quit. A timer refreshes the dynamic
/// labels. Bind/startup failures (no console in a WinExe) surface as a balloon tip + the log file.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly ServerStatus _status;
    private readonly AppSettings _settings;
    private readonly HttpStaticServer _server;
    private readonly System.Windows.Forms.Timer _timer;

    private ToolStripMenuItem _statusItem = null!;
    private ToolStripMenuItem _urlItem = null!;
    private ToolStripMenuItem _ipItem = null!;
    private ToolStripMenuItem _clientsItem = null!;
    private ToolStripMenuItem _pinItem = null!;

    public TrayApp(ServerStatus status, AppSettings settings, HttpStaticServer server)
    {
        _status = status;
        _settings = settings;
        _server = server;

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "MacPilot Windows Helper",
            ContextMenuStrip = BuildMenu(),
        };
        _icon.DoubleClick += (_, _) => OpenInBrowser();

        _timer = new System.Windows.Forms.Timer { Interval = 1000 };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();

        Refresh();

        if (!_status.IsRunning)
            _icon.ShowBalloonTip(8000, "MacPilot", _status.LastError ?? "서버 시작 실패 — 로그를 확인하세요.", ToolTipIcon.Error);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();

        _statusItem = new ToolStripMenuItem("상태 확인 중…") { Enabled = false };
        _urlItem = new ToolStripMenuItem("접속 URL: —");
        _urlItem.Click += (_, _) => OpenInBrowser();
        _ipItem = new ToolStripMenuItem("IP 폴백: —") { Enabled = false };
        _clientsItem = new ToolStripMenuItem("연결된 기기: 0") { Enabled = false };
        _pinItem = new ToolStripMenuItem("PIN: —") { Enabled = false, Visible = false };

        var copy = new ToolStripMenuItem("접속 URL 복사");
        copy.Click += (_, _) => CopyUrl();

        var openBrowser = new ToolStripMenuItem("브라우저에서 열기");
        openBrowser.Click += (_, _) => OpenInBrowser();

        var help = new ToolStripMenuItem("Windows 권한 / 제약 안내");
        help.Click += (_, _) => ShowHelp();

        var log = new ToolStripMenuItem("로그 폴더 열기");
        log.Click += (_, _) => OpenLog();

        var quit = new ToolStripMenuItem("종료");
        quit.Click += (_, _) => Quit();

        menu.Items.AddRange(new ToolStripItem[]
        {
            _statusItem,
            new ToolStripSeparator(),
            _urlItem, _ipItem, _clientsItem, _pinItem,
            new ToolStripSeparator(),
            copy, openBrowser,
            new ToolStripSeparator(),
            help, log,
            new ToolStripSeparator(),
            quit,
        });
        return menu;
    }

    private void Refresh()
    {
        _statusItem.Text = _status.IsRunning
            ? $"● 실행 중 · 포트 {_status.Port}"
            : $"○ 시작 실패{(string.IsNullOrEmpty(_status.LastError) ? "" : " · " + _status.LastError)}";
        _urlItem.Text = string.IsNullOrEmpty(_status.Url) ? "접속 URL: —" : $"접속 URL: {_status.Url}";
        _ipItem.Text = string.IsNullOrEmpty(_status.IpFallbackUrl) ? "IP 폴백: —" : $"IP 폴백: {_status.IpFallbackUrl}";
        _clientsItem.Text = $"연결된 기기: {_status.ClientCount}";
        _pinItem.Visible = _status.PairingEnabled;
        if (_status.PairingEnabled) _pinItem.Text = $"🔒 PIN: {_status.Pin}";
    }

    private void OpenInBrowser()
    {
        var url = string.IsNullOrEmpty(_status.IpFallbackUrl) ? _status.Url : _status.IpFallbackUrl;
        if (string.IsNullOrEmpty(url)) return;
        try { using var _ = Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn($"open browser failed: {ex.Message}"); }
    }

    private void CopyUrl()
    {
        var url = string.IsNullOrEmpty(_status.Url) ? _status.IpFallbackUrl : _status.Url;
        if (string.IsNullOrEmpty(url)) return;
        try { Clipboard.SetText(url); } catch { /* clipboard can transiently fail */ }
    }

    private void ShowHelp()
    {
        MessageBox.Show(
            "• 같은 Wi-Fi(사설망)에 있는 휴대폰 브라우저에서 위 접속 URL로 접속하세요.\n" +
            "• 첫 실행 시 Windows Defender 방화벽 허용 창이 뜨면 '개인 네트워크'를 허용해야 폰에서 접속됩니다.\n" +
            "• 관리자 권한으로 실행되는 창(작업 관리자, UAC 등)에는 입력이 주입되지 않습니다 (Windows UIPI 제약).\n" +
            "• 화면 밝기 제어는 노트북 내장 패널에서만 동작할 수 있습니다 (best-effort).\n" +
            "• 포트 8765를 인터넷에 노출하지 마세요. LAN 전용입니다.",
            "MacPilot — Windows 권한 / 제약",
            MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void OpenLog()
    {
        try
        {
            var dir = Path.GetDirectoryName(Log.Path_);
            if (dir is not null) { using var _ = Process.Start(new ProcessStartInfo { FileName = dir, UseShellExecute = true }); }
        }
        catch (Exception ex) { Log.Warn($"open log failed: {ex.Message}"); }
    }

    private void Quit()
    {
        _timer.Stop();
        _server.Stop();
        _icon.Visible = false;
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Dispose();
            _icon.Dispose();
        }
        base.Dispose(disposing);
    }
}
