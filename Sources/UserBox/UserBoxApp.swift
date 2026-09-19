#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserBoxCore
import UserBoxMac

@MainActor final class BoxModel: ObservableObject {
    @Published var name = "demo"
    @Published var status = "Prepare a dedicated account, then start its macOS desktop."
    @Published var image: NSImage?
    @Published var identity: SessionIdentity?
    @Published var apps: [AppInfo] = []
    @Published var selectedApp = ""
    @Published var transferName = ""
    @Published var human = false
    @Published var testing = false
    private var connection: BoxConnection?
    private var lease: String?
    private var poll: Task<Void, Never>?
    private let bootstrap = DesktopBootstrap()
    private var pending: [InputEvent] = []
    private var draining = false
    private var lastSequence: UInt64 = 0

    func startDesktop() async {
        do {
            let config = try BoxConfig.load(name)
            let url = try await bootstrap.start(username: config.username)
            guard NSWorkspace.shared.open(url) else { throw BoxError("Apple Screen Sharing could not open the local login") }
            status = "In Apple's login window, authenticate as \(config.username) and choose its own desktop, not Share Display."
            connect()
        } catch { status = error.localizedDescription }
    }
    func connect() {
        poll?.cancel(); connection?.close(); lease = nil; human = false; image = nil; identity = nil; lastSequence = 0
        do {
            let config = try BoxConfig.load(name), client = BoxConnection(config: try BoxConfig.load(name))
            connection = client
            status = "Connecting to \(config.username)'s graphical session…"
            poll = Task { [weak self] in
                var loadedApps = false
                while !Task.isCancelled {
                    guard let self else { return }
                    do {
                        var request = Request("status"); request.lease = self.lease
                        let (reply, _) = try await client.call(request)
                        guard !Task.isCancelled else { return }
                        self.identity = reply.identity
                        if !loadedApps {
                            let result = try await client.call(Request("apps")); self.apps = result.0.applications ?? []
                            self.selectedApp = self.apps.first(where: { $0.bundleID == "com.apple.TextEdit" })?.path ?? self.apps.first?.path ?? ""
                            loadedApps = true
                        }
                        if reply.identity?.screenRecording == true && NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
                            do {
                                let (frame, bytes) = try await client.call(Request("snapshot"))
                                guard !Task.isCancelled else { return }
                                if let sequence = frame.frame?.sequence, sequence != self.lastSequence {
                                    self.image = NSImage(data: bytes); self.lastSequence = sequence
                                }
                            } catch { if self.image == nil { self.status = error.localizedDescription } }
                        } else if reply.identity?.screenRecording != true {
                            self.status = "Enable Screen Recording for UserBox Session inside the Box account, then restart the helper."
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.status = error.localizedDescription; self.image = nil; self.identity = nil
                        self.lease = nil; self.human = false; self.pending.removeAll(); loadedApps = false
                    }
                    try? await Task.sleep(nanoseconds: 125_000_000)
                }
            }
        } catch { status = error.localizedDescription }
    }
    private func client() throws -> BoxConnection {
        guard let connection else { throw BoxError("Connect to the Box first") }; return connection
    }
    private func claim(_ role: String) async throws {
        pending.removeAll()
        var request = Request("claim"); request.role = role
        let result = try await client().call(request)
        guard let token = result.0.lease else { throw BoxError("No control lease returned") }
        lease = token; human = role == "human"
    }
    func takeOver() async { do { try await claim("human"); status = "You control the Box. Click its picture to type." } catch { status = error.localizedDescription } }
    func observe() async {
        pending.removeAll(); human = false
        do { _ = try await client().call(Request("release")); lease = nil; status = "Observe only. Agent clients may acquire control." }
        catch { lease = nil; status = error.localizedDescription }
    }
    func send(_ event: InputEvent) {
        guard human, lease != nil else { return }
        if event.kind == "move", pending.last?.kind == "move" { pending[pending.count - 1] = event }
        else { pending.append(event) }
        guard pending.count <= 512 else { pending.removeAll(); Task { await observe() }; return }
        guard !draining else { return }; draining = true
        Task {
            defer { draining = false }
            while human && !pending.isEmpty {
                let event = pending.removeFirst()
                do {
                    var request = Request("input"); request.event = event; request.lease = lease
                    _ = try await client().call(request)
                } catch { pending.removeAll(); human = false; lease = nil; status = error.localizedDescription }
            }
        }
    }
    func releasePressedKeys() { if human { send(InputEvent(kind: "release")) } }
    func action(_ name: String) async {
        do {
            if ["finder", "open", "restart"].contains(name) { try await claim("human") }
            var request = Request(name); request.lease = lease; request.appPath = selectedApp
            let result = try await client().call(request); status = result.0.result ?? "Done"
        } catch { status = error.localizedDescription }
    }
    func shortcut(_ code: UInt16) async {
        do {
            if !human { try await claim("human") }
            for kind in ["keyDown", "keyUp"] {
                var event = InputEvent(kind: kind); event.keyCode = code; event.flags = CGEventFlags.maskCommand.rawValue; send(event)
            }
        } catch { status = error.localizedDescription }
    }
    func importFile() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= Wire.maxPayload else {
                throw BoxError("Demo file transfer limit is 16 MiB")
            }
            let bytes = try Data(contentsOf: url); try await claim("human")
            var request = Request("import"); request.filename = url.lastPathComponent
            request.lease = lease; request.payloadBytes = bytes.count
            let result = try await client().call(request, payload: bytes)
            transferName = url.lastPathComponent; status = result.0.result ?? "Imported"
        } catch { status = error.localizedDescription }
    }
    func exportFile() async {
        do {
            _ = try SafeFiles.filename(transferName)
            let panel = NSSavePanel(); panel.nameFieldStringValue = transferName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try await claim("human")
            var request = Request("export"); request.filename = transferName; request.lease = lease
            let (_, bytes) = try await client().call(request)
            try bytes.write(to: url, options: .atomic); status = "Exported the selected file."
        } catch { status = error.localizedDescription }
    }
    func smoke() async {
        guard !testing else { return }; testing = true
        defer { testing = false }
        do {
            try await claim("agent")
            status = "Focus the host typing probe now; keep the physical mouse still during this test."
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let initialApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let initialCursor = NSEvent.mouseLocation
            let window = NSApp.mainWindow
            let initialFocus = window?.firstResponder
            var appChanged = false, pointerChanged = false, focusChanged = false
            let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                appChanged = appChanged || NSWorkspace.shared.frontmostApplication?.processIdentifier != initialApp
                pointerChanged = pointerChanged || NSEvent.mouseLocation != initialCursor
                focusChanged = focusChanged || window?.firstResponder !== initialFocus
            }
            defer { timer.invalidate() }
            var request = Request("smoke"); request.lease = lease
            let result = try await client().call(request)
            let passed = !appChanged && !pointerChanged && !focusChanged
            let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "box": name,
                "nativeFileVerification": result.0.result ?? "", "hostForegroundChanged": appChanged,
                "hostCursorChanged": pointerChanged, "hostFocusChanged": focusChanged,
                "overallPassed": passed, "note": "Human mouse/focus changes invalidate the deterministic host-isolation phase. No host keystrokes or screenshots are recorded."]
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/UserBox")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("isolation-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
            status = "\(passed ? "PASS" : "FAIL"): native edit/save verified; host isolation report: \(path.path)"
        } catch { status = "FAIL: \(error.localizedDescription)" }
        await releaseAfterTest()
    }
    private func releaseAfterTest() async {
        _ = try? await client().call(Request("release")); lease = nil; human = false
    }
}

