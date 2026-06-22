using System.Security.Cryptography;
using System.Text;

namespace MacPilot.Windows.Server;

/// <summary>
/// Optional PIN-based pairing (Phase 2). Backward compatible: when <see cref="Enabled"/> is false the
/// server behaves exactly as before (no checks). When enabled, a phone must enter the PIN once; the
/// server then issues an auth cookie. Because the cookie is set on the same origin, the browser
/// automatically attaches it to the <c>/ws</c> WebSocket handshake — so the REUSED web client
/// (MacHelper/Web/app.js) needs NO changes. macOS is unaffected (this is Windows-only code).
/// </summary>
public sealed class PairingAuth
{
    public const string CookieName = "mp_auth";

    private readonly byte[]? _pinBytes;
    private readonly HashSet<string> _tokens = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public bool Enabled { get; }
    public string Pin { get; }

    public PairingAuth(bool enabled, string? pin)
    {
        Enabled = enabled && !string.IsNullOrEmpty(pin);
        Pin = Enabled ? pin! : "";
        _pinBytes = Enabled ? Encoding.UTF8.GetBytes(Pin) : null;
    }

    /// <summary>Generate a random 6-digit PIN (cryptographic RNG).</summary>
    public static string GeneratePin() => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");

    /// <summary>Constant-time PIN check.</summary>
    public bool VerifyPin(string? candidate)
    {
        if (!Enabled || candidate is null || _pinBytes is null) return false;
        var cand = Encoding.UTF8.GetBytes(candidate);
        return cand.Length == _pinBytes.Length && CryptographicOperations.FixedTimeEquals(cand, _pinBytes);
    }

    /// <summary>Issue and remember a session token (returned to the client as the auth cookie value).</summary>
    public string IssueToken()
    {
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        lock (_gate) _tokens.Add(token);
        return token;
    }

    /// <summary>True if the request is authorized. Always true when pairing is disabled (open).</summary>
    public bool IsAuthorized(string? token)
    {
        if (!Enabled) return true;
        if (string.IsNullOrEmpty(token)) return false;
        lock (_gate) return _tokens.Contains(token);
    }

    /// <summary>Extract a named cookie value from a raw Cookie header ("a=1; mp_auth=xyz").</summary>
    public static string? ReadCookie(string? cookieHeader, string name)
    {
        if (string.IsNullOrEmpty(cookieHeader)) return null;
        foreach (var part in cookieHeader.Split(';'))
        {
            var kv = part.Split('=', 2);
            if (kv.Length == 2 && kv[0].Trim().Equals(name, StringComparison.Ordinal))
                return kv[1].Trim();
        }
        return null;
    }
}
