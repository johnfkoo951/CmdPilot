using MacPilot.Windows.Server;
using Xunit;

namespace MacPilot.Windows.Tests;

public class WebSocketHandshakeTests
{
    [Fact]
    public void Computes_rfc6455_accept_vector()
    {
        // The canonical RFC 6455 example: key "dGhlIHNhbXBsZSBub25jZQ==" → "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        Assert.Equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            WebSocketHandshake.ComputeAccept("dGhlIHNhbXBsZSBub25jZQ=="));
    }

    [Fact]
    public void Builds_101_switching_protocols_response()
    {
        var resp = WebSocketHandshake.BuildResponse("dGhlIHNhbXBsZSBub25jZQ==");
        Assert.StartsWith("HTTP/1.1 101 Switching Protocols\r\n", resp);
        Assert.Contains("Upgrade: websocket\r\n", resp);
        Assert.Contains("Connection: Upgrade\r\n", resp);
        Assert.Contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n", resp);
        Assert.EndsWith("\r\n\r\n", resp);
    }
}
