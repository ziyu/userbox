#if os(macOS)
import AppKit
import UserBoxCore
import CUserBox

@MainActor public final class SessionService {
    public let config: BoxConfig
    private let capture: DesktopCapture
    private var input: SessionInput?
    private var pinned: UInt32?
    private var lease = LeaseState()
    private var clients = Set<String>()
    private var listener: Int32 = -1
    private var timer: Timer?
    public init(config: BoxConfig) throws {
        try config.validate()
        guard ub_uid() == config.guestUID else { throw BoxError("Session helper must run as the dedicated Box account") }
        self.config = config; capture = DesktopCapture(config: config)
    }
    public func start() throws {
        listener = ub_listen(config.socketPath)
        guard listener >= 0 else { throw BoxError("Unable to bind private desktop socket") }
        let listener = listener, hostUID = config.hostUID
        DispatchQueue(label: "io.userbox.accept").async { [weak self] in
            while true {
                let fd = ub_accept(listener); if fd < 0 { break }
                var uid: UInt32 = 0
                guard ub_peer_uid(fd, &uid) == 0, uid == hostUID else { ub_close(fd); continue }
                let connection = UUID().uuidString
                DispatchQueue(label: "io.userbox.peer.\(connection)").async { [weak self] in
                    defer {
                        ub_close(fd)
                        Task { @MainActor [weak self] in await self?.disconnected(connection) }
                    }
                    do {
                        while true {
                            let request = try Wire.receive(Request.self, from: fd)
                            let payload = try Wire.read(fd, count: request.payloadBytes, maximum: Wire.maxPayload)
                            let ready = DispatchSemaphore(value: 0)
                            var result: (Reply, Data)?
                            Task { @MainActor [weak self] in
                                result = await self?.handle(request, payload: payload, owner: connection)
                                ready.signal()
                            }
                            ready.wait()
                            guard let result else { break }
                            try Wire.send(result.0, to: fd); try Wire.write(fd, data: result.1)
                        }
                    } catch { /* Disconnects release the control lease; never log payloads. */ }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.lease.expire(now: ProcessInfo.processInfo.systemUptime) { try? self.input?.releaseAll() }
                if (try? MacIdentity.guardSession(self.config, pinned: self.pinned)) == nil {
                    if let owner = self.lease.owner { _ = self.lease.release(owner: owner) }
                    try? self.input?.releaseAll(); await self.capture.stop()
                }
            }
        }
    }
    private func disconnected(_ owner: String) async {
        clients.remove(owner)
        if lease.release(owner: owner) { try? input?.releaseAll() }
        if clients.isEmpty { await capture.stop() }
    }
    private func authorized(_ request: Request, owner: String) throws {
        _ = try MacIdentity.guardSession(config, pinned: pinned)
        try lease.require(owner: owner, token: request.lease, now: ProcessInfo.processInfo.systemUptime)
    }
    private func identity() throws -> SessionIdentity {
        let identity = try MacIdentity.guardSession(config, pinned: pinned)
        if pinned == nil {
            pinned = identity.sessionID; input = SessionInput(config: config, pinned: identity.sessionID)
        }
        return identity
    }
    private func handle(_ request: Request, payload: Data, owner: String) async -> (Reply, Data) {
        clients.insert(owner)
        var reply = Reply(id: request.id), bytes = Data()
        do {
            reply.identity = try identity()
            guard request.action == "import" || payload.isEmpty else { throw BoxError("This operation does not accept binary data") }
            switch request.action {
            case "status":
                if request.lease != nil { try authorized(request, owner: owner) }
                reply.result = "Native Aqua session identity verified"
            case "claim":
                let token = try lease.acquire(owner: owner, role: request.role ?? "agent", now: ProcessInfo.processInfo.systemUptime)
                try? input?.releaseAll(); reply.lease = token
            case "release":
                if lease.release(owner: owner) { try? input?.releaseAll() }
            case "restart":
                try authorized(request, owner: owner)
                reply.result = "Restarting only the Box session helper; the desktop and apps remain running"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            case "permissions":
                // Prompts appear only inside the verified Box session. TCC is never edited.
                if !AXIsProcessTrusted() {
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
                if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                reply.identity = try identity()
                reply.result = "Approve UserBox Session in the Box account's Privacy & Security settings"
            case "snapshot":
                let frame = try await capture.frame(pinned: pinned!)
                reply.frame = frame.0; bytes = frame.1
            case "apps": reply.applications = applications()
            case "input":
                try authorized(request, owner: owner)
                guard let event = request.event else { throw BoxError("Input event missing") }
                try event.validate()
                if event.kind == "text" { try await type(event.text!, request: request, owner: owner) }
                else { try input?.send(event, bounds: capture.bounds) }
            case "open":
                try authorized(request, owner: owner)
                guard let path = request.appPath, applications().contains(where: { $0.path == path }) else {
                    throw BoxError("Select an installed native application from the Box application list")
                }
                let pid = try await open(URL(fileURLWithPath: path))
                reply.result = "Opened native application as UID \(config.guestUID), PID \(pid)"
            case "finder":
                try authorized(request, owner: owner)
                let pid = try await open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), file: try importsDirectory())
                reply.result = "Opened Finder as UID \(config.guestUID), PID \(pid)"
            case "import":
                try authorized(request, owner: owner)
                let url = try fileURL(request.filename)
                try payload.write(to: url, options: [.withoutOverwriting])
                reply.result = url.path
            case "export":
                try authorized(request, owner: owner)
                let url = try fileURL(request.filename)
                guard let stream = InputStream(url: url) else { throw BoxError("Cannot read exported file") }
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n == 0 { break }; if n < 0 { throw BoxError("File read failed") }
                    guard bytes.count + n <= Wire.maxPayload else { throw BoxError("Demo file transfer limit is 16 MiB") }
                    bytes.append(contentsOf: buffer.prefix(n))
                }
                reply.result = url.lastPathComponent
            case "smoke":
                try authorized(request, owner: owner)
                reply.result = try await smoke(request: request, owner: owner)
            default: throw BoxError("Unknown desktop operation")
            }
            // Recheck after every asynchronous operation and before returning any pixels.
            reply.identity = try identity(); reply.payloadBytes = bytes.count
        } catch {
            reply.ok = false; reply.error = error.localizedDescription; reply.payloadBytes = 0; bytes = Data()
        }
        return (reply, bytes)
    }
    private func type(_ text: String, request: Request, owner: String) async throws {
        var chunk = ""
        for character in text {
            chunk.append(character)
            if chunk.count >= 16 {
                try authorized(request, owner: owner)
                var event = InputEvent(kind: "text"); event.text = chunk
                try input?.send(event, bounds: capture.bounds); chunk = ""
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        if !chunk.isEmpty {
            try authorized(request, owner: owner)
            var event = InputEvent(kind: "text"); event.text = chunk; try input?.send(event, bounds: capture.bounds)
        }
    }
    private func importsDirectory() throws -> URL {
        let home = URL(fileURLWithPath: "/Users/\(config.username)", isDirectory: true)
        let root = home.appendingPathComponent("Documents/UserBox/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.resolvingSymlinksInPath().path == root.path else { throw BoxError("Transfer directory must not traverse symlinks") }
        return root
    }
    private func fileURL(_ filename: String?) throws -> URL {
        let name = try SafeFiles.filename(filename ?? "")
        let url = try importsDirectory().appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().path == url.path else { throw BoxError("Symlink transfers are not allowed") }
        return url
    }
    private func applications() -> [AppInfo] {
        var result: [AppInfo] = []
        for directory in ["/Applications", "/System/Applications", "/System/Library/CoreServices", "/Users/\(config.username)/Applications"] {
            guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator {
                guard url.pathExtension == "app", let bundle = Bundle(url: url),
                      let id = bundle.bundleIdentifier, !id.hasPrefix("io.userbox.") else { continue }
                result.append(AppInfo(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent,
                                      path: url.path, bundleID: id))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func open(_ application: URL, file: URL? = nil) async throws -> Int32 {
        _ = try identity()
        let settings = NSWorkspace.OpenConfiguration(); settings.activates = true
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: BoxError("Launch Services returned no application")) }
            }
            if let file { NSWorkspace.shared.open([file], withApplicationAt: application, configuration: settings, completionHandler: completion) }
            else { NSWorkspace.shared.openApplication(at: application, configuration: settings, completionHandler: completion) }
        }
        _ = try identity()
        guard ub_process_uid(app.processIdentifier) == config.guestUID else { throw BoxError("Application launched outside the Box account") }
        return app.processIdentifier
    }
    private func smoke(request: Request, owner: String) async throws -> String {
        try await capture.start(pinned: pinned!)
        let name = "userbox-smoke-\(UUID().uuidString).txt", expected = "UserBox native edit and save: \(UUID().uuidString)\n"
        let file = try fileURL(name)
        try Data("Replace this text.\n".utf8).write(to: file, options: [.withoutOverwriting])
        _ = try await open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), file: try importsDirectory())
        try authorized(request, owner: owner)
        let textEdit = applications().first { $0.bundleID == "com.apple.TextEdit" }
        guard let textEdit else { throw BoxError("TextEdit is not installed") }
        _ = try await open(URL(fileURLWithPath: textEdit.path), file: file)
        for _ in 0..<30 {
            try authorized(request, owner: owner)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            throw BoxError("TextEdit did not become the Box session's frontmost application")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        func shortcut(_ code: UInt16) throws {
            try authorized(request, owner: owner)
            for kind in ["keyDown", "keyUp"] {
                var event = InputEvent(kind: kind); event.keyCode = code; event.flags = CGEventFlags.maskCommand.rawValue
                try input?.send(event, bounds: capture.bounds)
            }
        }
        try shortcut(0) // Command-A
        try await type(expected, request: request, owner: owner)
        try shortcut(1) // Command-S
        for _ in 0..<40 {
            try authorized(request, owner: owner)
            if (try? String(contentsOf: file, encoding: .utf8)) == expected {
                _ = try await capture.frame(pinned: pinned!)
                return "PASS: Finder and TextEdit ran as UID \(config.guestUID); actual file contents match keyboard edits: \(file.path)"
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BoxError("Native save verification failed: the file did not contain the injected text. No success was inferred from event delivery.")
    }
}
#endif
