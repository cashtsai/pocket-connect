import Darwin
import Foundation

// Builds the Device.hostCandidates list (design §3.1): ordered best-first —
// tailnet, then LAN, then the public tunnel URL. The phone walks this list and
// direct-connects to the first reachable bridge; CloudKit never relays traffic.
public enum HostCandidates {
    /// - Parameters:
    ///   - bridgePort: local bridge port (candidates point straight at it).
    ///   - tunnelURL: public tunnel base URL from Config.connectURL, appended last.
    public static func gather(bridgePort: Int, tunnelURL: String?) -> [String] {
        var tailnet: [String] = []
        var lan: [String] = []
        for ip in localIPv4Addresses() {
            if isTailnetIP(ip) {
                tailnet.append("http://\(ip):\(bridgePort)")
            } else if isPrivateIP(ip) {
                lan.append("http://\(ip):\(bridgePort)")
            }
        }
        var out = tailnet + lan
        if let tunnelURL, !tunnelURL.isEmpty { out.append(tunnelURL) }
        return out
    }

    /// Tailscale assigns addresses from the CGNAT range 100.64.0.0/10.
    static func isTailnetIP(_ ip: String) -> Bool {
        guard let o = octets(ip) else { return false }
        return o[0] == 100 && (64...127).contains(o[1])
    }

    /// RFC1918 private ranges → LAN candidates.
    static func isPrivateIP(_ ip: String) -> Bool {
        guard let o = octets(ip) else { return false }
        if o[0] == 10 { return true }
        if o[0] == 172, (16...31).contains(o[1]) { return true }
        if o[0] == 192, o[1] == 168 { return true }
        return false
    }

    private static func octets(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return parts
    }

    private static func localIPv4Addresses() -> [String] {
        var addrs: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return addrs }
        defer { freeifaddrs(head) }
        var ptr = head
        while let ifa = ptr?.pointee {
            defer { ptr = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sin.sin_addr
            if inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                addrs.append(String(cString: buf))
            }
        }
        return addrs
    }
}
