using MacPilot.Windows.Input;
using Xunit;

namespace MacPilot.Windows.Tests;

public class MouseMapperTests
{
    private static readonly VirtualScreen Primary = new(0, 0, 1920, 1080);
    private static readonly VirtualScreen MultiMon = new(-1920, -200, 3840, 1280); // monitor to the left/above

    [Fact]
    public void Clamp_keeps_point_inside_primary()
    {
        Assert.Equal((100, 200), MouseMath.Clamp(100, 200, Primary));
    }

    [Fact]
    public void Clamp_bounds_overshoot_to_edges()
    {
        Assert.Equal((1919, 1079), MouseMath.Clamp(5000, 5000, Primary));
        Assert.Equal((0, 0), MouseMath.Clamp(-50, -50, Primary));
    }

    [Fact]
    public void Clamp_handles_negative_virtual_coordinates()
    {
        // a point on the left monitor stays valid (negative X allowed)
        Assert.Equal((-1000, -100), MouseMath.Clamp(-1000, -100, MultiMon));
        // far left overshoot snaps to the signed left edge
        Assert.Equal((-1920, -200), MouseMath.Clamp(-9999, -9999, MultiMon));
    }

    [Fact]
    public void ToAbsolute_maps_corners_to_0_and_65535()
    {
        Assert.Equal((0, 0), MouseMath.ToAbsolute(0, 0, Primary));
        Assert.Equal((65535, 65535), MouseMath.ToAbsolute(1919, 1079, Primary));
    }

    [Fact]
    public void ToAbsolute_maps_center_near_midpoint()
    {
        var (ax, ay) = MouseMath.ToAbsolute(960, 540, Primary);
        Assert.InRange(ax, 32000, 33000);
        Assert.InRange(ay, 32000, 33000);
    }

    [Fact]
    public void ScrollAccumulator_emits_notch_after_threshold()
    {
        var acc = new ScrollAccumulator(unitsPerNotch: 6.0);
        // small deltas below threshold produce nothing yet
        var (v0, _) = acc.Add(0, 2);
        Assert.Equal(0, v0);
        // accumulating past the threshold yields one notch; mirrors Mac negation (-dy)
        var (v1, _) = acc.Add(0, 5); // total -7 vertical -> -1 notch
        Assert.Equal(-1, v1);
    }

    [Fact]
    public void ScrollAccumulator_horizontal_uses_negated_dx()
    {
        var acc = new ScrollAccumulator(unitsPerNotch: 4.0);
        var (_, h) = acc.Add(8, 0); // -8 / 4 = -2 notches
        Assert.Equal(-2, h);
    }
}
