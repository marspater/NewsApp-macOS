// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Network
import dnssd
import os

/// The only socket gateway used by in-app HTTP clients. TLS stays end-to-end with the client.
actor NetworkBoundaryProxy {
    static let shared = NetworkBoundaryProxy()
    typealias Connector = @Sendable (NWEndpoint.Host, NWEndpoint.Port) -> NWConnection
    /// Alternates address families, starting with the family of the first answer.
    nonisolated static func interleaved(_ addresses: [String]) -> [String] {
        var first = [String]()
        var second = [String]()
        let leadsIPv6 = addresses.first.map { IPv6Address($0) != nil } ?? false
        for address in addresses {
            if (IPv6Address(address) != nil) == leadsIPv6 { first.append(address) } else { second.append(address) }
        }
        var result = [String]()
        for index in 0..<max(first.count, second.count) {
            if index < first.count { result.append(first[index]) }
            if index < second.count { result.append(second[index]) }
        }
        return result
    }

    static let logger = Logger(subsystem: "com.marspater.news", category: "NetworkBoundaryProxy")

    /// Whether a connection that reports `.waiting` with this error is refused for good, so the next address (or a
    /// rejection) should follow at once. Any other waiting error may clear by itself (a saturated machine, a path
    /// change); the tunnel's handshake timeout bounds the wait and still fails closed (#769).
    /// The error's domain and numeric code, safe to log publicly; never a host or address.
    nonisolated static func logDescription(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix \(code.rawValue)"
        case .dns(let code): return "dns \(code)"
        case .tls(let code): return "tls \(code)"
        default: return "other"
        }
    }

    nonisolated static func waitingFailsAtOnce(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return [.ECONNREFUSED, .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EACCES, .EPERM].contains(code)
    }
    /// A test's synchronous answers; nil resolves through the system (`DNSLookup`).
    typealias Resolver = @Sendable (String) -> IPAddressValidator.ValidationResult
    private let resolver: Resolver?
    private let connector: Connector
    private var startup: Task<SOCKSListener, Error>?

    /// Upstream connections ask for no proxy (#929): the gateway must open every connection itself to the address it
    /// validated. `preferNoProxies` is a preference, so a connection a system proxy or PAC rule handled anyway is
    /// refused when its establishment report says so.
    static var directParameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        return parameters
    }

    nonisolated static func permitsUpstream(proxyConfigured: Bool?) -> Bool {
        proxyConfigured == false
    }

    init(
        resolver: Resolver? = nil,
        connector: @escaping Connector = { NWConnection(host: $0, port: $1, using: directParameters) }
    ) {
        self.resolver = resolver
        self.connector = connector
    }

    func port() async throws -> UInt16 {
        // A listener that stopped or failed after startup (for example across sleep) is replaced once.
        for _ in 0..<2 {
            if startup == nil {
                let resolver = resolver
                let connector = connector
                startup = Task {
                    let server = try SOCKSListener(resolver: ProxyResolver(body: resolver), connector: connector)
                    try await server.start()
                    return server
                }
            }
            guard let task = startup else { throw FeedError.network("Network gateway unavailable") }
            do {
                let server = try await task.value
                if let port = server.runningPort { return port }
                if startup == task { startup = nil }
            } catch {
                if startup == task { startup = nil }
                throw error
            }
        }
        throw FeedError.network("Network gateway unavailable")
    }

    func configuration() async throws -> ProxyConfiguration {
        Self.configuration(port: try await port())
    }

    static func configuration(port: UInt16) -> ProxyConfiguration {
        var configuration = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        configuration.allowFailover = false
        configuration.matchDomains = [""]
        configuration.excludedDomains = []
        return configuration
    }

    /// The running gateway's port, or nil before the first request and after it stopped; never starts one (#1006).
    func runningPort() async -> UInt16? {
        guard let startup else { return nil }
        return try? await startup.value.runningPort
    }

    /// The next `port()` call starts a new listener.
    func stop() async {
        let task = startup
        task?.cancel()
        if let server = try? await task?.value { server.stop() }
    }
}

/// Resolves and validates one host for the gateway and the preflight (#945). The system lookup is asynchronous and
/// cancellable, so no thread or worker is held, and every lookup ends inside `deadline`: cancelling the caller
/// resumes it at once and cancels the native query.
final class ProxyResolver: Sendable {
    typealias Lookup = @Sendable (String) async -> IPAddressValidator.ValidationResult
    /// Longer than a healthy answer by far, shorter than the request timeout that would otherwise absorb a hang.
    static let defaultDeadline: Duration = .seconds(5)
    /// Lookups the caller cancelled before they answered, for the diagnostics export (#1006).
    static let cancellations = OSAllocatedUnfairLock(initialState: 0)
    private let lookup: Lookup
    private let deadline: Duration

