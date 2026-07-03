using System.Runtime.InteropServices;

namespace MacPilot.Windows.Input;

/// <summary>Thin Win32 SendInput P/Invoke surface for synthesizing mouse/keyboard input.</summary>
internal static class Win32Native
{
    // INPUT.type
    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;

    // MOUSEINPUT.dwFlags
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_HWHEEL = 0x1000;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

    // KEYBDINPUT.dwFlags
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    public const int WHEEL_DELTA = 120;

    // GetSystemMetrics indices for the virtual screen.
    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    public static readonly int InputSize = Marshal.SizeOf<INPUT>();

    // ── small builders ──

    public static INPUT MouseMove(int ax, int ay) => new()
    {
        type = INPUT_MOUSE,
        U = { mi = new MOUSEINPUT { dx = ax, dy = ay, dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK } }
    };

    public static INPUT MouseButton(uint flag) => new()
    {
        type = INPUT_MOUSE,
        U = { mi = new MOUSEINPUT { dwFlags = flag } }
    };

    public static INPUT MouseWheel(uint flag, int amount) => new()
    {
        type = INPUT_MOUSE,
        U = { mi = new MOUSEINPUT { mouseData = unchecked((uint)amount), dwFlags = flag } }
    };

    public static INPUT KeyEvent(ushort vk, bool keyUp)
    {
        uint flags = keyUp ? KEYEVENTF_KEYUP : 0;
        if (KeyMap.IsExtended(vk)) flags |= KEYEVENTF_EXTENDEDKEY;
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            U = { ki = new KEYBDINPUT { wVk = vk, wScan = 0, dwFlags = flags } }
        };
    }

    /// <summary>One UTF-16 code unit via KEYEVENTF_UNICODE (handles Korean + emoji surrogate halves).</summary>
    public static INPUT Unicode(ushort codeUnit, bool keyUp) => new()
    {
        type = INPUT_KEYBOARD,
        U = { ki = new KEYBDINPUT { wVk = 0, wScan = codeUnit, dwFlags = KEYEVENTF_UNICODE | (keyUp ? KEYEVENTF_KEYUP : 0) } }
    };

    private static long _lastBlockedWarnTicks;

    public static void Send(params INPUT[] inputs)
    {
        if (inputs.Length == 0) return;
        uint sent = SendInput((uint)inputs.Length, inputs, InputSize);
        if (sent != inputs.Length)
        {
            // Input was blocked (commonly UIPI: a foreground elevated/secure window). Behaviorally
            // we just drop it, but log occasionally (throttled) to aid field diagnosis.
            long now = Environment.TickCount64;
            if (now - _lastBlockedWarnTicks > 3000)
            {
                _lastBlockedWarnTicks = now;
                Diagnostics.Log.Warn($"SendInput blocked: {sent}/{inputs.Length} injected (UIPI / elevated window?)");
            }
        }
    }
}
