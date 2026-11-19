import Darwin
import Foundation
import SystemConfiguration

struct NetworkSample: Identifiable, Equatable {
    enum Kind: String {
        case wifi = "Wi-Fi"
        case ethernet = "Ethernet"
        case vpn = "VPN"
        case cellular = "Cellular"
        case other = "Network"
    }

    var id: String           // BSD name, e.g. "en0"
    var displayName: String  // e.g. "Wi-Fi"
    var kind: Kind
    var receiveRate: Double = 0  // bytes/s
    var sendRate: Double = 0     // bytes/s
    var linkSpeed: UInt64 = 0    // bits/s, 0 when unknown
    var ipv4: [String] = []
    var ipv6: [String] = []
    var totalReceived: UInt64 = 0
    var totalSent: UInt64 = 0

    var throughputBits: Double { (receiveRate + sendRate) * 8 }
    var utilization: Double? {
        guard linkSpeed > 0 else { return nil }
        return min(100, throughputBits / Double(linkSpeed) * 100)
    }
}

/// Per-interface throughput from the routing socket's 64-bit counters
/// (`NET_RT_IFLIST2`). `getifaddrs` only exposes 32-bit counters that wrap at 4 GB.
final class NetworkSampler {
    private struct Counters {
        var received: UInt64
        var sent: UInt64
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var namesCache: [String: (String, NetworkSample.Kind)] = [:]
    private var namesStamp: Date = .distantPast

    func sample() -> [NetworkSample] {
        let now = MachTime.now()
        let elapsed = previousTime > 0 ? Double(now - previousTime) / 1_000_000_000 : 0
        let counters = readCounters()
        let addresses = readAddresses()
        refreshNamesIfNeeded()

        var result: [NetworkSample] = []
        for (name, entry) in counters {
            let (received, sent, speed, flags) = entry
            guard flags & UInt32(IFF_LOOPBACK) == 0, flags & UInt32(IFF_UP) != 0 else { continue }
            let addrs = addresses[name] ?? ([], [])
            let isTunnel = name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            let known = namesCache[name]
            // Show adapters the system knows about and that are connected, plus VPN tunnels with an IPv4 address.
            guard (known != nil && !(addrs.0.isEmpty && addrs.1.isEmpty)) || (isTunnel && !addrs.0.isEmpty) else { continue }

            var sample = NetworkSample(
                id: name,
                displayName: known?.0 ?? (isTunnel ? "VPN" : name),
                kind: known?.1 ?? (isTunnel ? .vpn : .other)
            )
            sample.linkSpeed = speed
            sample.ipv4 = addrs.0
            sample.ipv6 = addrs.1
            sample.totalReceived = received
            sample.totalSent = sent
            if let before = previous[name], elapsed > 0 {
                sample.receiveRate = received >= before.received ? Double(received - before.received) / elapsed : 0
                sample.sendRate = sent >= before.sent ? Double(sent - before.sent) / elapsed : 0
            }
            result.append(sample)
        }

        previous = counters.mapValues { Counters(received: $0.0, sent: $0.1) }
        previousTime = now
        return result.sorted { lhs, rhs in
            if lhs.kind == .vpn, rhs.kind != .vpn { return false }
            if rhs.kind == .vpn, lhs.kind != .vpn { return true }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    // MARK: - Counters

    private func readCounters() -> [String: (UInt64, UInt64, UInt64, UInt32)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (UInt64, UInt64, UInt64, UInt32)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        result[name] = (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes,
                                        UInt64(info.ifm_data.ifi_baudrate), UInt32(bitPattern: info.ifm_flags))
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    private func readAddresses() -> [String: ([String], [String])] {
        var result: [String: ([String], [String])] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            var pair = result[name] ?? ([], [])
            if family == AF_INET {
                pair.0.append(text)
            } else if !text.hasPrefix("fe80") {
                pair.1.append(text.components(separatedBy: "%").first ?? text)
            }
            result[name] = pair
        }
        return result
    }

    // MARK: - Friendly names

    private func refreshNamesIfNeeded() {
        guard Date().timeIntervalSince(namesStamp) > 30 else { return }
        namesStamp = Date()
        var names: [String: (String, NetworkSample.Kind)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String? ?? ""
                let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd
                let kind: NetworkSample.Kind
                if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                    kind = .wifi
                } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                    kind = display.localizedCaseInsensitiveContains("thunderbolt bridge") ? .other : .ethernet
                } else if type == (kSCNetworkInterfaceTypeWWAN as String) {
                    kind = .cellular
                } else {
                    kind = .other
                }
                names[bsd] = (display, kind)
            }
        }
        namesCache = names
    }
}
