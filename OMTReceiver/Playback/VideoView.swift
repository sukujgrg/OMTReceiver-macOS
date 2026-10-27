import AppKit
import CoreGraphics
import MetalKit
import QuartzCore
import os

/// Native Metal surface. Admission is bounded independently of main-thread
/// responsiveness, and only due source pictures are consumed by the draw loop.
@MainActor
// AppKit/Metal state stays on MainActor. The sole nonisolated admission API
// accesses only VideoMailbox, whose complete mutable state is lock protected.
final class VideoView: MTKView, MTKViewDelegate, @unchecked Sendable {
    typealias BufferAllocator = @MainActor (MTLDevice, UnsafeRawPointer, Int) -> MTLBuffer?
    var onToggleFullscreen: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Notifications carry no stale payload; owners read current renderer health.
    var onStateChange: (@MainActor () -> Void)?
    var errorMessage: String? { initializationError ?? frameError }
    private(set) var displayedFormat: String?
    private let mailbox: VideoMailbox
    private let clock: PlaybackClock
    private let allocateBuffer: BufferAllocator
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var current: VideoMailbox.Entry?
    private var currentBuffer: MTLBuffer?
    private let inflight = DispatchSemaphore(value: 3)
    private var deinterlace: DeinterlaceMode = .automatic
    private var fieldOrder: FieldOrder = .topFirst
    private var background: VideoBackground = .black
    private var initializationError: String?
    private var frameError: String?
    private var frameRateLimit: Int?
    private var screenObserver: NSObjectProtocol?
    private var windowScreenObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.suku.OMTReceiver.macOS", category: "Video")

    init(frame frameRect: NSRect = .zero, clock: PlaybackClock = PlaybackClock(),
         device: MTLDevice? = MTLCreateSystemDefaultDevice(),
         allocateBuffer: @escaping BufferAllocator = {
             $0.makeBuffer(bytes: $1, length: $2, options: .storageModeShared)
         }) {
        self.clock = clock
        self.allocateBuffer = allocateBuffer
        mailbox = VideoMailbox(clock: clock)
        super.init(frame: frameRect, device: device)
        // Keep high-depth YUV and linear alpha composition above 8-bit
        // precision through Core Animation, even for ordinary SDR output.
        colorPixelFormat = .rgba16Float
        framebufferOnly = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        layer?.isOpaque = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        setAccessibilityElement(true)
        setAccessibilityLabel("OMT video")
        setAccessibilityHelp("Click to enter fullscreen. Press Escape to leave fullscreen.")
        delegate = self
        setupMetal()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateDisplayCadence() }
            }
    }

    required init(coder: NSCoder) { fatalError("Use init(frame:clock:)") }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onToggleFullscreen?()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.charactersIgnoringModifiers == " " { onToggleFullscreen?() }
        else { super.keyDown(with: event) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowScreenObserver {
            NotificationCenter.default.removeObserver(windowScreenObserver)
            self.windowScreenObserver = nil
        }
        if let window {
            windowScreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateDisplayCadence() }
                }
        }
        updateDisplayCadence()
    }

    nonisolated func enqueue(_ frame: VideoFrame) { mailbox.enqueue(frame) }

    /// Silent browser previews need only the newest picture and no A/V delay.
    /// A separate receiver supplies full-resolution fullscreen playback.
    func configurePreviewRendering() {
        frameRateLimit = 15
        mailbox.useImmediatePreview()
        setAccessibilityElement(false)
        updateDisplayCadence()
    }

    func clear() {
        mailbox.clear()
        current = nil; currentBuffer = nil; displayedFormat = nil
        clock.reset()
        publishFrameError(nil)
    }

    func configure(deinterlace: DeinterlaceMode, fieldOrder: FieldOrder,
                   background: VideoBackground) {
        self.deinterlace = deinterlace; self.fieldOrder = fieldOrder
        self.background = background
    }

    private func setupMetal() {
        guard let device else { reportInitializationError("Metal is unavailable on this Mac."); return }
        do {
            pipeline = try VideoPipelineCache.pipeline(device: device, format: colorPixelFormat)
            guard let queue = device.makeCommandQueue() else {
                reportInitializationError("Cannot prepare the video renderer: a Metal command queue is unavailable.")
                return
            }
            commandQueue = queue
        } catch { reportInitializationError("Cannot prepare the video renderer: \(error.localizedDescription)") }
    }

    private func reportInitializationError(_ message: String) {
        initializationError = message
        logger.error("\(message, privacy: .public)")
        onStateChange?()
    }

    private func publishFrameError(_ message: String?) {
        guard frameError != message else { return }
        frameError = message
        if let message { logger.error("\(message, privacy: .public)") }
        onStateChange?()
    }

    /// Preparation is independent of drawable availability. Only a successful
    /// allocation replaces the last good picture and clears a transient failure.
    @discardableResult
    func prepareDueFrame(at time: TimeInterval) -> Bool {
        guard initializationError == nil, let device,
              let entry = mailbox.takeDue(at: time) else { return false }
        let buffer = entry.frame.data.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return allocateBuffer(device, base, bytes.count)
        }
        guard let buffer else {
            publishFrameError("Insufficient GPU memory for this video format.")
            return false
        }
        current = entry
        currentBuffer = buffer
        displayedFormat = entry.frame.summary
        publishFrameError(nil)
        return true
    }

    private func updateDisplayCadence() {
        let screen = window?.screen ?? NSScreen.main
        let displayRate = max(1, screen?.maximumFramesPerSecond ?? 60)
        preferredFramesPerSecond = min(frameRateLimit ?? displayRate, displayRate)
    }

    private var screenIsInterlaced: Bool {
        guard let screen = window?.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(id.uint32Value)) else { return false }
        // IOGraphicsTypes.h kDisplayModeInterlacedFlag. AppKit cannot promise
        // field-accurate scanout; preserving fields avoids needless conversion.
        return mode.ioFlags & 0x40 != 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inflight.wait(timeout: .now()) == .success else { return }
        guard let commandQueue, let command = commandQueue.makeCommandBuffer(),
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable else {
            inflight.signal(); return
        }
        let now = CACurrentMediaTime()
        prepareDueFrame(at: now)
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            if let current, let currentBuffer, let pipeline {
                let frame = current.frame
                let bob = frame.isInterlaced && (deinterlace == .bob ||
                    (deinterlace == .automatic && !screenIsInterlaced))
                let first = fieldOrder == .topFirst ? 0 : 1
                let elapsed = max(0, now - current.presentationTime)
                let second = elapsed >= 0.5 / max(1, frame.framesPerSecond)
                let field = bob ? (first + (second ? 1 : 0)) % 2 : -1
                let bg: Int32 = background == .black ? 0 : (background == .checkerboard ? 1 : 2)
                var uniforms = VideoUniforms(
                    dimensions: SIMD4(UInt32(frame.width), UInt32(frame.height), UInt32(frame.stride), frame.codec),
                    options: SIMD4(Int32(frame.flags), Int32(frame.colorSpace), Int32(field), bg),
                    output: SIMD4(Float(drawableSize.width), Float(drawableSize.height), Float(frame.displayAspect), 0))
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentBuffer(currentBuffer, offset: 0, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
        }
        let semaphore = inflight
        command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable); command.commit()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let windowScreenObserver { NotificationCenter.default.removeObserver(windowScreenObserver) }
    }
}