    /// `body` keeps a test's synchronous answers; production resolves through `DNSLookup`.
    init(body: NetworkBoundaryProxy.Resolver? = nil, deadline: Duration = defaultDeadline) {
        if let body {
            self.lookup = { body($0) }
        } else {
            self.lookup = { host in
                let (name, guarded) = IPAddressValidator.hostnameGuard(host)
                if let guarded { return guarded }
                return await DNSLookup.resolve(name)
            }
        }
        self.deadline = deadline
    }

    init(lookup: @escaping Lookup, deadline: Duration = defaultDeadline) {
        self.lookup = lookup
        self.deadline = deadline
    }

    func resolve(_ host: String) async -> IPAddressValidator.ValidationResult {
        guard !Task.isCancelled else {
            Self.cancellations.withLock { $0 += 1 }
            return .unresolvable(reason: "Cancelled")
        }
        let lookup = lookup
        let deadline = deadline
        return await withTaskGroup(of: IPAddressValidator.ValidationResult.self) { group in
            group.addTask { await lookup(host) }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                    return .unresolvable(reason: "Timed out")
                } catch {
                    return .unresolvable(reason: "Cancelled")
                }
            }
            let first = await group.next() ?? .unresolvable(reason: "Cancelled")
            group.cancelAll()
            if Task.isCancelled, first == .unresolvable(reason: "Cancelled") {
                Self.cancellations.withLock { $0 += 1 }
            }
            return first
        }
    }
}

/// The bookkeeping of one lookup, apart from dns_sd so a test can feed it callbacks: the validated addresses in
/// arrival order, the families seen in the open batch and the families that ended. A lookup is decided by a blocked
/// address, however late it arrives, or once both families have ended; a family that never answers leaves it to
/// `ProxyResolver`'s deadline, so a host is never allowed with one family unchecked.
struct DNSAnswer {
    private static let families: Set<Int32> = [AF_INET, AF_INET6]
    private var addresses: [String] = []
    private var seen: Set<Int32> = []
    private var ended: Set<Int32> = []

    /// One callback: `blocked` is the validator's reason for the address and `address` its text; -1 names no family.
    mutating func received(
        family: Int32, moreComing: Bool, error: DNSServiceErrorType, blocked: String?, address: String?
    ) -> IPAddressValidator.ValidationResult? {
        switch Int(error) {
        case kDNSServiceErr_NoError:
            if let blocked { return .blocked(reason: blocked) }
            if let address { addresses.append(address) }
            seen.insert(family)
            // The flag clears at the end of a batch, which may carry both families' addresses.
            return moreComing ? nil : familiesEnded(seen)
        case kDNSServiceErr_NoSuchRecord:
            return familiesEnded([family])
        default:
            return .unresolvable(reason: "dns \(error)")
        }
    }

    private mutating func familiesEnded(_ families: Set<Int32>) -> IPAddressValidator.ValidationResult? {
        ended.formUnion(families)
        guard Self.families.isSubset(of: ended) else { return nil }
        return addresses.isEmpty ? .noSuchHost : .allowed(ips: addresses)
    }
}

