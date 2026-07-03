using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using MacPilot.Windows.Commands;
using MacPilot.Windows.Config;
using MacPilot.Windows.Server;
using MacPilot.Windows.Storage;
using MacPilot.Windows.Apps;
using Xunit;

namespace MacPilot.Windows.Tests;

/// <summary>
/// End-to-end smoke tests against a real loopback TcpListener: HTTP static serving + the /ws
/// handshake/message round-trip with System.Net.WebSockets.ClientWebSocket. Binds localhost-only
/// so no firewall prompt is triggered.
/// </summary>
public class ServerIntegrationTests : IDisposable
{
    private readonly int _port = FreeTcpPort();
    private readonly FakeInjector _injector = new();
    private readonly HttpStaticServer _server;
    private readonly ServerStatus _status = new();

    public ServerIntegrationTests()
    {
        var settings = AppSettings.Load(new[] { "--port", _port.ToString(), "--localhost" });
        var deck = new DeckStore(Path.Combine(Path.GetTempPath(), $"macpilot-test-{Guid.NewGuid():N}.json"));
        var apps = new AppListProvider();
        _server = new HttpStaticServer(settings, _injector,
            () => new CommandDispatcher(_injector, deck, apps), _status, new PairingAuth(false, null));
        _server.Start();
        Assert.True(_status.IsRunning, "server failed to start");
    }

    [Fact]
    public async Task Serves_index_over_http()
    {
        using var http = new HttpClient();
        var resp = await http.GetAsync($"http://localhost:{_port}/");
        Assert.Equal(System.Net.HttpStatusCode.OK, resp.StatusCode);
        Assert.Equal("text/html", resp.Content.Headers.ContentType?.MediaType);
        var body = await resp.Content.ReadAsStringAsync();
        Assert.Contains("MacPilot", body);
    }

    [Fact]
    public async Task Serves_app_js_over_http()
    {
        using var http = new HttpClient();
        var resp = await http.GetAsync($"http://localhost:{_port}/app.js");
        Assert.Equal(System.Net.HttpStatusCode.OK, resp.StatusCode);
        var body = await resp.Content.ReadAsStringAsync();
        Assert.Contains("WebSocket", body);
    }

    [Fact]
    public async Task Unknown_path_returns_404()
    {
        using var http = new HttpClient();
        var resp = await http.GetAsync($"http://localhost:{_port}/does-not-exist");
        Assert.Equal(System.Net.HttpStatusCode.NotFound, resp.StatusCode);
    }

    [Fact]
    public async Task WebSocket_getDeck_round_trip()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri($"ws://localhost:{_port}/ws"), cts.Token);
        Assert.Equal(WebSocketState.Open, ws.State);

        await SendAsync(ws, """{"t":"getDeck"}""", cts.Token);
        var reply = await ReceiveAsync(ws, cts.Token);

        // Empty store → {"t":"deck","json":null}
        Assert.Contains("\"t\":\"deck\"", reply);
        Assert.Contains("\"json\":null", reply);

        await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "done", cts.Token);
    }

    [Fact]
    public async Task WebSocket_routes_input_commands_to_injector()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri($"ws://localhost:{_port}/ws"), cts.Token);

        await SendAsync(ws, """{"t":"move","dx":4,"dy":-2}""", cts.Token);
        await SendAsync(ws, """{"t":"key","keyCode":8,"mods":["command"]}""", cts.Token);
        await SendAsync(ws, """{"t":"garbage-not-a-command}""", cts.Token); // must be ignored, not crash

        // give the server a moment to process
        await WaitUntil(() => _injector.Calls.Count >= 2, cts.Token);

        Assert.Contains(_injector.Calls, c => c.StartsWith("move:"));
        Assert.Contains(_injector.Calls, c => c.StartsWith("key:8"));

        await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "done", cts.Token);
    }

    [Fact]
    public async Task ReleaseAll_invoked_when_socket_closes()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using (var ws = new ClientWebSocket())
        {
            await ws.ConnectAsync(new Uri($"ws://localhost:{_port}/ws"), cts.Token);
            await SendAsync(ws, """{"t":"down","button":"left"}""", cts.Token);
            await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "drop", cts.Token);
        }

        await WaitUntil(() => _injector.ReleaseAllCount >= 1, cts.Token);
        Assert.True(_injector.ReleaseAllCount >= 1, "ReleaseAll should run on socket close (drag-safety)");
    }

    // ── helpers ──

    private static async Task SendAsync(ClientWebSocket ws, string text, CancellationToken ct)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, ct);
    }

    private static async Task<string> ReceiveAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[8192];
        var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
        return Encoding.UTF8.GetString(buffer, 0, result.Count);
    }

    private static async Task WaitUntil(Func<bool> condition, CancellationToken ct)
    {
        while (!condition() && !ct.IsCancellationRequested)
            await Task.Delay(25, ct);
    }

    private static int FreeTcpPort()
    {
        var l = new TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        int port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    public void Dispose() => _server.Stop();
}
