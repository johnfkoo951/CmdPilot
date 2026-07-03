using MacPilot.Windows.Commands;

namespace MacPilot.Windows.Input;

/// <summary>
/// Abstraction over OS input injection so the command dispatcher is unit-testable without moving
/// the real cursor. Mirrors the macOS EventInjector surface (move/down/up/click/scroll/key/text/
/// macro/launch/gesture/zoom/volume/brightness) plus ReleaseAll for the drag-on-disconnect guard.
/// Implementations MUST serialize all calls on a single worker so drag state stays coherent.
/// </summary>
public interface IInputInjector
{
    void Move(double dx, double dy);
    void Down(bool right, int count);
    void Up();
    void Click(bool right, int count);
    void Scroll(double dx, double dy);
    void Key(int macKeyCode, IReadOnlyList<string>? mods);
    void Text(string text);
    void Macro(IReadOnlyList<MacroStep> steps);
    void Launch(string target);
    void Gesture(string dir);
    void Zoom(string dir);
    void Volume(string dir);
    void Brightness(string dir);

    /// <summary>Release any held mouse button — called on WebSocket close/error so a dropped drag never sticks.</summary>
    void ReleaseAll();
}
