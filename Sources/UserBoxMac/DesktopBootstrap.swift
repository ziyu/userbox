#if os(macOS)
import Foundation
import Network
import UserBoxCore

/// Uses Apple's authenticated graphical login. Never handles an account password.
/// The relay is loopback-only; it does not enable or reconfigure Screen Sharing.
public final class DesktopBootstrap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.userbox.bootstrap")
    private var listener: NWListener?
    private var pipes: [UUID: Pipe] = [:]
    public init() {}
    public func start(username: String) async throws -> URL {
        guard username.hasPrefix("ub_"), BoxConfig.validName(String(username.dropFirst(3))) else {
            throw BoxError("Only a provisioned UserBox login may be requested")
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let port = listener?.port { continuation.resume(returning: port.rawValue); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var resumed = false
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed, let port = listener.port { resumed = true; continuation.resume(returning: port.rawValue) }
                        case .failed(let error):
                            if !resumed { resumed = true; continuation.resume(throwing: error) }
                        case .cancelled:
                            if !resumed { resumed = true; continuation.resume(throwing: BoxError("Desktop login relay cancelled")) }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, self.pipes.count < 4 else { connection.cancel(); return }
                        let id = UUID()
                        let pipe = Pipe(incoming: connection, queue: self.queue) { [weak self] in self?.pipes.removeValue(forKey: id) }
                        self.pipes[id] = pipe; pipe.start()
                    }
                    listener.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
        var url = URLComponents(); url.scheme = "vnc"; url.host = "127.0.0.1"; url.port = Int(port); url.user = username
        guard let result = url.url else { throw BoxError("Could not construct local login URL") }
        return result
    }
    public func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            let previous = Array(pipes.values); pipes.removeAll(); previous.forEach { $0.stop() }
        }
    }
    private final class Pipe {
        let incoming: NWConnection
        let outgoing = NWConnection(host: "127.0.0.1", port: 5900, using: .tcp)
        let queue: DispatchQueue
        let ended: () -> Void
        var stopped = false
        init(incoming: NWConnection, queue: DispatchQueue, ended: @escaping () -> Void) {
            self.incoming = incoming; self.queue = queue; self.ended = ended
        }
        func start() {
            incoming.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.stop() } }
            outgoing.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state { self.copy(self.incoming, self.outgoing); self.copy(self.outgoing, self.incoming) }
                if case .failed = state { self.stop() }
            }
            incoming.start(queue: queue); outgoing.start(queue: queue)
        }
        func copy(_ from: NWConnection, _ to: NWConnection) {
            guard !stopped else { return }
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self, !self.stopped else { return }
                if let error { _ = error; self.stop(); return }
                guard let data, !data.isEmpty else { if complete { self.stop() }; return }
                to.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil || complete { self.stop() } else { self.copy(from, to) }
                })
            }
        }
        func stop() {
            guard !stopped else { return }; stopped = true
            incoming.cancel(); outgoing.cancel(); ended()
        }
    }
}
#endif
