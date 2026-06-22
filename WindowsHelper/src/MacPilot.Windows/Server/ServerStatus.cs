namespace MacPilot.Windows.Server;

/// <summary>Thread-safe snapshot of server state for the tray UI (running, URLs, port, client count).</summary>
public sealed class ServerStatus
{
    private readonly object _gate = new();
    private int _clients;

    public bool IsRunning { get; set; }
    public string Url { get; set; } = "";
    public string IpFallbackUrl { get; set; } = "";
    public int Port { get; set; }
    public string? LastError { get; set; }

    /// <summary>PIN pairing state (for the tray display). Empty PIN when disabled.</summary>
    public bool PairingEnabled { get; set; }
    public string Pin { get; set; } = "";

    public int ClientCount { get { lock (_gate) return _clients; } }

    public void ClientConnected() { lock (_gate) _clients++; }
    public void ClientDisconnected() { lock (_gate) { if (_clients > 0) _clients--; } }
}