/// One system DNS lookup through dns_sd, answered address by address on a serial queue and validated as it arrives:
/// one blocked address fails the host closed. Both address families are queried and each ends with its last address
/// or with no record; the lookup answers once both have (`DNSAnswer`). Cancellation deallocates the query.
final class DNSLookup: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.marspater.news.dns")
    private var service: DNSServiceRef?
    private var continuation: CheckedContinuation<IPAddressValidator.ValidationResult, Never>?
    private var answer = DNSAnswer()
    /// Cancelled before the query started: a task already cancelled runs its cancellation handler first.
    private var cancelledBeforeStart = false

    static func resolve(_ host: String) async -> IPAddressValidator.ValidationResult {
        let lookup = DNSLookup()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { lookup.start(host, continuation) }
            }
        } onCancel: {
            queue.async { lookup.complete(.unresolvable(reason: "Cancelled")) }
        }
    }

    private func start(_ host: String, _ continuation: CheckedContinuation<IPAddressValidator.ValidationResult, Never>)
    {
        self.continuation = continuation
        if cancelledBeforeStart { return complete(.unresolvable(reason: "Cancelled")) }
        let reply: DNSServiceGetAddrInfoReply = { _, flags, _, error, _, address, _, context in
            guard let context else { return }
            Unmanaged<DNSLookup>.fromOpaque(context).takeUnretainedValue()
                .received(flags: flags, error: error, address: address)
        }
        // Both families are asked by name, so dns_sd owes an answer for each: addresses, or with intermediates a
        // family without records (or a name that does not exist) at once instead of staying silent. An address this
        // Mac cannot route fails its connect at once and the gateway moves to the next. The timeout flag ends an
        // unanswered query with kDNSServiceErr_Timeout.
        var ref: DNSServiceRef?
        let error = DNSServiceGetAddrInfo(
            &ref, DNSServiceFlags(kDNSServiceFlagsTimeout | kDNSServiceFlagsReturnIntermediates), 0,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host, reply,
            Unmanaged.passRetained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let ref else {
            Unmanaged.passUnretained(self).release()
            return complete(.unresolvable(reason: "dns \(error)"))
        }
        service = ref
        guard DNSServiceSetDispatchQueue(ref, Self.queue) == kDNSServiceErr_NoError else {
            return complete(.unresolvable(reason: "dns queue"))
        }
    }

    private func received(flags: DNSServiceFlags, error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard continuation != nil else { return }
        if Int(error) == kDNSServiceErr_NoError, address == nil { return }
        let result = answer.received(
            family: address.map { Int32($0.pointee.sa_family) } ?? -1,
            moreComing: flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0, error: error,
            blocked: address.flatMap(IPAddressValidator.validateSocketAddress),
            address: address.flatMap(IPAddressValidator.addressString))
        if let result { complete(result) }
    }

    /// Exactly once: deallocating the service cancels the query and stops its callbacks.
    private func complete(_ result: IPAddressValidator.ValidationResult) {
        guard let continuation else {
            cancelledBeforeStart = true
            return
        }
        self.continuation = nil
        if let service {
            DNSServiceRefDeallocate(service)
            self.service = nil
            Unmanaged.passUnretained(self).release()
        }
        continuation.resume(returning: result)
    }
}

private final class SOCKSListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.marspater.news.network-boundary")
    private let resolver: ProxyResolver
    private let connector: NetworkBoundaryProxy.Connector
    private var tunnels: [UUID: SOCKSTunnel] = [:]  // Accessed only on queue.
    private var isStopped = false  // Accessed only on queue.
    /// Nil once the listener has stopped or failed.
    var runningPort: UInt16? { queue.sync { isStopped ? nil : listener.port?.rawValue } }

    init(resolver: ProxyResolver, connector: @escaping NetworkBoundaryProxy.Connector) throws {
        self.resolver = resolver
        self.connector = connector
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = CompletionOnce()
            let complete: @Sendable (Result<Void, Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: complete(.success(()))
                case .failed(let error):
                    self?.stop()
                    complete(.failure(error))
                case .cancelled: complete(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.isStopped, self.tunnels.count < 64 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                let tunnel = SOCKSTunnel(
                    client: connection, queue: self.queue, resolver: self.resolver, connector: self.connector
                ) { [weak self] in
                    self?.tunnels.removeValue(forKey: id)
                }
                self.tunnels[id] = tunnel
                tunnel.start()
            }
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard once.claim() else { return }
                self?.stop()
                continuation.resume(throwing: FeedError.timeout)
            }
            listener.start(queue: queue)
        }
        if Task.isCancelled {
            stop()
            throw CancellationError()
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            guard !isStopped else { return }
            isStopped = true
            let active = Array(tunnels.values)
            tunnels.removeAll()
            for tunnel in active { tunnel.finish() }
        }
    }

    deinit {
        listener.cancel()
    }
}

final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func claim() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

/// Single serial queue owns each tunnel; at most one bounded buffer is in flight per direction.
private final class SOCKSTunnel: @unchecked Sendable {
    private let client: NWConnection
    private var upstream: NWConnection?
    /// Connections still trying, newest last; the first to become ready is the upstream and cancels the rest.
    private var attempts: [NWConnection] = []
    private var addresses: ArraySlice<String> = []
    private var port: UInt16 = 0
    private var nextAttempt: DispatchWorkItem?
    /// RFC 8305: the next address starts when the one before has not connected within this delay.
    static let attemptDelay: DispatchTimeInterval = .milliseconds(250)
    /// Attempts in flight per tunnel; a further address retires the oldest, so stalled attempts cannot hold every slot.
    static let maxAttempts = 3
    private let queue: DispatchQueue
    private let resolver: ProxyResolver
    private let connector: NetworkBoundaryProxy.Connector
    private let onFinish: @Sendable () -> Void
    private var timeout: DispatchSourceTimer?
    private var resolving: Task<Void, Never>?
    private var finished = false
    private var closedDirections = 0

