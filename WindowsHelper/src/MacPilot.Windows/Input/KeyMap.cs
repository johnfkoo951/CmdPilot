namespace MacPilot.Windows.Input;

/// <summary>
/// Translates the macOS virtual key codes the web client sends (app.js KEYMAP + SPECIAL_KEYS)
/// into Windows VK_* codes for SendInput. The wire protocol is unchanged — this is a pure
/// server-side interpretation layer. Derived directly from MacHelper/Web/app.js:69-83.
///
/// Layout caveat (documented): OEM punctuation maps to US/QWERTY VK_OEM_* codes. Un-modified
/// typing flows through the layout-independent <c>text</c> command (KEYEVENTF_UNICODE), so this
/// US-layout assumption only affects modified shortcuts.
/// </summary>
public static class KeyMap
{
    // Windows virtual-key constants used here.
    public const ushort VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_ESCAPE = 0x1B, VK_SPACE = 0x20;
    public const ushort VK_PRIOR = 0x21, VK_NEXT = 0x22, VK_END = 0x23, VK_HOME = 0x24;
    public const ushort VK_LEFT = 0x25, VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_DELETE = 0x2E;
    public const ushort VK_OEM_1 = 0xBA, VK_OEM_PLUS = 0xBB, VK_OEM_COMMA = 0xBC, VK_OEM_MINUS = 0xBD, VK_OEM_PERIOD = 0xBE, VK_OEM_2 = 0xBF, VK_OEM_3 = 0xC0;
    public const ushort VK_OEM_4 = 0xDB, VK_OEM_5 = 0xDC, VK_OEM_6 = 0xDD, VK_OEM_7 = 0xDE;

    private static readonly Dictionary<int, ushort> Table = new()
    {
        // ── letters (macOS VK → Windows 'A'..'Z') ──
        [0] = 0x41,  [1] = 0x53,  [2] = 0x44,  [3] = 0x46,  [4] = 0x48,  [5] = 0x47,
        [6] = 0x5A,  [7] = 0x58,  [8] = 0x43,  [9] = 0x56,  [11] = 0x42, [12] = 0x51,
        [13] = 0x57, [14] = 0x45, [15] = 0x52, [16] = 0x59, [17] = 0x54, [31] = 0x4F,
        [32] = 0x55, [34] = 0x49, [35] = 0x50, [37] = 0x4C, [38] = 0x4A, [40] = 0x4B,
        [45] = 0x4E, [46] = 0x4D,

        // ── digits (macOS VK → Windows '0'..'9') ──
        [18] = 0x31, [19] = 0x32, [20] = 0x33, [21] = 0x34, [23] = 0x35,
        [22] = 0x36, [26] = 0x37, [28] = 0x38, [25] = 0x39, [29] = 0x30,

        // ── punctuation (US layout) ──
        [27] = VK_OEM_MINUS, [24] = VK_OEM_PLUS, [33] = VK_OEM_4, [30] = VK_OEM_6,
        [41] = VK_OEM_1, [39] = VK_OEM_7, [43] = VK_OEM_COMMA, [47] = VK_OEM_PERIOD,
        [44] = VK_OEM_2, [42] = VK_OEM_5, [50] = VK_OEM_3,

        // ── special keys ──
        [49] = VK_SPACE, [36] = VK_RETURN, [48] = VK_TAB, [53] = VK_ESCAPE,
        [51] = VK_BACK,                 // ⌫ — the keyboard tab sends this for every deleted char
        [117] = VK_DELETE,              // ⌦ forward delete
        [123] = VK_LEFT, [124] = VK_RIGHT, [126] = VK_UP, [125] = VK_DOWN,
        [115] = VK_HOME, [119] = VK_END, [116] = VK_PRIOR, [121] = VK_NEXT,

        // ── function keys (macOS VK → VK_F1..VK_F12 = 0x70..0x7B) ──
        [122] = 0x70, [120] = 0x71, [99] = 0x72,  [118] = 0x73, [96] = 0x74, [97] = 0x75,
        [98] = 0x76,  [100] = 0x77, [101] = 0x78, [109] = 0x79, [103] = 0x7A, [111] = 0x7B,
    };

    /// <summary>macOS virtual key code → Windows VK, or null if unmapped (caller should no-op).</summary>
    public static ushort? ToWindowsVk(int macKeyCode)
        => Table.TryGetValue(macKeyCode, out var vk) ? vk : null;

    /// <summary>
    /// Keys that require KEYEVENTF_EXTENDEDKEY for correct behavior (navigation/arrows, etc.).
    /// </summary>
    public static bool IsExtended(ushort vk) => vk switch
    {
        VK_LEFT or VK_RIGHT or VK_UP or VK_DOWN
            or VK_HOME or VK_END or VK_PRIOR or VK_NEXT or VK_DELETE => true,
        0x5B or 0x5C => true,   // VK_LWIN / VK_RWIN
        _ => false,
    };
}
