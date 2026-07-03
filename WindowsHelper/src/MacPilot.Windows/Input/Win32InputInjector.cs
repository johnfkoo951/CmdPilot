using System.Collections.Concurrent;
using MacPilot.Windows.Apps;
using MacPilot.Windows.Commands;
using MacPilot.Windows.Diagnostics;
using MacPilot.Windows.SystemControls;
using static MacPilot.Windows.Input.Win32Native;

namespace MacPilot.Windows.Input;

/// <summary>
/// Real input injection via Win32 SendInput. ALL injection runs on a single background worker
/// thread (mirroring the macOS serial DispatchQueue) so move/down/up ordering and the held-drag
/// state can never interleave across WebSocket messages. Held-button state is owned by that thread.
/// </summary>
public sealed class Win32InputInjector : IInputInjector, IDisposable
{
    private readonly BlockingCollection<Action> _queue = new(new ConcurrentQueue<Action>());
    private readonly Thread _worker;
    private readonly ScrollAccumulator _scroll = new();

    // Worker-thread-only state.
    private bool _mouseDown;
    private bool _downRight;

    // Sub-pixel-accurate virtual cursor position, integrated across a move stream so a burst of
    // small deltas isn't lost to integer rounding or to GetCursorPos not yet reflecting our last
    // SendInput. Re-synced to the real cursor on the first move and after an idle gap.
    private double _virtX, _virtY;
    private bool _haveVirt;
    private long _lastMoveTicks;
    private const long ResyncIdleMs = 250;

    public Win32InputInjector()
    {
        _worker = new Thread(WorkerLoop) { IsBackground = true, Name = "MacPilot-Injector" };
        _worker.Start();
    }

    private void WorkerLoop()
    {
        foreach (var action in _queue.GetConsumingEnumerable())
        {
            try { action(); }
            catch (Exception ex) { Log.Warn($"injector action failed: {ex.Message}"); }
        }
    }

    private void Enqueue(Action a)
    {
        if (!_queue.IsAddingCompleted) _queue.Add(a);
    }

    // ── mouse ──

    public void Move(double dx, double dy) => Enqueue(() =>
    {
        var vs = CurrentVirtualScreen();
        long now = Environment.TickCount64;

        // Re-sync to the real cursor on first move or after an idle gap (the user may have moved
        // the physical mouse meanwhile). During an active stream we integrate on our own position.
        if (!_haveVirt || now - _lastMoveTicks > ResyncIdleMs)
        {
            if (GetCursorPos(out var p)) { _virtX = p.X; _virtY = p.Y; _haveVirt = true; }
            else return;
        }
        _lastMoveTicks = now;

        _virtX += dx;
        _virtY += dy;
        // Keep the virtual position inside the desktop so it can't drift off to infinity.
        _virtX = Math.Clamp(_virtX, vs.Left, vs.Right - 1);
        _virtY = Math.Clamp(_virtY, vs.Top, vs.Bottom - 1);

        var (cx, cy) = MouseMath.Clamp((int)Math.Round(_virtX), (int)Math.Round(_virtY), vs);
        var (ax, ay) = MouseMath.ToAbsolute(cx, cy, vs);
        Send(MouseMove(ax, ay));
    });

    public void Down(bool right, int count) => Enqueue(() =>
    {
        _mouseDown = true;
        _downRight = right;
        Send(MouseButton(right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN));
    });

    public void Up() => Enqueue(() =>
    {
        if (!_mouseDown) return;
        Send(MouseButton(_downRight ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP));
        _mouseDown = false;
    });

    public void Click(bool right, int count) => Enqueue(() =>
    {
        // The client sends ONE click command per physical tap, with an INCREMENTING count
        // (1, then 2, then 3 on rapid consecutive taps — app.js:827). Like the macOS reference
        // (which tags a single click via mouseEventClickState rather than clicking N times), we
        // emit exactly ONE down/up per command and let Windows' native double-click timing
        // (GetDoubleClickTime, same-position taps) coalesce them. Clicking `count` times here
        // would turn a double-tap into a triple-click.
        uint down = right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
        uint up = right ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP;
        Send(MouseButton(down), MouseButton(up));
    });

    public void Scroll(double dx, double dy) => Enqueue(() =>
    {
        var (v, h) = _scroll.Add(dx, dy);
        if (v != 0) Send(MouseWheel(MOUSEEVENTF_WHEEL, v * WHEEL_DELTA));
        if (h != 0) Send(MouseWheel(MOUSEEVENTF_HWHEEL, h * WHEEL_DELTA));
    });

    // ── keyboard ──

    public void Key(int macKeyCode, IReadOnlyList<string>? mods) => Enqueue(() =>
    {
        var chord = ModifierMap.Plan(macKeyCode, mods);
        PressChord(chord.Modifiers, chord.MainVk);
    });

