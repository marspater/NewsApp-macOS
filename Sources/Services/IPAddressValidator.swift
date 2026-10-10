import Foundation
import Darwin

/// Validates IP addresses, hostnames, and socket endpoints to protect against
/// SSRF (Server-Side Request Forgery), DNS rebinding, and private intranet probing.
struct IPAddressValidator: Sendable {

    enum ValidationResult: Equatable, Sendable {
        case allowed(ips: [String])
        case blocked(reason: String)
        case unresolvable(reason: String)
    }

    /// Comprehensive pre-flight check for a given hostname or IP string.
    /// Injected DNS results still follow the hostname and literal-address guards.
    static func validateHost(
        _ rawHost: String,
        resolver: (String) -> ValidationResult = resolveAndValidateHost
    ) -> ValidationResult {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        
        guard !host.contains("%"), !host.contains("\0") else { return .blocked(reason: "Scoped or malformed address") }

        // 1. Literal hostname checks
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return .blocked(reason: "Localhost or internal domain name")
        }
        
        // Single-label names may implicitly bypass native proxy routing.
        guard host.contains(".") || host.contains(":") else {
            return .blocked(reason: "Single-label network host")
        }

        // 2. Direct IP address check (if user provided literal IP)
        if let directBlockReason = checkLiteralIP(host) {
            return .blocked(reason: directBlockReason)
        }

