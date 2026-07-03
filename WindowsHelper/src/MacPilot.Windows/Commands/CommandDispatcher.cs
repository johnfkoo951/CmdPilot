using MacPilot.Windows.Apps;
using MacPilot.Windows.Input;
using MacPilot.Windows.Storage;

namespace MacPilot.Windows.Commands;

/// <summary>
/// Routes a parsed <see cref="InboundCommand"/> to the right handler — combining the macOS
/// HelperServer.onCommand control-command interception (getDeck/saveDeck/getApps) with the
/// EventInjector.apply switch (everything else). Control replies go back through <paramref name="reply"/>.
/// </summary>
public sealed class CommandDispatcher
{
    private readonly IInputInjector _injector;
    private readonly DeckStore _deck;
    private readonly AppListProvider _apps;

    public CommandDispatcher(IInputInjector injector, DeckStore deck, AppListProvider apps)
    {
        _injector = injector;
        _deck = deck;
        _apps = apps;
    }

    /// <summary>
    /// Handle one command. <paramref name="reply"/> sends a text frame back (used only by control
    /// commands). Returns true if a reply was produced.
    /// </summary>
    public bool Dispatch(InboundCommand cmd, Action<string> reply)
    {
        switch (cmd.T)
        {
            // ── control commands (intercepted before injection, like HelperServer) ──
            case "getDeck":
                reply(Protocol.DeckReply(_deck.LoadString()));
                return true;
            case "saveDeck":
                _deck.Save(cmd.DeckJson);
                return false;
            case "getApps":
                reply(Protocol.AppsReply(_apps.GetJson()));
                return true;

            // ── input commands ──
            case "move":   _injector.Move(cmd.Dx ?? 0, cmd.Dy ?? 0); return false;
            case "down":   _injector.Down(cmd.Button == "right", cmd.Count ?? 1); return false;
            case "up":     _injector.Up(); return false;
            case "click":  _injector.Click(cmd.Button == "right", cmd.Count ?? 1); return false;
            case "scroll": _injector.Scroll(cmd.Dx ?? 0, cmd.Dy ?? 0); return false;
            case "key":    _injector.Key(cmd.KeyCode ?? 0, cmd.Mods); return false;
            case "text":   _injector.Text(cmd.Text ?? ""); return false;
            case "macro":  _injector.Macro(cmd.Steps ?? []); return false;
            case "launch": _injector.Launch(cmd.Target ?? ""); return false;
            case "gesture": _injector.Gesture(cmd.Dir ?? ""); return false;
            case "zoom":   _injector.Zoom(cmd.Dir ?? ""); return false;
            case "volume": _injector.Volume(cmd.Dir ?? ""); return false;
            case "brightness": _injector.Brightness(cmd.Dir ?? ""); return false;

            // hello + unknown: no-op (parity with EventInjector default/hello cases)
            case "hello":
            default:
                return false;
        }
    }
}