struct ContentView: View {
    @StateObject private var model = BoxModel()
    @State private var hostProbe = "Type here while the native test runs in the other desktop."
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("UserBox").font(.largeTitle.bold())
                Text("Native macOS desktop").foregroundStyle(.secondary)
                TextField("Box name", text: $model.name)
                HStack {
                    Button("Start desktop") { Task { await model.startDesktop() } }
                    Button("Connect") { model.connect() }
                }
                Button("Open host Screen Sharing settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
                }.font(.caption)
                Divider()
                if let identity = model.identity {
                    Text("UID \(identity.uid) · session \(identity.sessionID)").font(.system(.caption, design: .monospaced))
                    Text("Off-console identity verified").font(.caption)
                    Text("Capture: \(identity.screenRecording ? "granted" : "needed") · Input: \(identity.accessibility ? "granted" : "needed")").font(.caption)
                }
                HStack {
                    Button("Permissions") { Task { await model.action("permissions") } }
                    Button("Restart helper") { Task { await model.action("restart") } }
                }.disabled(model.identity == nil)
                Divider()
                HStack {
                    Button("Take over") { Task { await model.takeOver() } }
                    Button("Observe") { Task { await model.observe() } }
                }.disabled(model.identity == nil)
                Text(model.human ? "Your input stays inside the picture." : "Viewer only — your host input is not forwarded.").font(.caption)
                Button("Open Finder") { Task { await model.action("finder") } }.disabled(model.identity == nil)
                Picker("Application", selection: $model.selectedApp) {
                    ForEach(model.apps) { app in Text(app.name).tag(app.path) }
                }
                Button("Open native app") { Task { await model.action("open") } }.disabled(model.selectedApp.isEmpty)
                HStack {
                    Button("Send ⌘Tab") { Task { await model.shortcut(48) } }
                    Button("Send ⌘Space") { Task { await model.shortcut(49) } }
                }.disabled(model.identity == nil)
                Divider()
                Button("Import a file…") { Task { await model.importFile() } }.disabled(model.identity == nil)
                TextField("Filename in Box Imports", text: $model.transferName)
                Button("Export this file…") { Task { await model.exportFile() } }.disabled(model.identity == nil)
                Divider()
                Button(model.testing ? "Testing…" : "Run native isolation test") { Task { await model.smoke() } }
                    .disabled(model.identity == nil || model.testing)
                Text("Host typing probe").font(.caption.bold())
                TextEditor(text: $hostProbe).font(.system(.body, design: .monospaced)).frame(height: 95)
                Spacer(minLength: 0)
            }.padding(20).frame(minWidth: 300, idealWidth: 320, maxWidth: 370)
            VStack(spacing: 0) {
                ZStack {
                    DesktopSurface(image: model.image, controlling: model.human, send: model.send)
                    if model.image == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").font(.system(size: 48))
                            Text("Waiting for the dedicated native desktop").font(.title3)
                            Text("The picture appears only after its account and graphical session are verified.")
                                .font(.callout).multilineTextAlignment(.center)
                        }.foregroundStyle(.white).padding(40)
                    }
                }
                Text(model.status).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(minWidth: 620, minHeight: 620)
        }.frame(minWidth: 980, minHeight: 780)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.releasePressedKeys() }
    }
}
@main struct UserBoxApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Quit UserBox") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: [.command, .shift])
                }
            }
    }
}
#else
@main enum UnsupportedHost { static func main() { print("UserBox's native desktop viewer requires macOS 13 or later") } }
#endif