/// Each GPU compiles the shipped shader once, shared by full-size and thumbnail
/// surfaces. All cache access is on the AppKit owner actor.
@MainActor
private enum VideoPipelineCache {
    struct Key: Hashable { let device: UInt64; let format: UInt }
    private static var pipelines: [Key: MTLRenderPipelineState] = [:]
    static func pipeline(device: MTLDevice, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = Key(device: device.registryID, format: format.rawValue)
        if let cached = pipelines[key] { return cached }
        guard let url = Bundle.main.url(forResource: "VideoShaders.metal", withExtension: "txt") else {
            throw NSError(domain: "OMTReceiver.Video", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled video shader is missing."])
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "omt_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "omt_fragment")
        descriptor.colorAttachments[0].pixelFormat = format
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }
}

private struct VideoUniforms {
    var dimensions: SIMD4<UInt32>
    var options: SIMD4<Int32>
    var output: SIMD4<Float>
}

final class VideoMailbox: @unchecked Sendable {
    struct Entry { let frame: VideoFrame; let presentationTime: Double }
    private let lock = NSLock()
    private let clock: PlaybackClock
    private var frames: [Entry] = []
    private var queuedBytes = 0
    private var immediatePreview = false
    func useImmediatePreview() {
        lock.lock(); defer { lock.unlock() }
        immediatePreview = true
        frames.removeAll(); queuedBytes = 0
    }
    init(clock: PlaybackClock) { self.clock = clock }

    func enqueue(_ frame: VideoFrame) {
        guard VideoFrameValidation.isValid(frame) else { return }
        lock.lock(); defer { lock.unlock() }
        let time = immediatePreview ? CACurrentMediaTime() : clock.presentationTime(for: frame.timestamp)
        if immediatePreview {
            frames = [Entry(frame: frame, presentationTime: time)]
            queuedBytes = frame.data.count
            return
        }
        if let last = frames.last, frame.timestamp <= last.frame.timestamp {
            frames.removeAll(keepingCapacity: true); queuedBytes = 0
        }
        frames.append(Entry(frame: frame, presentationTime: time)); queuedBytes += frame.data.count
        while frames.count > 1 && (frames.count > 8 || queuedBytes > 128 * 1024 * 1024) {
            queuedBytes -= frames.removeFirst().frame.data.count
        }
    }
    func takeDue(at time: Double) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var latest: Entry?
        while let first = frames.first, first.presentationTime <= time {
            latest = frames.removeFirst()
            queuedBytes -= latest!.frame.data.count
        }
        return latest
    }
    func clear() { lock.lock(); frames.removeAll(); queuedBytes = 0; lock.unlock() }
}

/// Kept independent of Metal so malformed SDK frames can be regression tested.
enum VideoFrameValidation {
    static func isValid(_ frame: VideoFrame) -> Bool {
        guard (2...16384).contains(frame.width), (2...16384).contains(frame.height),
              frame.stride > 0, frame.stride <= 262144,
              frame.frameRateN > 0, frame.frameRateD > 0,
              frame.framesPerSecond.isFinite, frame.framesPerSecond <= 1000,
              frame.data.count <= 256 * 1024 * 1024 else { return false }
        let rows = frame.stride * frame.height
        switch frame.codec {
        case 0x41524742, 0x58524742:
            return frame.stride >= frame.width * 4 && frame.data.count >= rows
        case 0x59565955:
            return frame.width % 2 == 0 && frame.stride >= frame.width * 2 && frame.data.count >= rows
        case 0x41565955:
            return frame.width % 2 == 0 && frame.stride % 2 == 0 &&
                frame.stride >= frame.width * 2 && frame.data.count >= rows + rows / 2
        case 0x36313250:
            return frame.width % 2 == 0 && frame.stride >= frame.width * 2 && frame.data.count >= rows * 2
        case 0x36314150:
            return frame.width % 2 == 0 && frame.stride >= frame.width * 2 && frame.data.count >= rows * 3
        default: return false
        }
    }
}
