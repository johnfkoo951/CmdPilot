using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using MacPilot.Windows.Apps;
using MacPilot.Windows.Commands;
using MacPilot.Windows.Config;
using MacPilot.Windows.Server;
using MacPilot.Windows.Storage;
using Xunit;

namespace MacPilot.Windows.Tests;

/// <summary>
/// End-to-end pairing flow against a loopback server with pairing ENABLED: the input channel (/ws)
/// is blocked until the PIN is entered, after which the auto-attached cookie authorizes it — all
/// without any change to the reused web client.
/// </summary>
public class PairingIntegrationTests : IDisposable
{
    private const string Pin = "246810";
    private readonly int _port = FreePort();
    private readonly FakeInjector _injector = new();
    private readonly HttpStaticServer _server;
    private readonly ServerStatus _status = new();

    public PairingIntegrationTests()
    {
        var settings = AppSettings.Load(new[] { "--port", _port.ToString(), "--localhost", "--pin", Pin });
        Assert.True(settings.PairingEnabled);
        Assert.Equal(Pin, settings.Pin);

        var deck = new DeckStore(Path.Combine(Path.GetTempPath(), $"macpilot-pair-{Guid.NewGuid():N}.json"));
        var auth = new PairingAuth(settings.PairingEnabled, settings.Pin);
        _server = new HttpStaticServer(settings, _injector,
            () => new CommandDispatcher(_injector, deck, new AppListProvider()), _status, auth);
        _server.Start();
        Assert.True(_status.IsRunning);
    }

    [Fact]
    public async Task Root_shows_pair_page_when_unauthed()
    {
        using var http = new HttpClient();
        var resp = await http.GetAsync($"http://127.0.0.1:{_port}/");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var body = await resp.Content.ReadAsStringAsync();
        Assert.Contains("name=\"pin\"", body);          // the PIN form, not the trackpad UI
        Assert.DoesNotContain("id=\"trackpad\"", body);
    }

    [Fact]
    public async Task WebSocket_rejected_without_pairing_cookie()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var ws = new ClientWebSocket();
        await Assert.ThrowsAnyAsync<Exception>(async () =>
            await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{_port}/ws"), cts.Token));
        Assert.NotEqual(WebSocketState.Open, ws.State);
    }

    [Fact]
    public async Task Wrong_pin_does_not_issue_cookie()
    {
        var cookies = new CookieContainer();
        using var handler = new HttpClientHandler { CookieContainer = cookies, UseCookies = true, AllowAutoRedirect = false };
        using var http = new HttpClient(handler);

        var resp = await http.GetAsync($"http://127.0.0.1:{_port}/pair?pin=000000");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode); // re-shows the page, no redirect
        Assert.Empty(cookies.GetCookies(new Uri($"http://127.0.0.1:{_port}/")));
    }

    [Fact]
    public async Task Correct_pin_issues_cookie_and_unlocks_websocket()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var cookies = new CookieContainer();
        using var handler = new HttpClientHandler { CookieContainer = cookies, UseCookies = true, AllowAutoRedirect = false };
        using var http = new HttpClient(handler);

        // enter the correct PIN → 302 + Set-Cookie
        var pair = await http.GetAsync($"http://127.0.0.1:{_port}/pair?pin={Pin}", cts.Token);
        Assert.Equal(HttpStatusCode.Found, pair.StatusCode);
        var token = cookies.GetCookies(new Uri($"http://127.0.0.1:{_port}/"))["mp_auth"]?.Value;
        Assert.False(string.IsNullOrEmpty(token));

        // now the WebSocket handshake carrying the cookie is accepted
        using var ws = new ClientWebSocket();
        ws.Options.Cookies = new CookieContainer();
        ws.Options.Cookies.Add(new Uri($"http://127.0.0.1:{_port}/"), new Cookie("mp_auth", token));
        await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{_port}/ws"), cts.Token);
        Assert.Equal(WebSocketState.Open, ws.State);

        // and the protocol still works
        var send = Encoding.UTF8.GetBytes("""{"t":"getDeck"}""");
        await ws.SendAsync(new ArraySegment<byte>(send), WebSocketMessageType.Text, true, cts.Token);
        var buf = new byte[4096];
        var r = await ws.ReceiveAsync(new ArraySegment<byte>(buf), cts.Token);
        var reply = Encoding.UTF8.GetString(buf, 0, r.Count);
        Assert.Contains("\"t\":\"deck\"", reply);

        await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "done", cts.Token);
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    public void Dispose() => _server.Stop();
}
