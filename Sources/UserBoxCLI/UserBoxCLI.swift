import Foundation
import UserBoxCore

@main enum UserBoxCLI {
    static let usage = """
    userboxctl [--box demo] COMMAND
      status | apps | finder | permissions | smoke
      screenshot OUTPUT.jpg
      open /Applications/Example.app
      type TEXT
      key MAC_KEYCODE [CG_FLAGS]
      click X Y                  normalized coordinates, 0...1
      scroll DELTA_Y
      import LOCAL_FILE
      export BOX_FILENAME LOCAL_OUTPUT
    Commands are authenticated by Unix peer UID; run as the configured host user, never sudo.
    """
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst()), box = "demo"
        if args.isEmpty || args.contains("--help") { print(usage); return }
        if let index = args.firstIndex(of: "--box") {
            guard args.indices.contains(index + 1) else { fail("--box requires a name") }
            box = args[index + 1]; args.removeSubrange(index...index + 1)
        }
        guard !args.isEmpty else { fail(usage) }
        let command = args.removeFirst()
        var client: BoxConnection?
        do {
            let connection = BoxConnection(config: try BoxConfig.load(box)); client = connection
            var request = Request(command), payload = Data(), output: URL?
            var click: (Double, Double)?
            switch command {
            case "status", "apps", "finder", "permissions", "smoke":
                guard args.isEmpty else { throw BoxError("Unexpected arguments") }
            case "screenshot":
                guard args.count == 1 else { throw BoxError("screenshot requires an output path") }
                request.action = "snapshot"; output = URL(fileURLWithPath: args[0])
            case "open":
                guard args.count == 1 else { throw BoxError("open requires the installed .app path") }; request.appPath = args[0]
            case "type":
                guard args.count == 1 else { throw BoxError("type requires one quoted string") }
                request.action = "input"; var event = InputEvent(kind: "text"); event.text = args[0]; try event.validate(); request.event = event
            case "key":
                guard (1...2).contains(args.count), let code = UInt16(args[0]), code <= 127 else { throw BoxError("Invalid key code") }
                request.action = "input"; var event = InputEvent(kind: "keyDown"); event.keyCode = code
                if args.count == 2 { guard let flags = UInt64(args[1]) else { throw BoxError("Invalid flags") }; event.flags = flags }
                request.event = event
            case "click":
                guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]) else { throw BoxError("click requires X Y in 0...1") }
                var event = InputEvent(kind: "down"); event.x = x; event.y = y; event.button = 0; try event.validate()
                request.action = "input"; request.event = event; click = (x, y)
            case "scroll":
                guard args.count == 1, let y = Int(args[0]) else { throw BoxError("scroll requires a signed pixel delta") }
                request.action = "input"; var event = InputEvent(kind: "scroll"); event.deltaY = y; try event.validate(); request.event = event
            case "import":
                guard args.count == 1 else { throw BoxError("import requires a local file") }
                let url = URL(fileURLWithPath: args[0])
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= Wire.maxPayload else { throw BoxError("Transfer exceeds 16 MiB") }
                payload = try Data(contentsOf: url); request.filename = url.lastPathComponent; request.payloadBytes = payload.count
            case "export":
                guard args.count == 2 else { throw BoxError("export requires a Box filename and local destination") }
                request.filename = try SafeFiles.filename(args[0]); output = URL(fileURLWithPath: args[1])
            default: throw BoxError(usage)
            }
            let readOnly = ["status", "apps", "snapshot", "permissions"].contains(request.action)
            if !readOnly {
                var claim = Request("claim"); claim.role = "agent"
                request.lease = try await connection.call(claim).0.lease
            }
            if command == "click" { _ = try? await connection.call(Request("snapshot")) }
            var response: (Reply, Data)
            if command == "screenshot" {
                var received: (Reply, Data)?
                for attempt in 0..<20 {
                    do { received = try await connection.call(request); break }
                    catch { if attempt == 19 { throw error }; try await Task.sleep(nanoseconds: 100_000_000) }
                }
                guard let received else { throw BoxError("No native frame received") }; response = received
            } else { response = try await connection.call(request, payload: payload) }
            if command == "key" || click != nil {
                var up = request; up.id = UUID().uuidString; up.event?.kind = click != nil ? "up" : "keyUp"
                _ = try await connection.call(up)
            }
            if let output { try response.1.write(to: output, options: [.withoutOverwriting]) }
            if !readOnly { _ = try await connection.call(Request("release")) }
            response.0.lease = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(response.0), as: UTF8.self))
            connection.close()
        } catch {
            if let client { _ = try? await client.call(Request("release")); client.close() }
            fail(error.localizedDescription)
        }
    }
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("userboxctl: " + message + "\n").utf8)); exit(1)
    }
}
