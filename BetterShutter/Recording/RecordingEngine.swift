import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Records a display to an H.264 MP4 (with optional system audio) using ScreenCaptureKit's
/// `SCStream` feeding an `AVAssetWriter`. Not an actor: SCStream delivers sample buffers on a
/// background queue, so all writer state is confined to one serial `queue` and the class is
/// `@unchecked Sendable` with that invariant.
nonisolated final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let queue = DispatchQueue(label: "app.bettershutter.recording.writer")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var outputURL: URL?

    var captureSystemAudio = true

    // MARK: Start

    func start(displayID: CGDirectDisplayID, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else { throw CaptureError.noDisplays }

        let scale = CaptureEngine.scale(for: display.displayID)
        let width = even(Int((CGFloat(display.width) * scale).rounded()))
        let height = even(Int((CGFloat(display.height) * scale).rounded()))

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = captureSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])

        try queue.sync {
            let writer = try AVAssetWriter(url: url, fileType: .mp4)

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
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: 128_000,
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    self.audioInput = audioInput
                }
            }

            writer.startWriting()
            self.writer = writer
            self.videoInput = videoInput
            self.adaptor = adaptor
            self.outputURL = url
            self.sessionStarted = false
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: Stop

    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                guard let writer = self.writer else { continuation.resume(returning: nil); return }
                writer.finishWriting {
                    continuation.resume(returning: self.writer?.status == .completed ? self.outputURL : nil)
                }
            }
        }
    }

    // MARK: SCStreamOutput (background queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard isComplete(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !sessionStarted {
                writer?.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            adaptor?.append(pixelBuffer, withPresentationTime: pts)

        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)

        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream ended (e.g. display disconnect). Writer is finalized on stop().
    }

    // MARK: Helpers

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
}
