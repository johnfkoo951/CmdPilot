using MacPilot.Windows.Input;
using Xunit;

namespace MacPilot.Windows.Tests;

public class KeyMapperTests
{
    [Theory]
    // letters
    [InlineData(0, 0x41)]   // a
    [InlineData(8, 0x43)]   // c
    [InlineData(9, 0x56)]   // v
    [InlineData(6, 0x5A)]   // z
    [InlineData(46, 0x4D)]  // m
    // digits (mac order)
    [InlineData(29, 0x30)]  // 0
    [InlineData(18, 0x31)]  // 1
    [InlineData(23, 0x35)]  // 5
    [InlineData(22, 0x36)]  // 6
    // specials
    [InlineData(51, 0x08)]  // backspace -> VK_BACK (typing-flow critical)
    [InlineData(117, 0x2E)] // forward delete -> VK_DELETE
    [InlineData(36, 0x0D)]  // return
    [InlineData(48, 0x09)]  // tab
    [InlineData(53, 0x1B)]  // esc
    [InlineData(49, 0x20)]  // space
    // arrows
    [InlineData(123, 0x25)] // left
    [InlineData(124, 0x27)] // right
    [InlineData(126, 0x26)] // up
    [InlineData(125, 0x28)] // down
    // function keys
    [InlineData(122, 0x70)] // F1
    [InlineData(111, 0x7B)] // F12
    // punctuation
    [InlineData(24, 0xBB)]  // '=' -> VK_OEM_PLUS
    [InlineData(27, 0xBD)]  // '-' -> VK_OEM_MINUS
    public void Maps_mac_vk_to_windows_vk(int macVk, int expectedWinVk)
    {
        Assert.Equal((ushort)expectedWinVk, KeyMap.ToWindowsVk(macVk));
    }

    [Fact]
    public void Unknown_keycode_returns_null()
    {
        Assert.Null(KeyMap.ToWindowsVk(9999));
    }

    [Theory]
    [InlineData(KeyMap.VK_LEFT, true)]
    [InlineData(KeyMap.VK_HOME, true)]
    [InlineData(KeyMap.VK_DELETE, true)]
    [InlineData(0x41, false)]  // 'A' is not extended
    public void Flags_extended_navigation_keys(ushort vk, bool expected)
    {
        Assert.Equal(expected, KeyMap.IsExtended(vk));
    }
}
