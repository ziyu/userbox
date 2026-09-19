#if os(macOS)
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UserBoxCore

/// Owns only frames delivered inside the Box user's Aqua session.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let config: BoxConfig
    let pinned: UInt32
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latest: (FrameInfo, Data)?
    private var sequence: UInt64 = 0
    private var failure: String?
    init(config: BoxConfig, pinned: UInt32) { self.config = config; self.pinned = pinned }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failure = error.localizedDescription; latest = nil; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              (try? MacIdentity.guardSession(config, pinned: pinned)) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = context.createCGImage(image, from: image.extent) else { return }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            guard CGImageDestinationFinalize(destination), bytes.length <= Wire.maxPayload else { return }
            lock.lock(); defer { lock.unlock() }
            sequence &+= 1
            latest = (FrameInfo(width: cg.width, height: cg.height, sequence: sequence), bytes as Data)
        }
    }
    func frame() throws -> (FrameInfo, Data) {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw BoxError("Screen capture stopped: \(failure)") }
        guard let latest else { throw BoxError("Waiting for the first native desktop frame") }
        return latest
    }
}

@MainActor final class DesktopCapture {
    let config: BoxConfig
    var stream: SCStream?
    var sink: CaptureSink?
    private(set) var bounds = CGRect.zero
    init(config: BoxConfig) { self.config = config }
    func start(pinned: UInt32) async throws {
        if stream != nil { return }
        let identity = try MacIdentity.guardSession(config, pinned: pinned)
        guard identity.screenRecording else { throw BoxError("Grant Screen Recording to UserBox Session in the Box account") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        _ = try MacIdentity.guardSession(config, pinned: pinned)
        guard let display = content.displays.first else { throw BoxError("The Box session has no capturable display") }
        bounds = CGDisplayBounds(display.displayID)
        guard bounds.width > 0, bounds.height > 0 else { throw BoxError("Invalid Box display geometry") }
        let settings = SCStreamConfiguration()
        let scale = min(1.0, 1600.0 / Double(display.width))
        settings.width = max(1, Int(Double(display.width) * scale))
        settings.height = max(1, Int(Double(display.height) * scale))
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        settings.queueDepth = 3; settings.showsCursor = true; settings.capturesAudio = false
        let sink = CaptureSink(config: config, pinned: pinned)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: settings, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "io.userbox.capture"))
        try await stream.startCapture()
        _ = try MacIdentity.guardSession(config, pinned: pinned)
        self.sink = sink; self.stream = stream
    }
    func stop() async {
        let previous = stream; stream = nil; sink = nil; bounds = .zero
        try? await previous?.stopCapture()
    }
    func frame(pinned: UInt32) async throws -> (FrameInfo, Data) {
        try await start(pinned: pinned)
        _ = try MacIdentity.guardSession(config, pinned: pinned)
        guard let sink else { throw BoxError("Capture not started") }
        return try sink.frame()
    }
}
#endif
