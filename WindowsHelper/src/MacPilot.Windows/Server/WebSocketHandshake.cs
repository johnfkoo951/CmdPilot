using System.Security.Cryptography;
using System.Text;

namespace MacPilot.Windows.Server;

/// <summary>
/// RFC6455 opening-handshake helper. We hand-roll only the 101 response (so we can keep the no-admin
/// TcpListener bind), then hand the raw stream to System.Net.WebSockets.WebSocket.CreateFromStream
/// for all framing. Mirrors HTTPWebSocketConnection.performHandshake.
/// </summary>
public static class WebSocketHandshake
{
    private const string Magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    /// <summary>Compute the Sec-WebSocket-Accept value for a given Sec-WebSocket-Key.</summary>
    public static string ComputeAccept(string secWebSocketKey)
    {
        var bytes = Encoding.ASCII.GetBytes(secWebSocketKey + Magic);
        var hash = SHA1.HashData(bytes);
        return Convert.ToBase64String(hash);
    }

    /// <summary>Build the full HTTP/1.1 101 Switching Protocols response.</summary>
    public static string BuildResponse(string secWebSocketKey)
    {
        var accept = ComputeAccept(secWebSocketKey);
        return "HTTP/1.1 101 Switching Protocols\r\n"
             + "Upgrade: websocket\r\n"
             + "Connection: Upgrade\r\n"
             + $"Sec-WebSocket-Accept: {accept}\r\n"
             + "\r\n";
    }
}
