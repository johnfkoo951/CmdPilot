using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using MacPilot.Windows.Commands;
using MacPilot.Windows.Config;
using MacPilot.Windows.Diagnostics;
using MacPilot.Windows.Input;

namespace MacPilot.Windows.Server;

/// <summary>
/// The HTTP + WebSocket server, Option B style: a hand-rolled <see cref="TcpListener"/> (binds
/// 0.0.0.0:port as a normal user — NO http.sys, NO URL ACL, NO admin, exactly like the macOS
/// NWListener) that serves the embedded web client over HTTP/1.1 and upgrades /ws connections.
/// We hand-roll only the 101 handshake, then hand the raw stream to
/// <see cref="WebSocket.CreateFromStream"/> for spec-correct framing/masking/ping-pong/close.
/// </summary>
public sealed class HttpStaticServer
{
    private readonly AppSettings _settings;
    private readonly IInputInjector _injector;
    private readonly DispatcherFactory _dispatcherFactory;
    private readonly ServerStatus _status;
    private readonly PairingAuth _auth;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    /// <summary>Creates a fresh dispatcher per request (cheap; keeps no per-connection state but the injector).</summary>
    public delegate CommandDispatcher DispatcherFactory();

    public HttpStaticServer(AppSettings settings, IInputInjector injector, DispatcherFactory dispatcherFactory, ServerStatus status, PairingAuth auth)
    {
        _settings = settings;
        _injector = injector;
        _dispatcherFactory = dispatcherFactory;
        _status = status;
        _auth = auth;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        try
        {
            _listener = new TcpListener(_settings.BindAddress, _settings.Port);
            _listener.Start();
            _status.IsRunning = true;
            _status.Port = _settings.Port;
            Log.Info($"server listening on {_settings.BindAddress}:{_settings.Port}");
        }
        catch (Exception ex)
        {
            _status.IsRunning = false;
            _status.LastError = $"포트 {_settings.Port} 바인드 실패: {ex.Message}";
            Log.Error(_status.LastError);
            return;
        }
        _ = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    public void Stop()
    {
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _listener?.Stop(); } catch { /* ignore */ }
        _status.IsRunning = false;
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener is not null)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(ct); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { Log.Warn($"accept failed: {ex.Message}"); continue; }

