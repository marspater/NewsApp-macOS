import Foundation
import Network

/// The only socket gateway used by in-app HTTP clients. TLS stays end-to-end with the client.
actor NetworkBoundaryProxy {
    static let shared = NetworkBoundaryProxy()
    typealias Connector = @Sendable (NWEndpoint.Host, NWEndpoint.Port) -> NWConnection
    typealias Resolver = @Sendable (String) -> IPAddressValidator.ValidationResult
    private let resolver: Resolver
    private let connector: Connector
    private var startup: Task<SOCKSListener, Error>?

    init(resolver: @escaping Resolver = { IPAddressValidator.validateHost($0) },
         connector: @escaping Connector = { NWConnection(host: $0, port: $1, using: .tcp) }) {
        self.resolver = resolver
        self.connector = connector
    }

    func port() async throws -> UInt16 {
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
        do { return try await task.value.port }
        catch { if startup == task { startup = nil }; throw error }
    }

    func configuration() async throws -> ProxyConfiguration {
        let port = try await port()
        var configuration = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        configuration.allowFailover = false
        configuration.matchDomains = [""]
        configuration.excludedDomains = []
        return configuration
    }

    func stop() async {
        let task = startup
        startup = nil
        task?.cancel()
        if let server = try? await task?.value { server.stop() }
    }
}

// Bound blocking native DNS work independently of the number of queued/expired clients.
private actor ProxyResolver {
    let body: NetworkBoundaryProxy.Resolver
    init(body: @escaping NetworkBoundaryProxy.Resolver) { self.body = body }
    func resolve(_ host: String) -> IPAddressValidator.ValidationResult {
        guard !Task.isCancelled else { return .unresolvable(reason: "Cancelled") }
        return body(host)
    }
}

private final class SOCKSListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.marspater.news.network-boundary")
    private let resolver: ProxyResolver
    private let connector: NetworkBoundaryProxy.Connector
    private var tunnels: [UUID: SOCKSTunnel] = [:] // Accessed only on queue.
    var port: UInt16 { listener.port!.rawValue }

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
                case .failed(let error): self?.stop(); complete(.failure(error))
                case .cancelled: complete(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.tunnels.count < 64 else { connection.cancel(); return }
                let id = UUID()
                let tunnel = SOCKSTunnel(client: connection, queue: self.queue, resolver: self.resolver, connector: self.connector) { [weak self] in
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
        if Task.isCancelled { stop(); throw CancellationError() }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            let active = Array(tunnels.values)
            active.forEach { $0.finish() }
        }
    }
}

private final class CompletionOnce: @unchecked Sendable {
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
    private let queue: DispatchQueue
    private let resolver: ProxyResolver
    private let connector: NetworkBoundaryProxy.Connector
    private let onFinish: @Sendable () -> Void
    private var timeout: DispatchSourceTimer?
    private var resolving: Task<Void, Never>?
    private var finished = false
    private var closedDirections = 0

