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
import Testing

extension NativeSuites {
    /// `NewsTests.socksConnect`, recording its greeting check through Swift Testing instead of the runner's log: a
    /// wrong greeting followed by a working tunnel would otherwise pass in the native bundle.
    static func socksConnect(_ proxy: NetworkBoundaryProxy, host: String, command: UInt8 = 1, port: UInt16 = 80)
        async throws -> (NWConnection, Data)
    {
        let endpoint: UInt16
        do { endpoint = try await proxy.port() } catch {
            throw NewsTests.loopbackFailure("listener start (NetworkBoundaryProxy, port .any)", error)
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint)!, using: .tcp)
        // A loopback connect can fail with EADDRINUSE when parallel runs churn ephemeral ports. NWConnection
        // then parks in .waiting and never completes a send, so surface that state instead of hanging.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = NewsTests.SocketObservation()
                client.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.claim() { continuation.resume() }
                    case .waiting(let error), .failed(let error):
                        if once.claim() { continuation.resume(throwing: error) }
                    case .cancelled: if once.claim() { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                client.start(queue: .global())
            }
        } catch {
            client.stateUpdateHandler = nil
            client.cancel()
            throw NewsTests.loopbackFailure("connect to 127.0.0.1:\(endpoint)", error)
        }
        client.stateUpdateHandler = nil
        try await NewsTests.socketSend(client, Data([5, 1, 0]))
        expectEqual(try await NewsTests.socketRead(client, count: 2), Data([5, 0]), "SOCKS greeting succeeds")
        let hostBytes = Data(host.utf8)
        var request = Data([5, command, 0, 3, UInt8(hostBytes.count)])
        request.append(hostBytes)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 255)])
        // Fragment across every protocol boundary, not just a single network packet.
        try await NewsTests.socketSend(client, Data(request.prefix(1)))
        try await NewsTests.socketSend(client, Data(request.dropFirst()))
        return (client, try await NewsTests.socketRead(client, count: 10))
    }
}
