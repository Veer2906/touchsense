import CoreGraphics
@preconcurrency import ScreenCaptureKit
import TapCore

public final class ScreenWatcher: NSObject, SCStreamOutput, @unchecked Sendable {
  public let frames: AsyncStream<HandFrame>

  private let continuation: AsyncStream<HandFrame>.Continuation
  private let queue = DispatchQueue(label: "local.tapsense.screen", qos: .utility)
  private let detector = HandDetector()
  private var stream: SCStream?

  public override init() {
    (frames, continuation) = AsyncStream<HandFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
    super.init()
  }

  public func start(displayID: CGDirectDisplayID) async throws {
    let content = try await SCShareableContent.current
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw AudioInputError.coreAudio("finding the display to watch", -1)
    }
    let configuration = SCStreamConfiguration()
    configuration.width = 1280
    configuration.height = 1280 * display.height / max(display.width, 1)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 6)
    configuration.showsCursor = false
    configuration.queueDepth = 3
    let stream = SCStream(
      filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
      delegate: nil)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  public func stop() async {
    try? await stream?.stopCapture()
    stream = nil
    continuation.finish()
  }

  public func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    continuation.yield(
      HandFrame(
        time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
        hands: detector.detect(in: buffer)))
  }
}
