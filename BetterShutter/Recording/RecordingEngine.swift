import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Records a display to an H.264 MP4 (with optional system audio + microphone) using
/// ScreenCaptureKit's `SCStream` feeding an `AVAssetWriter`. Not an actor: SCStream and the mic
/// `AVCaptureAudioDataOutput` deliver sample buffers on background queues, so all writer state is
/// confined to one serial `queue` and the class is `@unchecked Sendable` with that invariant.
nonisolated final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate,
                                         AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let queue = DispatchQueue(label: "app.bettershutter.recording.writer")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var stopping = false
    private var outputURL: URL?

    // Microphone capture (separate audio track).
    private let micSession = AVCaptureSession()
    private let micOutput = AVCaptureAudioDataOutput()
    private var micConfigured = false

    // Pause/resume: frames are dropped while paused and subsequent timestamps are shifted back by the
    // accumulated paused duration, so the output is gapless. The pause duration is measured off the
    // host-time clock (the same clock SCStream/AVCapture stamp samples with) at pause()/resume(), so
    // it's exact regardless of whether frames arrive during the pause.
    private var paused = false
    private var pauseStartHostTime: CMTime?
    private var accumulatedPause: CMTime = .zero

    var captureSystemAudio = true
    var captureMicrophone = false
    var showsCursor = true
    var fps: Int = 60
    /// Window IDs to keep OUT of the recording (e.g. our own control bar). The click / keystroke /
    /// webcam overlays are deliberately NOT listed, so they remain composited into the video.
    var excludedWindowIDs: [CGWindowID] = []

    // GIF mode: collect downscaled, PNG-compressed frames instead of writing video. Compressing
    // each frame keeps a full-length recording at tens of MB instead of hundreds (raw 640px BGRA
    // is ~1 MB/frame × 300 frames); GIFEncoder decodes them back one at a time on finalize.
    var gifMode = false
    private let ciContext = CIContext()
    private var gifFrameData: [Data] = []
    private var lastGIFTime: CMTime?
    private let gifInterval = CMTime(value: 1, timescale: 12)
    private let gifMaxFrames = 300

    // MARK: Start

    /// - Parameter sourceRect: optional sub-region in display-local points (top-left origin). When
    ///   non-nil only that region is recorded.
    func start(displayID: CGDirectDisplayID, sourceRect: CGRect? = nil, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else { throw CaptureError.noDisplays }

        let scale = CaptureEngine.scale(for: display.displayID)
        let regionPoints = sourceRect ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let width = even(Int((regionPoints.width * scale).rounded()))
        let height = even(Int((regionPoints.height * scale).rounded()))
        guard width > 0, height > 0 else { throw CaptureError.emptyCapture }

        let config = makeConfiguration(width: width, height: height, sourceRect: sourceRect)
        let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        try await beginWriting(filter: filter, config: config, width: width, height: height, to: url)
    }

    /// Record a single window (CleanShot/macshot-style), following it across the screen at its native
    /// resolution. Uses a desktop-independent window filter so only that window's pixels are recorded.
    func start(windowID: CGWindowID, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.emptyCapture
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let width = even(Int((filter.contentRect.width * scale).rounded()))
        let height = even(Int((filter.contentRect.height * scale).rounded()))
        guard width > 0, height > 0 else { throw CaptureError.emptyCapture }

        let config = makeConfiguration(width: width, height: height, sourceRect: nil)
        config.scalesToFit = true
        try await beginWriting(filter: filter, config: config, width: width, height: height, to: url)
    }

    /// Shared SCStream configuration for the display / region / window paths.
    private func makeConfiguration(width: Int, height: Int, sourceRect: CGRect?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: gifMode ? 15 : Int32(max(1, fps)))
        // Each queued buffer is a full-resolution BGRA frame (~60 MB at 5K); the writer drops
        // frames it can't keep up with anyway, so a deep queue mostly just pins memory.
        config.queueDepth = 4
        config.showsCursor = showsCursor
        config.capturesAudio = captureSystemAudio && !gifMode
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }

    /// Set up the writer (video + optional system/mic audio tracks) and start the SCStream for the
    /// given filter/config. Shared by the display, region, and window capture paths.
    private func beginWriting(filter: SCContentFilter, config: SCStreamConfiguration,
                              width: Int, height: Int, to url: URL) async throws {
        // Only commit a mic track if a device is present and authorized, so we never strand an empty
        // audio track when the mic is unavailable.
        let micAvailable = captureMicrophone && !gifMode
            && AVCaptureDevice.default(for: .audio) != nil
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        try queue.sync {
            guard !self.gifMode else {
                self.outputURL = url
                return
            }
            let writer = try AVAssetWriter(url: url, fileType: .mp4)
            // Periodic fragments keep the file playable if the app crashes mid-recording.
            writer.movieFragmentInterval = CMTime(value: 5, timescale: 1)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            guard writer.canAdd(videoInput) else { throw CaptureError.emptyCapture }
            writer.add(videoInput)

            if captureSystemAudio {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    self.audioInput = audioInput
                }
            }

            if micAvailable {
                let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
                micInput.expectsMediaDataInRealTime = true
                if writer.canAdd(micInput) {
                    writer.add(micInput)
                    self.micInput = micInput
                }
            }

            writer.startWriting()
            self.writer = writer
            self.videoInput = videoInput
            self.adaptor = adaptor
            self.outputURL = url
            self.sessionStarted = false
            self.paused = false
            self.pauseStartHostTime = nil
            self.accumulatedPause = .zero
        }

        if micAvailable { configureMicrophone() }

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if captureSystemAudio && !gifMode {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
            self.stream = stream
        } catch {
            // Don't strand a started writer / running mic session if the stream fails to start.
            if micSession.isRunning { micSession.stopRunning() }
            queue.sync { self.writer?.cancelWriting() }
            throw error
        }
    }

    private static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    private func configureMicrophone() {
        guard !micConfigured,
              let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        micSession.beginConfiguration()
        if micSession.canAddInput(input) { micSession.addInput(input) }
        micOutput.setSampleBufferDelegate(self, queue: queue)
        if micSession.canAddOutput(micOutput) { micSession.addOutput(micOutput) }
        micSession.commitConfiguration()
        micConfigured = true
        micSession.startRunning()
    }

    // MARK: Pause / resume

    func pause() {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            self.pauseStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            if let start = self.pauseStartHostTime {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                self.accumulatedPause = CMTimeAdd(self.accumulatedPause, CMTimeSubtract(now, start))
                self.pauseStartHostTime = nil
            }
        }
    }

    // MARK: Stop

    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        if micSession.isRunning { micSession.stopRunning() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async {
                // Reject any sample buffers that are still in flight after this point.
                self.stopping = true
                if self.gifMode {
                    let encoded = self.outputURL.map {
                        GIFEncoder.encode(frameData: self.gifFrameData, frameDelay: 1.0 / 12.0, to: $0)
                    } ?? false
                    self.gifFrameData.removeAll()
                    continuation.resume(returning: encoded ? self.outputURL : nil)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                guard let writer = self.writer else { continuation.resume(returning: nil); return }
                writer.finishWriting {
                    continuation.resume(returning: self.writer?.status == .completed ? self.outputURL : nil)
                }
            }
        }
    }

    // MARK: SCStreamOutput (writer queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard isComplete(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard !paused else { return }
            if gifMode {
                appendGIFFrame(sampleBuffer, pts: pts)
                return
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let adjusted = CMTimeSubtract(pts, accumulatedPause)
            // Anchor the session at the first frame we actually append, so there's no leading gap.
            if !sessionStarted {
                writer?.startSession(atSourceTime: adjusted)
                sessionStarted = true
            }
            adaptor?.append(pixelBuffer, withPresentationTime: adjusted)

        case .audio:
            guard sessionStarted, !paused,
                  let audioInput, audioInput.isReadyForMoreMediaData else { return }
            appendOffsetAudio(sampleBuffer, to: audioInput)

        default:
            break
        }
    }

    // MARK: AVCaptureAudioDataOutput (writer queue) — microphone

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopping, !gifMode, sessionStarted, !paused,
              CMSampleBufferDataIsReady(sampleBuffer),
              let micInput, micInput.isReadyForMoreMediaData else { return }
        appendOffsetAudio(sampleBuffer, to: micInput)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream ended (e.g. display disconnect). Writer is finalized on stop().
    }

    // MARK: Helpers

    /// Append an audio buffer, shifting its timestamps back by the accumulated paused duration so it
    /// stays aligned with the (also-shifted) video.
    private func appendOffsetAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        if accumulatedPause == .zero {
            input.append(sampleBuffer)
        } else if let shifted = Self.retime(sampleBuffer, by: accumulatedPause) {
            input.append(shifted)
        }
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in 0..<count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }

    private func appendGIFFrame(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        if let last = lastGIFTime, CMTimeSubtract(pts, last) < gifInterval { return }
        lastGIFTime = pts
        guard gifFrameData.count < gifMaxFrames,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Pool: CoreImage/ImageIO autorelease full-frame temporaries; without an explicit drain
        // they pile up on the long-lived writer queue between frames.
        autoreleasepool {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let maxWidth: CGFloat = 640
            let scale = min(1, maxWidth / max(ci.extent.width, 1))
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ciContext.createCGImage(scaled, from: scaled.extent),
               let data = ImageEncoder.encode(cg, as: .png) {
                gifFrameData.append(data)
            }
        }
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
}
