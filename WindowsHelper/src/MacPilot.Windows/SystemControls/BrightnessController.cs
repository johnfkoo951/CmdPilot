using System.Diagnostics;

namespace MacPilot.Windows.SystemControls;

/// <summary>
/// Best-effort screen brightness via WMI (root\WMI WmiMonitorBrightnessMethods.WmiSetBrightness).
/// KNOWN LIMITATION: this only works on displays that expose the WMI brightness interface — typically
/// internal laptop/all-in-one panels. Most desktops with external monitors will fail (they need DDC/CI,
/// which many monitors disable). On any failure this no-ops gracefully and never throws.
///
/// Implemented by shelling to PowerShell's CIM cmdlets to AVOID adding the System.Management NuGet
/// dependency (keeping the runtime dependency-free). Slower than a P/Invoke, acceptable for a
/// rarely-hammered, explicitly best-effort feature. Marked "partial / manual-verify" in the docs.
/// </summary>
public static class BrightnessController
{
    public static void Adjust(string? dir)
    {
        int delta = dir switch { "up" => 10, "down" => -10, _ => 0 };
        if (delta == 0) return;

        // Read current brightness, clamp ±delta, set it — all in one short-lived PowerShell call.
        string script =
            "$ErrorActionPreference='SilentlyContinue';" +
            "$b=(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness);" +
            "if($b){$cur=$b.CurrentBrightness;" +
            $"$n=[Math]::Max(0,[Math]::Min(100,$cur+({delta})));" +
            "$m=(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods);" +
            "Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{Timeout=1;Brightness=$n}|Out-Null}";

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -Command \"" + script + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var _ = Process.Start(psi);
        }
        catch
        {
            // Best-effort: brightness genuinely unsupported on this device. Stay silent.
        }
    }
}
