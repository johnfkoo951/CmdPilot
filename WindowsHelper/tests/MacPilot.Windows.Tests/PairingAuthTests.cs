using MacPilot.Windows.Server;
using Xunit;

namespace MacPilot.Windows.Tests;

public class PairingAuthTests
{
    [Fact]
    public void Disabled_authorizes_everything()
    {
        var auth = new PairingAuth(false, null);
        Assert.False(auth.Enabled);
        Assert.True(auth.IsAuthorized(null));   // open when pairing is off
        Assert.True(auth.IsAuthorized("anything"));
    }

    [Fact]
    public void Enabled_requires_a_valid_token()
    {
        var auth = new PairingAuth(true, "123456");
        Assert.True(auth.Enabled);
        Assert.False(auth.IsAuthorized(null));
        Assert.False(auth.IsAuthorized("bogus"));

        var token = auth.IssueToken();
        Assert.True(auth.IsAuthorized(token));
    }

    [Fact]
    public void VerifyPin_checks_exact_pin()
    {
        var auth = new PairingAuth(true, "123456");
        Assert.True(auth.VerifyPin("123456"));
        Assert.False(auth.VerifyPin("123457"));
        Assert.False(auth.VerifyPin("12345"));   // wrong length
        Assert.False(auth.VerifyPin(null));
    }

    [Fact]
    public void Enabled_with_empty_pin_is_treated_as_disabled()
    {
        var auth = new PairingAuth(true, "");
        Assert.False(auth.Enabled);
        Assert.True(auth.IsAuthorized(null));
    }

    [Fact]
    public void GeneratePin_is_six_digits()
    {
        var pin = PairingAuth.GeneratePin();
        Assert.Equal(6, pin.Length);
        Assert.All(pin, c => Assert.True(char.IsDigit(c)));
    }

    [Theory]
    [InlineData("mp_auth=abc123", "abc123")]
    [InlineData("a=1; mp_auth=xyz; b=2", "xyz")]
    [InlineData(" mp_auth=tok ", "tok")]
    [InlineData("other=1", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void ReadCookie_extracts_named_value(string? header, string? expected)
    {
        Assert.Equal(expected, PairingAuth.ReadCookie(header, "mp_auth"));
    }

    [Fact]
    public void Issued_tokens_are_unique()
    {
        var auth = new PairingAuth(true, "000000");
        var a = auth.IssueToken();
        var b = auth.IssueToken();
        Assert.NotEqual(a, b);
        Assert.True(auth.IsAuthorized(a));
        Assert.True(auth.IsAuthorized(b));
    }
}
