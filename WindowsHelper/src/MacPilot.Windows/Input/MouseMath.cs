namespace MacPilot.Windows.Input;

/// <summary>A signed virtual-screen rectangle (can start negative for monitors left/above primary).</summary>
public readonly record struct VirtualScreen(int Left, int Top, int Width, int Height)
{
    public int Right => Left + Width;
    public int Bottom => Top + Height;
}

/// <summary>
/// Pure mouse coordinate math (no Win32 calls) so it is unit-testable. The web client sends a
/// RELATIVE, already-scaled delta; to match the Mac's deterministic, acceleration-free motion we
/// add the delta to the current cursor position, clamp to the signed virtual desktop, and convert
/// to the 0..65535 normalized space SendInput expects with MOUSEEVENTF_ABSOLUTE|VIRTUALDESK.
/// </summary>
public static class MouseMath
{
    /// <summary>Clamp an absolute pixel point to the signed virtual-screen rectangle.</summary>
    public static (int X, int Y) Clamp(int x, int y, VirtualScreen vs)
    {
        int cx = Math.Max(vs.Left, Math.Min(x, vs.Right - 1));
        int cy = Math.Max(vs.Top, Math.Min(y, vs.Bottom - 1));
        return (cx, cy);
    }

    /// <summary>Convert a clamped pixel point into SendInput's 0..65535 absolute/virtual-desk space.</summary>
    public static (int Ax, int Ay) ToAbsolute(int x, int y, VirtualScreen vs)
    {
        int w = Math.Max(vs.Width - 1, 1);
        int h = Math.Max(vs.Height - 1, 1);
        int ax = (int)Math.Round((x - vs.Left) * 65535.0 / w);
        int ay = (int)Math.Round((y - vs.Top) * 65535.0 / h);
        return (Math.Clamp(ax, 0, 65535), Math.Clamp(ay, 0, 65535));
    }
}

/// <summary>
/// Windows mouse wheel is quantized to WHEEL_DELTA (120) notches, while the client streams small
/// pixel deltas plus momentum frames. Accumulate fractional deltas and emit whole notches once a
/// tunable threshold is crossed, keeping the remainder. Direction mirrors the Mac (which negates
/// dy); the exact sign is a documented manual-verify item.
/// </summary>
public sealed class ScrollAccumulator
{
    private readonly double _unitsPerNotch;
    private double _accumV, _accumH;

    public ScrollAccumulator(double unitsPerNotch = 6.0) => _unitsPerNotch = Math.Max(1.0, unitsPerNotch);

    /// <summary>
    /// Feed a raw scroll delta; returns whole 120-unit wheel notches to emit (vertical, horizontal).
    /// Mirrors EventInjector.scroll's negation: vertical follows -dy, horizontal follows -dx.
    /// </summary>
    public (int VerticalNotches, int HorizontalNotches) Add(double dx, double dy)
    {
        _accumV += -dy;
        _accumH += -dx;
        int v = (int)(_accumV / _unitsPerNotch);
        int h = (int)(_accumH / _unitsPerNotch);
        _accumV -= v * _unitsPerNotch;
        _accumH -= h * _unitsPerNotch;
        return (v, h);
    }

    public void Reset() { _accumV = 0; _accumH = 0; }
}
