using System.Text;
using MacPilot.Windows.Server;
using Xunit;

namespace MacPilot.Windows.Tests;

/// <summary>
/// Verifies the embedded web client is served correctly and that path traversal / unknown paths 404.
/// The assets are embedded in the main assembly (reused verbatim from MacHelper/Web).
/// </summary>
public class StaticAssetsTests
{
    [Fact]
    public void Serves_index_for_root()
    {
        var asset = StaticAssets.Resolve("/");
        Assert.NotNull(asset);
        Assert.StartsWith("text/html", asset!.Value.ContentType);
        var html = Encoding.UTF8.GetString(asset.Value.Bytes);
        Assert.Contains("<html", html, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Serves_app_js_with_js_content_type()
    {
        var asset = StaticAssets.Resolve("/app.js");
        Assert.NotNull(asset);
        Assert.StartsWith("application/javascript", asset!.Value.ContentType);
        var js = Encoding.UTF8.GetString(asset.Value.Bytes);
        Assert.Contains("WebSocket", js); // sanity: it really is the client
    }

    [Fact]
    public void Serves_style_css()
    {
        var asset = StaticAssets.Resolve("/style.css");
        Assert.NotNull(asset);
        Assert.StartsWith("text/css", asset!.Value.ContentType);
    }

    [Fact]
    public void Strips_query_string()
    {
        Assert.NotNull(StaticAssets.Resolve("/app.js?v=123"));
    }

    [Fact]
    public void Aliases_favicon_and_apple_touch_to_logo()
    {
        Assert.NotNull(StaticAssets.Resolve("/favicon.ico"));
        Assert.NotNull(StaticAssets.Resolve("/apple-touch-icon.png"));
        Assert.NotNull(StaticAssets.Resolve("/apple-touch-icon-precomposed.png"));
    }

    [Theory]
    [InlineData("/nope")]
    [InlineData("/../secret")]
    [InlineData("/../../etc/passwd")]
    [InlineData("/app.js/../../../Program.cs")]
    [InlineData("")]
    public void Unknown_or_traversal_paths_return_null(string path)
    {
        Assert.Null(StaticAssets.Resolve(path));
    }
}
