using System.Collections.Concurrent;
using MacPilot.Windows.Commands;
using MacPilot.Windows.Input;

namespace MacPilot.Windows.Tests;

/// <summary>Records calls instead of moving the real cursor — used for headless integration tests.</summary>
internal sealed class FakeInjector : IInputInjector
{
    public ConcurrentQueue<string> Calls { get; } = new();
    public int ReleaseAllCount;

    public void Move(double dx, double dy) => Calls.Enqueue($"move:{dx},{dy}");
    public void Down(bool right, int count) => Calls.Enqueue($"down:{right},{count}");
    public void Up() => Calls.Enqueue("up");
    public void Click(bool right, int count) => Calls.Enqueue($"click:{right},{count}");
    public void Scroll(double dx, double dy) => Calls.Enqueue($"scroll:{dx},{dy}");
    public void Key(int macKeyCode, IReadOnlyList<string>? mods) => Calls.Enqueue($"key:{macKeyCode}");
    public void Text(string text) => Calls.Enqueue($"text:{text}");
    public void Macro(IReadOnlyList<MacroStep> steps) => Calls.Enqueue($"macro:{steps.Count}");
    public void Launch(string target) => Calls.Enqueue($"launch:{target}");
    public void Gesture(string dir) => Calls.Enqueue($"gesture:{dir}");
    public void Zoom(string dir) => Calls.Enqueue($"zoom:{dir}");
    public void Volume(string dir) => Calls.Enqueue($"volume:{dir}");
    public void Brightness(string dir) => Calls.Enqueue($"brightness:{dir}");
    public void ReleaseAll() => Interlocked.Increment(ref ReleaseAllCount);
}
