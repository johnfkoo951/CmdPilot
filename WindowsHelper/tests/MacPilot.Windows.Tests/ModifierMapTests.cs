using MacPilot.Windows.Input;
using Xunit;

namespace MacPilot.Windows.Tests;

public class ModifierMapTests
{
    [Fact]
    public void Command_C_folds_to_Ctrl_C()
    {
        var chord = ModifierMap.Plan(8, new[] { "command" }); // ⌘C
        Assert.Equal(new[] { ModifierMap.VK_CONTROL }, chord.Modifiers);
        Assert.Equal((ushort)0x43, chord.MainVk); // 'C'
    }

    [Fact]
    public void Command_Tab_special_cases_to_Alt_Tab()
    {
        var chord = ModifierMap.Plan(48, new[] { "command" }); // ⌘Tab
        Assert.Equal(new[] { ModifierMap.VK_MENU }, chord.Modifiers);
        Assert.Equal(ModifierMap.VK_TAB, chord.MainVk);
    }

    [Fact]
    public void Command_Space_special_cases_to_Win_S()
    {
        var chord = ModifierMap.Plan(49, new[] { "command" }); // ⌘Space → Win+S (search)
        Assert.Equal(new[] { ModifierMap.VK_LWIN }, chord.Modifiers);
        Assert.Equal(ModifierMap.VK_S, chord.MainVk);
    }

    [Fact]
    public void Command_Shift_Z_maps_to_Ctrl_Shift_Z()
    {
        var chord = ModifierMap.Plan(6, new[] { "command", "shift" }); // ⌘⇧Z redo
        Assert.Equal(new[] { ModifierMap.VK_CONTROL, ModifierMap.VK_SHIFT }, chord.Modifiers);
        Assert.Equal((ushort)0x5A, chord.MainVk); // 'Z'
    }

    [Fact]
    public void Command_Tab_with_extra_modifier_does_not_hit_special_case()
    {
        // ⌘⇧Tab must NOT collapse to Alt+Tab (which would drop Shift); it falls through to the
        // generic fold → Ctrl+Shift+Tab.
        var chord = ModifierMap.Plan(48, new[] { "command", "shift" });
        Assert.Equal(new[] { ModifierMap.VK_CONTROL, ModifierMap.VK_SHIFT }, chord.Modifiers);
        Assert.Equal(ModifierMap.VK_TAB, chord.MainVk);
    }

    [Fact]
    public void Command_and_control_dedupe_to_single_Ctrl()
    {
        var chord = ModifierMap.Plan(8, new[] { "command", "control" });
        Assert.Equal(new[] { ModifierMap.VK_CONTROL }, chord.Modifiers); // not pressed twice
    }

    [Fact]
    public void Option_folds_to_Alt()
    {
        var chord = ModifierMap.Plan(0, new[] { "option" }); // ⌥A
        Assert.Equal(new[] { ModifierMap.VK_MENU }, chord.Modifiers);
        Assert.Equal((ushort)0x41, chord.MainVk);
    }

    [Fact]
    public void No_mods_returns_bare_key()
    {
        var chord = ModifierMap.Plan(36, null); // return
        Assert.Empty(chord.Modifiers);
        Assert.Equal((ushort)0x0D, chord.MainVk);
    }
}
