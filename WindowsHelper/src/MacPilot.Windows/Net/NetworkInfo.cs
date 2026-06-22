using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace MacPilot.Windows.Net;

/// <summary>
/// Computes the LAN connect address to show the phone, mirroring NetworkInfo.swift. Prefers a real
/// Up Ethernet/Wi-Fi adapter with a default gateway and filters out virtual adapters (Hyper-V,
/// WSL, VPN, VMware, VirtualBox) which otherwise sort first and would show an unreachable IP.
///
/// NOTE: Windows mDNS for "&lt;host&gt;.local" is unreliable without an mDNS responder, so the LAN IPv4
/// is the PRIMARY URL and ".local" is only a best-effort hint.
/// </summary>
public static class NetworkInfo
{
    private static readonly string[] VirtualHints =
        ["hyper-v", "vethernet", "virtual", "wsl", "vmware", "virtualbox", "vbox", "loopback", "tap", "tunnel", "pseudo"];

    /// <summary>Best LAN IPv4 to reach this PC, or null if none found.</summary>
    public static string? PrimaryIPv4()
    {
        var candidates = new List<(int score, string ip)>();

        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;

            var desc = (ni.Description + " " + ni.Name).ToLowerInvariant();
            bool looksVirtual = VirtualHints.Any(h => desc.Contains(h));

            var props = ni.GetIPProperties();
            bool hasGateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork
                                                              && !g.Address.Equals(IPAddress.Any));

            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var ip = ua.Address.ToString();
                if (ip.StartsWith("169.254") || ip.StartsWith("127.")) continue; // APIPA / loopback

                int score = 0;
                if (hasGateway) score += 100;
                if (!looksVirtual) score += 50;
                if (ni.NetworkInterfaceType is NetworkInterfaceType.Wireless80211) score += 10;
                if (ni.NetworkInterfaceType is NetworkInterfaceType.Ethernet) score += 8;
                candidates.Add((score, ip));
            }
        }

        return candidates.Count == 0 ? null : candidates.OrderByDescending(c => c.score).First().ip;
    }

    /// <summary>Best-effort mDNS-style hostname "&lt;computer&gt;.local" (may not resolve on all networks).</summary>
    public static string LocalHostName()
    {
        var name = Dns.GetHostName();
        return string.IsNullOrWhiteSpace(name) ? "localhost" : $"{name}.local";
    }
}
