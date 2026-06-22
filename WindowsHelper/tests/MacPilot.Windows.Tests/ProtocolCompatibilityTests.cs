using System.Text.Json;
using MacPilot.Windows.Commands;
using Xunit;

namespace MacPilot.Windows.Tests;

/// <summary>
/// Guards the byte-level compatibility with the reused web client. The most dangerous trap: the
/// stored deck JSON must be embedded UNQUOTED as a nested object so the client's m.json.folders
/// check works. Double-encoding it (as a quoted string) silently wipes the user's deck.
/// </summary>
public class ProtocolCompatibilityTests
{
    [Fact]
    public void DeckReply_embeds_deck_object_unquoted()
    {
        var raw = """{"folders":[{"id":"x1","name":"기본","items":[]}]}""";
        var reply = Protocol.DeckReply(raw);

        // The reply must parse and m.json must be an OBJECT with a folders array — not a string.
        using var doc = JsonDocument.Parse(reply);
        var json = doc.RootElement.GetProperty("json");
        Assert.Equal(JsonValueKind.Object, json.ValueKind);
        Assert.Equal(JsonValueKind.Array, json.GetProperty("folders").ValueKind);
        Assert.Equal("deck", doc.RootElement.GetProperty("t").GetString());
    }

    [Fact]
    public void DeckReply_null_when_no_deck_stored()
    {
        var reply = Protocol.DeckReply(null);
        using var doc = JsonDocument.Parse(reply);
        Assert.Equal(JsonValueKind.Null, doc.RootElement.GetProperty("json").ValueKind);
    }

    [Fact]
    public void DeckReply_does_not_double_encode()
    {
        var raw = """{"folders":[]}""";
        var reply = Protocol.DeckReply(raw);
        // A double-encoded reply would contain an escaped quote sequence \" inside json.
        Assert.DoesNotContain("\\\"folders\\\"", reply);
    }

    [Fact]
    public void AppsReply_wraps_list_array()
    {
        var list = """[{"name":"Notepad","path":"C:\\x.lnk","icon":""}]""";
        var reply = Protocol.AppsReply(list);
        using var doc = JsonDocument.Parse(reply);
        Assert.Equal("apps", doc.RootElement.GetProperty("t").GetString());
        var arr = doc.RootElement.GetProperty("list");
        Assert.Equal(JsonValueKind.Array, arr.ValueKind);
        Assert.Equal("Notepad", arr[0].GetProperty("name").GetString());
    }

    [Fact]
    public void AppsReply_empty_list_is_valid_array()
    {
        var reply = Protocol.AppsReply("");
        using var doc = JsonDocument.Parse(reply);
        Assert.Equal(JsonValueKind.Array, doc.RootElement.GetProperty("list").ValueKind);
    }
}