    init(
        client: NWConnection, queue: DispatchQueue, resolver: ProxyResolver,
        connector: @escaping NetworkBoundaryProxy.Connector, onFinish: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.queue = queue
        self.resolver = resolver
        self.connector = connector
        self.onFinish = onFinish
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.finish() }
        timer.schedule(deadline: .now() + 15)
        timer.resume()
        timeout = timer
        client.start(queue: queue)
        read(2) { [weak self] greeting in
            guard let self, let greeting, greeting[0] == 5, greeting[1] > 0 else {
                self?.finish()
                return
            }
            self.readMethods(Int(greeting[1]))
        }
    }

    private func readMethods(_ count: Int) {
        read(count) { [weak self] methods in
            guard let self, let methods, methods.contains(0) else {
                self?.finish()
                return
            }
            self.client.send(
                content: Data([5, 0]),
                completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else {
                        self?.finish()
                        return
                    }
                    self.readRequest()
                })
        }
    }

    private func read(_ count: Int, accumulated: Data = Data(), completion: @escaping @Sendable (Data?) -> Void) {
        guard !finished else {
            completion(nil)
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) {
            [weak self] data, _, eof, error in
            guard let self, !self.finished, error == nil else {
                completion(nil)
                return
            }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if bytes.count == count {
                completion(bytes)
            } else if eof {
                completion(nil)
            } else {
                self.read(count, accumulated: bytes, completion: completion)
            }
        }
    }

    private func readRequest() {
        read(4) { [weak self] header in self?.handleRequestHeader(header) }
    }

    private func handleRequestHeader(_ header: Data?) {
        guard let header, header[0] == 5, header[1] == 1, header[2] == 0 else {
            reject()
            return
        }
        switch header[3] {
        case 1:
            read(4) { [weak self] bytes in self?.readPort(host: bytes.flatMap { IPv4Address($0)?.debugDescription }) }
        case 4:
            read(16) { [weak self] bytes in self?.readPort(host: bytes.flatMap { IPv6Address($0)?.debugDescription }) }
        case 3:
            read(1) { [weak self] length in
                guard let self, let length, length[0] > 0 else {
                    self?.reject()
                    return
                }
                self.read(Int(length[0])) { [weak self] bytes in
                    guard let bytes, let host = String(data: bytes, encoding: .utf8) else {
                        self?.reject()
                        return
                    }
                    self?.readPort(host: host)
                }
            }
        default: reject()
        }
    }

    private func readPort(host: String?) {
        guard let host, !host.isEmpty, !host.contains("%"), !host.contains("\0"),
            host == host.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            reject()
            return
        }
        read(2) { [weak self] bytes in
            guard let self, let bytes else {
                self?.reject()
                return
            }
            let port = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            guard [80, 443, 8080, 8443].contains(port) else {
                self.reject()
                return
            }
            self.resolve(host: host, port: port)
        }
    }

    private static func isPublicAddress(_ address: String) -> Bool {
        IPAddressValidator.checkLiteralIP(address) == nil
            && (IPv4Address(address) != nil || IPv6Address(address) != nil) && !address.contains("%")
    }

    private func resolve(host: String, port: UInt16) {
        let resolver = self.resolver
        resolving = Task.detached { [weak self] in
            let result = await resolver.resolve(host)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self, !self.finished else { return }
                guard case .allowed(let addresses) = result, !addresses.isEmpty,
                    addresses.allSatisfy(Self.isPublicAddress)
                else {
                    self.reject()
                    return
                }
                self.connect(addresses: addresses, port: port)
            }
        }
    }

    /// Happy Eyeballs (RFC 8305, #945): the families take turns, a further address starts after `attemptDelay`
    /// while none is ready, the first ready connection wins and every other attempt is cancelled. A dead first
    /// address (an IPv6 route that never answers) costs a quarter second, not the handshake timeout.
    private func connect(addresses: [String], port: UInt16) {
        self.addresses = NetworkBoundaryProxy.interleaved(addresses)[...]
        self.port = port
        startNextAttempt()
    }

    private func startNextAttempt() {
        nextAttempt?.cancel()
        nextAttempt = nil
        guard !finished, upstream == nil else { return }
        guard let address = addresses.popFirst() else {
            if attempts.isEmpty { reject() }
            return
        }
        let host: NWEndpoint.Host
        if let ipv4 = IPv4Address(address) {
            host = .ipv4(ipv4)
        } else if let ipv6 = IPv6Address(address) {
            host = .ipv6(ipv6)
        } else {
            startNextAttempt()
            return
        }
        if attempts.count >= Self.maxAttempts {
            let oldest = attempts.removeFirst()
            oldest.stateUpdateHandler = nil
            oldest.cancel()
        }
        let connection = connector(host, NWEndpoint.Port(rawValue: port)!)
        attempts.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.attempt(connection, changed: state)
        }
        connection.start(queue: queue)
        guard !addresses.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in self?.startNextAttempt() }
        nextAttempt = item
        queue.asyncAfter(deadline: .now() + Self.attemptDelay, execute: item)
    }

    private func attempt(_ connection: NWConnection, changed state: NWConnection.State) {
        guard !finished, upstream == nil, attempts.contains(where: { $0 === connection }) else { return }
        let port = port
        switch state {
        case .ready:
            upstream = connection
            nextAttempt?.cancel()
            nextAttempt = nil
            for other in attempts where other !== connection {
                other.stateUpdateHandler = nil
                other.cancel()
            }
            attempts = []
            addresses = []
            connection.stateUpdateHandler = nil
            // Fail closed on a proxied connection: a system proxy or PAC rule would have resolved and connected in
            // the gateway's place, so the destination is no longer the validated one (#929).
            connection.requestEstablishmentReport(queue: queue) { [weak self] report in
                guard let self, !self.finished, self.upstream === connection else { return }
                guard NetworkBoundaryProxy.permitsUpstream(proxyConfigured: report?.proxyConfigured) else {
                    NetworkBoundaryProxy.logger.error(
                        "Upstream port \(port, privacy: .public) refused: proxy status is not verified direct")
                    self.reject()
                    return
                }
                self.relayThroughUpstream(connection)
            }
        case .failed(let error):
            let reason = NetworkBoundaryProxy.logDescription(error)
            NetworkBoundaryProxy.logger.error(
                "Upstream connect to port \(port, privacy: .public) failed: \(reason, privacy: .public)")
            drop(connection)
        case .waiting(let error):
            let reason = NetworkBoundaryProxy.logDescription(error)
            guard NetworkBoundaryProxy.waitingFailsAtOnce(error) else {
                // May resolve to .ready or .failed; the next address starts meanwhile and the handshake timeout
                // ends a connect that never does.
                NetworkBoundaryProxy.logger.notice(
                    "Upstream connect to port \(port, privacy: .public) is waiting: \(reason, privacy: .public)")
                return
            }
            NetworkBoundaryProxy.logger.error(
                "Upstream connect to port \(port, privacy: .public) refused: \(reason, privacy: .public)")
            drop(connection)
        default: break
        }
    }

    private func drop(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        attempts.removeAll { $0 === connection }
        startNextAttempt()
    }

    private func touch() { timeout?.schedule(deadline: .now() + 90) }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        guard !finished else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, eof, error in
            guard let self, !self.finished, error == nil else {
                self?.finish()
                return
            }
            self.touch()
            destination.send(
                content: data, contentContext: eof ? .finalMessage : .defaultMessage,
                completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else {
                        self?.finish()
                        return
                    }
                    if eof {
                        self.closedDirections += 1
                        if self.closedDirections == 2 { self.finish() }
                        return  // Preserve half-close until response bytes in the other direction drain.
                    }
                    self.relay(from: source, to: destination)
                })
        }
    }

    /// The SOCKS success reply, then bytes flow both ways.
    private func relayThroughUpstream(_ connection: NWConnection) {
        client.send(
            content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]),
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    self?.finish()
                    return
                }
                self.touch()
                self.relay(from: self.client, to: connection)
                self.relay(from: connection, to: self.client)
            })
    }

    private func reject() {
        guard !finished else { return }
        // Half-close after the reply and drain until the client closes. Cancelling while request
        // bytes are still unread makes TCP send RST, which can discard the reply before it is read.
        // The handshake timeout still bounds a client that never closes.
        client.send(
            content: Data([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    self?.finish()
                    return
                }
                self.drain()
            })
    }

    private func drain() {
        guard !finished else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, eof, error in
            guard let self, !eof, error == nil else {
                self?.finish()
                return
            }
            self.drain()
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        resolving?.cancel()
        resolving = nil
        nextAttempt?.cancel()
        nextAttempt = nil
        client.cancel()
        for attempt in attempts {
            attempt.stateUpdateHandler = nil
            attempt.cancel()
        }
        attempts = []
        upstream?.cancel()
        upstream = nil
        onFinish()
    }
}
