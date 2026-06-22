using MacPilot.Windows.Commands;
using Xunit;

namespace MacPilot.Windows.Tests;

public class CommandParsingTests
{
    [Fact]
    public void Parses_move()
    {
        var c = InboundCommand.TryParse("""{"t":"move","dx":3,"dy":-2}""");
        Assert.NotNull(c);
        Assert.Equal("move", c!.T);
        Assert.Equal(3, c.Dx);
        Assert.Equal(-2, c.Dy);
    }

    [Fact]
    public void Parses_key_with_mods()
    {
        var c = InboundCommand.TryParse("""{"t":"key","keyCode":49,"mods":["command","shift"]}""");
        Assert.NotNull(c);
        Assert.Equal(49, c!.KeyCode);
        Assert.Equal(new[] { "command", "shift" }, c.Mods);
    }

    [Fact]
    public void Parses_click_with_count()
    {
        var c = InboundCommand.TryParse("""{"t":"click","button":"left","count":2}""");
        Assert.Equal("left", c!.Button);
        Assert.Equal(2, c.Count);
    }

    [Fact]
    public void Right_click_without_count_defaults_handled_by_dispatcher()
    {
        var c = InboundCommand.TryParse("""{"t":"click","button":"right"}""");
        Assert.Equal("right", c!.Button);
        Assert.Null(c.Count);
    }

    [Fact]
    public void Parses_text_with_korean_and_emoji()
    {
        var c = InboundCommand.TryParse("""{"t":"text","text":"안녕😀"}""");
        Assert.Equal("안녕😀", c!.Text);
    }

    [Fact]
    public void Parses_macro_steps()
    {
        var json = """{"t":"macro","steps":[{"type":"key","keyCode":0,"mods":["command"]},{"type":"delay","ms":80},{"type":"text","text":"hi"}]}""";
        var c = InboundCommand.TryParse(json);
        Assert.NotNull(c);
        Assert.Equal(3, c!.Steps!.Length);
        Assert.Equal("key", c.Steps[0].Type);
        Assert.Equal(80, c.Steps[1].Ms);
        Assert.Equal("hi", c.Steps[2].Text);
    }

    [Fact]
    public void Parses_saveDeck_field_name()
    {
        var c = InboundCommand.TryParse("""{"t":"saveDeck","deckJson":"{\"folders\":[]}"}""");
        Assert.Equal("saveDeck", c!.T);
        Assert.Equal("{\"folders\":[]}", c.DeckJson);
    }

    [Fact]
    public void Parses_volume_and_gesture_dir()
    {
        Assert.Equal("mute", InboundCommand.TryParse("""{"t":"volume","dir":"mute"}""")!.Dir);
        Assert.Equal("up", InboundCommand.TryParse("""{"t":"gesture","dir":"up"}""")!.Dir);
    }

    [Fact]
    public void Hello_carries_name()
    {
        var c = InboundCommand.TryParse("""{"t":"hello","name":"Safari"}""");
        Assert.Equal("Safari", c!.Name);
    }

    [Fact]
    public void Malformed_json_returns_null()
    {
        Assert.Null(InboundCommand.TryParse("not json"));
        Assert.Null(InboundCommand.TryParse("{"));
    }

    [Fact]
    public void Missing_t_returns_null()
    {
        Assert.Null(InboundCommand.TryParse("""{"dx":1}"""));
    }
}
