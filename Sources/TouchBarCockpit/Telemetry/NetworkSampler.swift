import Foundation
import Darwin
import SystemConfiguration

final class NetworkSampler {
    private var prevInBytes: UInt64 = 0
    private var prevOutBytes: UInt64 = 0
    private var prevTime: CFAbsoluteTime = 0
    private var lastProxyPoll: CFAbsoluteTime = 0
    private var cachedProxyActive: Bool = false

    struct Sample {
        let downBps: Double
        let upBps: Double
        let tailscaleActive: Bool
        let vpnActive: Bool
        let proxyActive: Bool
    }

    func sample() -> Sample {
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var tailscale = false
        var vpn = false

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr {
            defer { freeifaddrs(ifaddrPtr) }

            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = ptr {
                let ifa = cur.pointee
                let name = String(cString: ifa.ifa_name)
                let flags = Int32(ifa.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

                if let addr = ifa.ifa_addr {
                    let family = Int32(addr.pointee.sa_family)

                    // Link layer counters for physical/active network interfaces (en*, bridge*, etc.)
                    if family == AF_LINK, name.hasPrefix("en"), isUp, let data = ifa.ifa_data {
                        let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                        inBytes &+= UInt64(ifData.ifi_ibytes)
                        outBytes &+= UInt64(ifData.ifi_obytes)
                    }

                    // Detect Tailscale (100.64.0.0/10 CGNAT on utun*) or other active VPN (IPv4 on utun*)
                    if family == AF_INET, name.hasPrefix("utun"), isUp {
                        let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
                        let octet1 = (ip >> 24) & 0xFF
                        let octet2 = (ip >> 16) & 0xFF
                        if octet1 == 100 && (octet2 >= 64 && octet2 <= 127) {
                            tailscale = true
                        } else if octet1 != 127 && octet1 != 169 {
                            vpn = true
                        }
                    }
                }

                ptr = ifa.ifa_next
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        var downBps = 0.0
        var upBps = 0.0

        if prevTime > 0 {
            let dt = now - prevTime
            if dt > 0.1 {
                if inBytes >= prevInBytes {
                    downBps = Double(inBytes - prevInBytes) / dt
                }
                if outBytes >= prevOutBytes {
                    upBps = Double(outBytes - prevOutBytes) / dt
                }
            }
        }

        prevInBytes = inBytes
        prevOutBytes = outBytes
        prevTime = now

        if (now - lastProxyPoll) >= 3.0 || lastProxyPoll == 0 {
            cachedProxyActive = Self.isSystemProxyEnabled()
            lastProxyPoll = now
        }

        return Sample(
            downBps: downBps,
            upBps: upBps,
            tailscaleActive: tailscale,
            vpnActive: vpn,
            proxyActive: cachedProxyActive
        )
    }

    private static func isSystemProxyEnabled() -> Bool {
        guard let cfDict = SCDynamicStoreCopyProxies(nil),
              let dict = cfDict as? [String: Any] else {
            return false
        }
        let http = (dict[kSCPropNetProxiesHTTPEnable as String] as? Int ?? 0) == 1
        let https = (dict[kSCPropNetProxiesHTTPSEnable as String] as? Int ?? 0) == 1
        let socks = (dict[kSCPropNetProxiesSOCKSEnable as String] as? Int ?? 0) == 1
        return http || https || socks
    }
}
