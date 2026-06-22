namespace MacPilot.Windows.Input;

/// <summary>A resolved key chord: modifier VKs to hold (in order) around a main key VK.</summary>
public readonly record struct KeyChord(IReadOnlyList<ushort> Modifiers, ushort? MainVk);

/// <summary>
/// Folds the macOS modifier vocabulary (command/control/shift/option) onto Windows modifiers and
/// resolves the main key, with the two unavoidable special cases for the shipped default deck:
///   • ⌘Tab  (keyCode 48 + command) → Alt+Tab   (app switcher)
///   • ⌘Space (keyCode 49 + command) → Win+S     (Spotlight ≈ Windows Search)
/// General fold: command→Ctrl, control→Ctrl, shift→Shift, option→Alt (Ctrl deduped).
/// This is a pure function so it is fully unit-testable without injecting input.
/// </summary>
public static class ModifierMap
{
    public const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B;
    public const ushort VK_TAB = 0x09, VK_S = 0x53;

    public static KeyChord Plan(int macKeyCode, IReadOnlyList<string>? mods)
    {
        mods ??= [];
        bool command = mods.Contains("command");
        bool control = mods.Contains("control");
        bool shift = mods.Contains("shift");
        bool option = mods.Contains("option");

        // ── special cases (only when ⌘ is the SOLE modifier; otherwise fall through so extra
        //    modifiers like ⌘⇧Tab aren't silently dropped) ──
        bool commandOnly = command && !control && !shift && !option;
        if (commandOnly && macKeyCode == 48) // ⌘Tab → Alt+Tab
            return new KeyChord([VK_MENU], VK_TAB);
        if (commandOnly && macKeyCode == 49) // ⌘Space → Win+S
            return new KeyChord([VK_LWIN], VK_S);

        // ── generic fold, stable order Ctrl, Alt, Shift, Win ──
        var modifiers = new List<ushort>();
        if (command || control) modifiers.Add(VK_CONTROL); // deduped: both fold to Ctrl
        if (option) modifiers.Add(VK_MENU);
        if (shift) modifiers.Add(VK_SHIFT);

        return new KeyChord(modifiers, KeyMap.ToWindowsVk(macKeyCode));
    }
}
