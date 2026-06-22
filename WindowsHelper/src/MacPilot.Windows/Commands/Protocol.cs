namespace MacPilot.Windows.Commands;

/// <summary>
/// Builds the two server→client reply messages. CRITICAL compatibility detail: the stored deck
/// JSON must be embedded UNQUOTED as a nested object (the client checks <c>m.json.folders</c>).
/// Re-serializing the stored string through a JSON encoder would double-encode it into a quoted
/// string and silently wipe/reseed the user's deck. This mirrors the macOS HelperServer string
/// interpolation: {"t":"deck","json":&lt;rawDeckJsonOrNull&gt;}.
/// </summary>
public static class Protocol
{
    /// <summary>
    /// getDeck reply. <paramref name="rawDeckJson"/> is the verbatim stored deck text, or null
    /// when nothing is stored (client then pushes its local deck via saveDeck).
    /// </summary>
    public static string DeckReply(string? rawDeckJson)
    {
        var json = string.IsNullOrWhiteSpace(rawDeckJson) ? "null" : rawDeckJson.Trim();
        return "{\"t\":\"deck\",\"json\":" + json + "}";
    }

    /// <summary>apps reply. <paramref name="listJsonArray"/> is a JSON array string [{name,path,icon}, ...].</summary>
    public static string AppsReply(string listJsonArray)
    {
        var arr = string.IsNullOrWhiteSpace(listJsonArray) ? "[]" : listJsonArray.Trim();
        return "{\"t\":\"apps\",\"list\":" + arr + "}";
    }
}