    public void Text(string text) => Enqueue(() => TypeUnicode(text));

    // ── macro ──

    public void Macro(IReadOnlyList<MacroStep> steps) => Enqueue(() =>
    {
        foreach (var step in steps.Take(50)) // runaway guard, matches the Mac
        {
            switch (step.Type)
            {
                case "key":
                    var chord = ModifierMap.Plan(step.KeyCode ?? 0, step.Mods);
                    PressChord(chord.Modifiers, chord.MainVk);
                    break;
                case "text":
                    TypeUnicode(step.Text ?? "");
                    break;
                case "launch":
                    AppLauncher.Launch(step.Target ?? "");
                    break;
                case "delay":
                    Thread.Sleep(Math.Clamp(step.Ms ?? 0, 0, 5000));
                    break;
            }
        }
    });

    // ── app / system ──

    public void Launch(string target) => Enqueue(() => AppLauncher.Launch(target));

    /// <summary>3-finger swipe → virtual-desktop + Task View (per user choice). Not on the injection-critical path.</summary>
    public void Gesture(string dir) => Enqueue(() =>
    {
        switch (dir)
        {
            case "up":    PressChord([ModifierMap.VK_LWIN], ModifierMap.VK_TAB); break;        // Win+Tab Task View
            case "down":  PressChord([ModifierMap.VK_LWIN], 0x44 /*VK_D*/); break;             // Win+D show desktop
            case "left":  PressChord([ModifierMap.VK_CONTROL, ModifierMap.VK_LWIN], KeyMap.VK_LEFT); break;  // prev virtual desktop
            case "right": PressChord([ModifierMap.VK_CONTROL, ModifierMap.VK_LWIN], KeyMap.VK_RIGHT); break; // next virtual desktop
        }
    });

    /// <summary>Pinch → Ctrl +/-, consistent with command→Ctrl folding (works in browsers/zoomable apps).</summary>
    public void Zoom(string dir) => Enqueue(() =>
    {
        switch (dir)
        {
            case "in":  PressChord([ModifierMap.VK_CONTROL], KeyMap.VK_OEM_PLUS); break;
            case "out": PressChord([ModifierMap.VK_CONTROL], KeyMap.VK_OEM_MINUS); break;
        }
    });

    public void Volume(string dir) => Enqueue(() => MediaController.Volume(dir));

    public void Brightness(string dir) => Enqueue(() => BrightnessController.Adjust(dir));

    public void ReleaseAll() => Enqueue(() =>
    {
        if (_mouseDown)
        {
            Send(MouseButton(_downRight ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP));
            _mouseDown = false;
        }
    });

    // ── helpers (worker thread) ──

    /// <summary>
    /// Press modifier keys down, tap the main key, then release modifiers in REVERSE order — always
    /// releasing in a finally block so a failure can never leave Ctrl/Alt/Shift/Win physically stuck.
    /// </summary>
    private static void PressChord(IReadOnlyList<ushort> modifiers, ushort? mainVk)
    {
        var pressed = new List<ushort>();
        try
        {
            foreach (var m in modifiers)
            {
                Send(KeyEvent(m, keyUp: false));
                pressed.Add(m);
            }
            if (mainVk is { } vk)
            {
                Send(KeyEvent(vk, keyUp: false));
                Send(KeyEvent(vk, keyUp: true));
            }
        }
        finally
        {
            for (int i = pressed.Count - 1; i >= 0; i--)
                Send(KeyEvent(pressed[i], keyUp: true));
        }
    }

    /// <summary>
    /// Type an arbitrary Unicode string via KEYEVENTF_UNICODE, one INPUT per UTF-16 code UNIT.
    /// Emoji (&gt; U+FFFF) are surrogate pairs and are sent as two consecutive code units — iterating
    /// code points/runes instead would silently drop them. Mirrors keyboardSetUnicodeString.
    /// </summary>
    private static void TypeUnicode(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        var inputs = new INPUT[text.Length * 2];
        int j = 0;
        foreach (char c in text) // char iteration == UTF-16 code units
        {
            inputs[j++] = Unicode(c, keyUp: false);
            inputs[j++] = Unicode(c, keyUp: true);
        }
        Send(inputs);
    }

    private static VirtualScreen CurrentVirtualScreen() => new(
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_CXVIRTUALSCREEN),
        GetSystemMetrics(SM_CYVIRTUALSCREEN));

    public void Dispose()
    {
        _queue.CompleteAdding();
        try { _worker.Join(TimeSpan.FromSeconds(1)); } catch { /* ignore */ }
        _queue.Dispose();
    }
}