    init(client: NWConnection, queue: DispatchQueue, resolver: ProxyResolver,
         connector: @escaping NetworkBoundaryProxy.Connector, onFinish: @escaping @Sendable () -> Void) {
        self.client = client; self.queue = queue; self.resolver = resolver; self.connector = connector; self.onFinish = onFinish
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.finish() }
        timer.schedule(deadline: .now() + 15)
        timer.resume()
        timeout = timer
        client.start(queue: queue)
        read(2) { [weak self] greeting in
            guard let self, let greeting, greeting[0] == 5, greeting[1] > 0 else { self?.finish(); return }
            self.readMethods(Int(greeting[1]))
        }
    }

    private func readMethods(_ count: Int) {
        read(count) { [weak self] methods in
            guard let self, let methods, methods.contains(0) else { self?.finish(); return }
            self.client.send(content: Data([5, 0]), completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { self?.finish(); return }
                self.readRequest()
            })
        }
    }

    private func read(_ count: Int, accumulated: Data = Data(), completion: @escaping @Sendable (Data?) -> Void) {
        guard !finished else { completion(nil); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] data, _, eof, error in
            guard let self, !self.finished, error == nil else { completion(nil); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if bytes.count == count { completion(bytes) }
            else if eof { completion(nil) }
            else { self.read(count, accumulated: bytes, completion: completion) }
        }
    }

    private func readRequest() {
        read(4) { [weak self] header in self?.handleRequestHeader(header) }
    }

    private func handleRequestHeader(_ header: Data?) {
        guard let header, header[0] == 5, header[1] == 1, header[2] == 0 else { reject(); return }
        switch header[3] {
        case 1:
            read(4) { [weak self] bytes in self?.readPort(host: bytes.flatMap { IPv4Address($0)?.debugDescription }) }
        case 4:
            read(16) { [weak self] bytes in self?.readPort(host: bytes.flatMap { IPv6Address($0)?.debugDescription }) }
        case 3:
            read(1) { [weak self] length in
                guard let self, let length, length[0] > 0 else { self?.reject(); return }
                self.read(Int(length[0])) { [weak self] bytes in
                    guard let bytes, let host = String(data: bytes, encoding: .utf8) else { self?.reject(); return }
                    self?.readPort(host: host)
                }
            }
        default: reject()
        }
    }

    private func readPort(host: String?) {
        guard let host, !host.isEmpty, !host.contains("%"), !host.contains("\0"),
              host == host.trimmingCharacters(in: .whitespacesAndNewlines) else { reject(); return }
        read(2) { [weak self] bytes in
            guard let self, let bytes else { self?.reject(); return }
            let port = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            guard [80, 443, 8080, 8443].contains(port) else { self.reject(); return }
            self.resolve(host: host, port: port)
        }
    }

    private static func isPublicAddress(_ address: String) -> Bool {
        IPAddressValidator.checkLiteralIP(address) == nil &&
            (IPv4Address(address) != nil || IPv6Address(address) != nil) && !address.contains("%")
    }

    private func resolve(host: String, port: UInt16) {
        let resolver = self.resolver
        resolving = Task.detached { [weak self] in
            let result = await resolver.resolve(host)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self, !self.finished else { return }
                guard case .allowed(let addresses) = result, !addresses.isEmpty,
                      addresses.allSatisfy(Self.isPublicAddress) else { self.reject(); return }
                self.connect(addresses: addresses[...], port: port)
            }
        }
    }

    private func connect(addresses: ArraySlice<String>, port: UInt16) {
        guard !finished, let address = addresses.first else { reject(); return }
        let host: NWEndpoint.Host
        if let ipv4 = IPv4Address(address) { host = .ipv4(ipv4) }
        else if let ipv6 = IPv6Address(address) { host = .ipv6(ipv6) }
        else { reject(); return }
        let connection = connector(host, NWEndpoint.Port(rawValue: port)!)
        upstream = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.finished, self.upstream === connection else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                self.client.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else { self?.finish(); return }
                    self.touch()
                    self.relay(from: self.client, to: connection)
                    self.relay(from: connection, to: self.client)
                })
            case .failed, .waiting:
                connection.stateUpdateHandler = nil
                connection.cancel()
                self.connect(addresses: addresses.dropFirst(), port: port)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func touch() { timeout?.schedule(deadline: .now() + 90) }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        guard !finished else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, eof, error in
            guard let self, !self.finished, error == nil else { self?.finish(); return }
            self.touch()
            destination.send(content: data, isComplete: eof, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { self?.finish(); return }
                if eof {
                    self.closedDirections += 1
                    if self.closedDirections == 2 { self.finish() }
                    return // Preserve half-close until response bytes in the other direction drain.
                }
                self.relay(from: source, to: destination)
            })
        }
    }

    private func reject() {
        guard !finished else { return }
        // Half-close after the reply and drain until the client closes. Cancelling while request
        // bytes are still unread makes TCP send RST, which can discard the reply before it is read.
        // The handshake timeout still bounds a client that never closes.
        client.send(content: Data([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { self?.finish(); return }
            self.drain()
        })
    }

    private func drain() {
        guard !finished else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, eof, error in
            guard let self, !eof, error == nil else { self?.finish(); return }
            self.drain()
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timeout?.cancel(); timeout = nil
        resolving?.cancel(); resolving = nil
        client.cancel(); upstream?.cancel(); upstream = nil
        onFinish()
    }
}