            _ = Task.Run(() => HandleClientAsync(client, ct));
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        try
        {
            client.NoDelay = true;
            using var stream = client.GetStream();
            var (requestLine, headers) = await ReadHttpHeaderAsync(stream, ct);
            if (requestLine is null) return;

            var path = ParsePath(requestLine);
            var clean = path.Split('?', 2)[0];
            bool authed = _auth.IsAuthorized(
                PairingAuth.ReadCookie(headers.GetValueOrDefault("cookie"), PairingAuth.CookieName));

            if (IsWebSocketUpgrade(headers) && headers.TryGetValue("sec-websocket-key", out var wsKey))
            {
                // Gate the input channel: the browser auto-sends the auth cookie on the WS handshake,
                // so no change to the reused web client is needed.
                if (!authed) { await WriteSimpleAsync(stream, "401 Unauthorized", "Unauthorized", ct); return; }
                await UpgradeAndServeWebSocketAsync(stream, wsKey, ct);
            }
            else if (clean == "/pair")
            {
                await ServePairAsync(stream, path, ct);
            }
            else if (_auth.Enabled && !authed && (clean == "/" || clean == "/index.html"))
            {
                await WritePairPageAsync(stream, error: false, ct);
            }
            else
            {
                await ServeStaticAsync(stream, path, ct);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"client handling error: {ex.Message}");
        }
        finally
        {
            try { client.Close(); } catch { /* ignore */ }
        }
    }

    // ── HTTP ──

    /// <summary>Read request bytes one at a time up to the CRLFCRLF header terminator (no body over-read).</summary>
    private static async Task<(string? RequestLine, Dictionary<string, string> Headers)> ReadHttpHeaderAsync(NetworkStream stream, CancellationToken ct)
    {
        var sb = new StringBuilder(512);
        var one = new byte[1];
        int matched = 0; // counts progress through \r\n\r\n
        int guard = 0;
        while (guard++ < 64 * 1024)
        {
            int n = await stream.ReadAsync(one.AsMemory(0, 1), ct);
            if (n == 0) break; // closed
            char c = (char)one[0];
            sb.Append(c);
            matched = c switch
            {
                '\r' when matched == 0 || matched == 2 => matched + 1,
                '\n' when matched == 1 || matched == 3 => matched + 1,
                _ => 0,
            };
            if (matched == 4) break; // full CRLFCRLF
        }

        var text = sb.ToString();
        var lines = text.Split("\r\n");
        if (lines.Length == 0 || string.IsNullOrEmpty(lines[0])) return (null, new());

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 1; i < lines.Length; i++)
        {
            var line = lines[i];
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var key = line[..colon].Trim().ToLowerInvariant();
            var val = line[(colon + 1)..].Trim();
            headers[key] = val;
        }
        return (lines[0], headers);
    }

    private static string ParsePath(string requestLine)
    {
        var parts = requestLine.Split(' ');
        return parts.Length >= 2 ? parts[1] : "/";
    }

    private static bool IsWebSocketUpgrade(Dictionary<string, string> headers)
        => headers.TryGetValue("upgrade", out var up)
           && up.Contains("websocket", StringComparison.OrdinalIgnoreCase);

    private static async Task ServeStaticAsync(NetworkStream stream, string path, CancellationToken ct)
    {
        var asset = StaticAssets.Resolve(path);
        if (asset is not { } a)
        {
            var nf = Encoding.UTF8.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found");
            await stream.WriteAsync(nf, ct);
            return;
        }

        var head = $"HTTP/1.1 200 OK\r\nContent-Type: {a.ContentType}\r\nContent-Length: {a.Bytes.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head), ct);
        await stream.WriteAsync(a.Bytes, ct);
        await stream.FlushAsync(ct);
    }

    // ── PIN pairing ──

    /// <summary>GET /pair?pin=NNNNNN — verify the PIN, set the auth cookie, redirect to "/".</summary>
    private async Task ServePairAsync(NetworkStream stream, string path, CancellationToken ct)
    {
        var pin = GetQueryParam(path, "pin");
        if (_auth.VerifyPin(pin))
        {
            var token = _auth.IssueToken();
            var head = "HTTP/1.1 302 Found\r\n"
                     + $"Set-Cookie: {PairingAuth.CookieName}={token}; Path=/; HttpOnly; SameSite=Lax\r\n"
                     + "Location: /\r\n"
                     + "Cache-Control: no-store\r\n"
                     + "Content-Length: 0\r\n"
                     + "Connection: close\r\n\r\n";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(head), ct);
            await stream.FlushAsync(ct);
            return;
        }

        // Wrong PIN (an attempt was made) → throttle to slow brute force, then re-show with error.
        if (pin is not null) await Task.Delay(400, ct);
        await WritePairPageAsync(stream, error: pin is not null, ct);
    }

    private static async Task WritePairPageAsync(NetworkStream stream, bool error, CancellationToken ct)
    {
        var body = Encoding.UTF8.GetBytes(PairPage.Html(error));
        var head = $"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head), ct);
        await stream.WriteAsync(body, ct);
        await stream.FlushAsync(ct);
    }

    private static async Task WriteSimpleAsync(NetworkStream stream, string status, string body, CancellationToken ct)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var head = $"HTTP/1.1 {status}\r\nContent-Length: {bodyBytes.Length}\r\nConnection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head), ct);
        await stream.WriteAsync(bodyBytes, ct);
        await stream.FlushAsync(ct);
    }

    private static string? GetQueryParam(string path, string key)
    {
        int q = path.IndexOf('?');
        if (q < 0) return null;
        foreach (var pair in path[(q + 1)..].Split('&'))
        {
            var kv = pair.Split('=', 2);
            if (kv[0] == key) return kv.Length == 2 ? Uri.UnescapeDataString(kv[1]) : "";
        }
        return null;
    }

    // ── WebSocket ──

    private async Task UpgradeAndServeWebSocketAsync(NetworkStream stream, string wsKey, CancellationToken ct)
    {
        var response = WebSocketHandshake.BuildResponse(wsKey);
        await stream.WriteAsync(Encoding.ASCII.GetBytes(response), ct);
        await stream.FlushAsync(ct);

        using var ws = WebSocket.CreateFromStream(stream, isServer: true, subProtocol: null,
            keepAliveInterval: TimeSpan.FromSeconds(30));

        _status.ClientConnected();
        var dispatcher = _dispatcherFactory();
        try
        {
            await ReceiveLoopAsync(ws, dispatcher, ct);
        }
        catch (Exception ex)
        {
            Log.Warn($"ws session error: {ex.Message}");
        }
        finally
        {
            // Release any held mouse button so a dropped drag never sticks (parity with releaseAll on onClose).
            _injector.ReleaseAll();
            _status.ClientDisconnected();
            try
            {
                if (ws.State == WebSocketState.Open)
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
            }
            catch { /* ignore */ }
        }
    }

    private static async Task ReceiveLoopAsync(WebSocket ws, CommandDispatcher dispatcher, CancellationToken ct)
    {
        const int MaxMessageBytes = 8 * 1024 * 1024; // generous: saveDeck can embed base64 app icons
        var buffer = new byte[16 * 1024];
        var message = new MemoryStream();

        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            WebSocketReceiveResult result;
            message.SetLength(0);
            bool oversize = false;
            do
            {
                result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
                    return;
                }
                if (!oversize)
                {
                    message.Write(buffer, 0, result.Count);
                    if (message.Length > MaxMessageBytes) { oversize = true; message.SetLength(0); }
                }
                // keep draining frames even when oversize so framing stays in sync
            }
            while (!result.EndOfMessage);

            if (oversize) { Log.Warn("dropped oversized WebSocket message (skipped, connection kept)"); continue; }
            if (result.MessageType != WebSocketMessageType.Text) continue;

            var json = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
            var cmd = InboundCommand.TryParse(json);
            if (cmd is null) continue; // unknown/invalid JSON safely ignored

            dispatcher.Dispatch(cmd, text => SendText(ws, text, ct));
        }
    }

    private static void SendText(WebSocket ws, string text, CancellationToken ct)
    {
        try
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            // ReceiveLoop is single-threaded per connection, so this send never overlaps another.
            ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, ct).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            Log.Warn($"ws send failed: {ex.Message}");
        }
    }
}