        // 3. DNS Resolution check (resolves host and validates all resolved IP addresses)
        return resolver(host)
    }

    /// Checks whether an individual literal IP string (IPv4 or IPv6) is forbidden.
    static func checkLiteralIP(_ ipString: String) -> String? {
        if ipString.contains("%") { return "Scoped IP address" }
        var cleanIP = ipString
        if cleanIP.hasPrefix("[") && cleanIP.hasSuffix("]") {
            cleanIP = String(cleanIP.dropFirst().dropLast())
        }

        // Check IPv4
        var sin = in_addr()
        if inet_pton(AF_INET, cleanIP, &sin) == 1 {
            return isBlockedIPv4(sin)
        }

        // Check IPv6
        var sin6 = in6_addr()
        if inet_pton(AF_INET6, cleanIP, &sin6) == 1 {
            return isBlockedIPv6(sin6)
        }

        return nil
    }

    /// Validates an active socket address (e.g. from URLSessionTaskMetrics) for diagnostics; connection-time enforcement uses validated numeric endpoints.
    static func validateSocketAddress(_ sockaddrPtr: UnsafePointer<sockaddr>) -> String? {
        switch sockaddrPtr.pointee.sa_family {
        case UInt8(AF_INET):
            let sin = sockaddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            return isBlockedIPv4(sin.sin_addr)
        case UInt8(AF_INET6):
            let sin6 = sockaddrPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            return isBlockedIPv6(sin6.sin6_addr)
        default:
            return nil
        }
    }

    // MARK: - DNS Resolution Engine

    private static func resolveAndValidateHost(_ host: String) -> ValidationResult {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &res)
        guard status == 0, let firstAddr = res else {
            let errorMsg = String(cString: gai_strerror(status))
            return .unresolvable(reason: errorMsg)
        }
        defer { freeaddrinfo(res) }

        var resolvedIPs = [String]()
        var current: UnsafeMutablePointer<addrinfo>? = firstAddr

        while let ptr = current {
            if let aiAddr = ptr.pointee.ai_addr {
                let family = ptr.pointee.ai_family
                var ipBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

                if family == AF_INET {
                    let sin = aiAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    if let reason = isBlockedIPv4(sin.sin_addr) {
                        return .blocked(reason: reason)
                    }
                    var addr = sin.sin_addr
                    inet_ntop(AF_INET, &addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                    resolvedIPs.append(ipBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
                } else if family == AF_INET6 {
                    let sin6 = aiAddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    if let reason = isBlockedIPv6(sin6.sin6_addr) {
                        return .blocked(reason: reason)
                    }
                    var addr6 = sin6.sin6_addr
                    inet_ntop(AF_INET6, &addr6, &ipBuffer, socklen_t(INET6_ADDRSTRLEN))
                    resolvedIPs.append(ipBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
                }
            }
            current = ptr.pointee.ai_next
        }

        if resolvedIPs.isEmpty {
            return .unresolvable(reason: "No valid addresses resolved")
        }

        return .allowed(ips: resolvedIPs)
    }

    // MARK: - IPv4 Filtering

    static func isBlockedIPv4(_ inAddr: in_addr) -> String? {
        let ip = inAddr.s_addr.bigEndian

        let b1 = UInt8((ip >> 24) & 0xFF)
        let b2 = UInt8((ip >> 16) & 0xFF)
        let b3 = UInt8((ip >> 8) & 0xFF)

        // 127.0.0.0/8 — Loopback
        if b1 == 127 { return "IPv4 loopback address (127.0.0.0/8)" }

        // 0.0.0.0/8 — Current network
        if b1 == 0 { return "IPv4 current network (0.0.0.0/8)" }

        // 10.0.0.0/8 — RFC 1918 Private
        if b1 == 10 { return "RFC 1918 private network (10.0.0.0/8)" }

        // 172.16.0.0/12 — RFC 1918 Private
        if b1 == 172 && (b2 >= 16 && b2 <= 31) { return "RFC 1918 private network (172.16.0.0/12)" }

        // 192.168.0.0/16 — RFC 1918 Private
        if b1 == 192 && b2 == 168 { return "RFC 1918 private network (192.168.0.0/16)" }

        // 169.254.0.0/16 — Link-Local
        if b1 == 169 && b2 == 254 { return "Link-local address (169.254.0.0/16)" }

        // 100.64.0.0/10 — Carrier-Grade NAT
        if b1 == 100 && (b2 >= 64 && b2 <= 127) { return "Carrier-grade NAT (100.64.0.0/10)" }

        if b1 == 192 && b2 == 0 && (b3 == 0 || b3 == 2) { return "IPv4 protocol/documentation network" }
        if b1 == 192 && b2 == 88 && b3 == 99 { return "IPv4 transition network" }
        if b1 == 198 && (b2 == 18 || b2 == 19) { return "IPv4 benchmarking network" }
        if (b1 == 198 && b2 == 51 && b3 == 100) || (b1 == 203 && b2 == 0 && b3 == 113) { return "IPv4 documentation network" }

        // 224.0.0.0/4 — Multicast
        if b1 >= 224 && b1 <= 239 { return "Multicast address (224.0.0.0/4)" }

        // 240.0.0.0/4 & 255.255.255.255 — Reserved/Broadcast
        if b1 >= 240 { return "Reserved/broadcast address" }

        return nil
    }

    // MARK: - IPv6 Filtering

    private static func isBlockedIPv6(_ in6: in6_addr) -> String? {
        let bytes = Mirror(reflecting: in6.__u6_addr.__u6_addr8).children.compactMap { $0.value as? UInt8 }
        guard bytes.count == 16 else { return "Malformed IPv6" }

        // ::1 — Loopback
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return "IPv6 loopback (::1)"
        }

        // :: — Unspecified
        if bytes.allSatisfy({ $0 == 0 }) {
            return "IPv6 unspecified address (::)"
        }

        // fe80::/10 — Link-Local
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 {
            return "IPv6 link-local address (fe80::/10)"
        }

        // fc00::/7 — Unique Local Address (ULA)
        if (bytes[0] & 0xfe) == 0xfc {
            return "IPv6 unique local address (fc00::/7)"
        }

        // ff00::/8 — Multicast
        if bytes[0] == 0xff {
            return "IPv6 multicast address (ff00::/8)"
        }

        // ::ffff:0:0/96 — IPv4-mapped IPv6
        let isIPv4Mapped = bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff
        if isIPv4Mapped {
            var v4Sin = in_addr()
            let v4Bytes: [UInt8] = Array(bytes[12..<16])
            v4Sin.s_addr = (UInt32(v4Bytes[0]) << 24 |
                            UInt32(v4Bytes[1]) << 16 |
                            UInt32(v4Bytes[2]) << 8  |
                            UInt32(v4Bytes[3])).bigEndian
            if let reason = isBlockedIPv4(v4Sin) {
                return "IPv4-mapped IPv6 (\(reason))"
            }
        }

        // 64:ff9b::/96 — NAT64 Prefix
        let isNAT64 = bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4..<12].allSatisfy({ $0 == 0 })
        if isNAT64 {
            var v4Sin = in_addr()
            let v4Bytes: [UInt8] = Array(bytes[12..<16])
            v4Sin.s_addr = (UInt32(v4Bytes[0]) << 24 |
                            UInt32(v4Bytes[1]) << 16 |
                            UInt32(v4Bytes[2]) << 8  |
                            UInt32(v4Bytes[3])).bigEndian
            if let reason = isBlockedIPv4(v4Sin) {
                return "NAT64 IPv6 (\(reason))"
            }
        }

        if isIPv4Mapped || isNAT64 { return nil }
        // Refuse transition mechanisms that can embed a separately routed IPv4 destination.
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return "6to4 transition address" }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0 { return "Teredo transition address" }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return "IPv6 documentation address" }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2 { return "IPv6 special-purpose network" }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return "IPv6 documentation address" }
        guard bytes[0] & 0xe0 == 0x20 else { return "Non-global IPv6 address" }
        return nil
    }
}
