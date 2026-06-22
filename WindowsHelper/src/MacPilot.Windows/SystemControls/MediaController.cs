using MacPilot.Windows.Input;

namespace MacPilot.Windows.SystemControls;

/// <summary>
/// Volume control via the standard media virtual keys (raises the native Windows volume OSD, needs
/// no admin) — the closest analog to the macOS native HUD. Mirrors MediaKeys.swift volume cases.
/// </summary>
public static class MediaController
{
    public const ushort VK_VOLUME_MUTE = 0xAD, VK_VOLUME_DOWN = 0xAE, VK_VOLUME_UP = 0xAF;

    public static void Volume(string? dir)
    {
        ushort? vk = dir switch
        {
            "up" => VK_VOLUME_UP,
            "down" => VK_VOLUME_DOWN,
            "mute" => VK_VOLUME_MUTE,
            _ => null,
        };
        if (vk is { } v)
            Win32Native.Send(Win32Native.KeyEvent(v, keyUp: false), Win32Native.KeyEvent(v, keyUp: true));
    }
}
