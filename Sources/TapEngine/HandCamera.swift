import AVFoundation
import CoreImage
import TapCore
import os

public struct CameraFrame: Sendable {
  public let frame: HandFrame
  public let preview: Data?
}

public final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  public let name: String
  public let frames: AsyncStream<CameraFrame>

  private let continuation: AsyncStream<CameraFrame>.Continuation
  private let device: AVCaptureDevice
  private let zoom: Double
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "local.tapsense.camera", qos: .userInteractive)
  private let detector = HandDetector()
  private var recording: Recording?
  private let context = CIContext()
  private let watchdog: DispatchSourceTimer
  private var lastFrame = Date()
  private var lastPreview = -Double.infinity
  private let log = Logger(subsystem: "local.tapsense", category: "camera")

  public static func device() -> AVCaptureDevice? {
    let found = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.continuityCamera, .external], mediaType: .video, position: .unspecified
    ).devices.filter { $0.isConnected && !$0.isSuspended }
    return found.first(where: \.isContinuityCamera) ?? found.first
  }

  private struct Recording {
    let directory: URL
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    var start = CMTime.zero
    var times: [Double] = []
  }

  public init(device: AVCaptureDevice, zoom: Double = 1) throws {
    self.device = device
    self.zoom = zoom
    name = device.localizedName
    (frames, continuation) = AsyncStream<CameraFrame>.makeStream(bufferingPolicy: .bufferingNewest(4))
    watchdog = DispatchSource.makeTimerSource(queue: queue)
    super.init()

    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    session.beginConfiguration()
    guard session.canAddInput(input), session.canAddOutput(output) else {
      session.commitConfiguration()
      throw AudioInputError.coreAudio("configuring \(name)", -1)
    }
    session.addInput(input)
    session.addOutput(output)
    session.commitConfiguration()
  }

  public func start() {
    queue.async { [self] in
      AVCaptureDevice.centerStageControlMode = .app
      AVCaptureDevice.isCenterStageEnabled = false
      let locked = (try? device.lockForConfiguration()) != nil
      if locked, let format = preferredFormat() {
        device.activeFormat = format.format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: format.rate)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: format.rate)
      }
      session.startRunning()
      if locked {
        setZoom(zoom)
        device.unlockForConfiguration()
      }
      let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
      log.notice(
        "camera format \(size.width)x\(size.height), frame duration \(self.device.activeVideoMinFrameDuration.seconds, format: .fixed(precision: 4)) s, zoom \(self.currentZoom, format: .fixed(precision: 2)), running \(self.session.isRunning)"
      )

      lastFrame = Date()
      watchdog.schedule(deadline: .now() + 2, repeating: 2)
      watchdog.setEventHandler { [self] in
        if Date().timeIntervalSince(lastFrame) > 4 || !session.isRunning { continuation.finish() }
      }
      watchdog.resume()
    }
  }

  public func stop() {
    queue.async { [self] in
      finishRecording()
      watchdog.cancel()
      if (try? device.lockForConfiguration()) != nil {
        setZoom(1)
        device.unlockForConfiguration()
      }
      session.stopRunning()
      continuation.finish()
    }
  }

  public func startRecording(to directory: URL) {
    queue.async { [self] in recording = Recording(directory: directory) }
  }

  public func stopRecording() {
    queue.async { [self] in finishRecording() }
  }

  private func finishRecording() {
    guard let finished = recording else { return }
    recording = nil
    finished.input?.markAsFinished()
    finished.writer?.finishWriting {}
    try? JSONEncoder().encode(finished.times).write(to: finished.directory.appending(path: "frames.json"))
  }

  private func record(_ buffer: CVPixelBuffer, stamp: CMTime, time: Double) {
    guard var active = recording else { return }
    defer { recording = active }
    if active.writer == nil {
      guard let writer = try? AVAssetWriter(url: active.directory.appending(path: "video.mov"), fileType: .mov)
      else { return }
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: CVPixelBufferGetWidth(buffer),
          AVVideoHeightKey: CVPixelBufferGetHeight(buffer),
          AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { return }
      writer.add(input)
      active.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
      guard writer.startWriting() else { return }
      writer.startSession(atSourceTime: .zero)
      active.writer = writer
      active.input = input
      active.start = stamp
    }
    guard let input = active.input, input.isReadyForMoreMediaData,
      active.adaptor?.append(buffer, withPresentationTime: stamp - active.start) == true
    else { return }
    active.times.append(time)
  }

  public func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lastFrame = Date()
    let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let time = (session.synchronizationClock.map {
      CMSyncConvertTime(stamp, from: $0, to: CMClockGetHostTimeClock())
    } ?? stamp).seconds

    record(buffer, stamp: stamp, time: time)

    var preview: Data?
    if time - lastPreview >= 0.1 {
      lastPreview = time
      let image = CIImage(cvPixelBuffer: buffer)
      let scale = 640 / image.extent.width
      preview = context.jpegRepresentation(
        of: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5])
    }
    continuation.yield(
      CameraFrame(
        frame: HandFrame(
          time: time, hands: detector.detect(in: buffer),
          aspect: Float(CVPixelBufferGetWidth(buffer)) / Float(CVPixelBufferGetHeight(buffer))),
        preview: preview))
  }

  private var currentZoom: Double {
    guard device.responds(to: Selector(("videoZoomFactor"))) else { return 1 }
    return device.value(forKey: "videoZoomFactor") as? Double ?? 1
  }

  private func setZoom(_ factor: Double) {
    guard
      device.responds(to: Selector(("setVideoZoomFactor:"))),
      device.activeFormat.responds(to: Selector(("videoMaxZoomFactor"))),
      let limit = device.activeFormat.value(forKey: "videoMaxZoomFactor") as? Double
    else { return }
    device.setValue(min(max(factor, 1), limit), forKey: "videoZoomFactor")
  }

  private func preferredFormat() -> (format: AVCaptureDevice.Format, rate: Int32)? {
    let candidates = device.formats.filter {
      let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
      return size.width == 1920 && size.height == 1080
    }
    func fastest(_ format: AVCaptureDevice.Format) -> Double {
      format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }
    guard let best = candidates.max(by: { fastest($0) < fastest($1) }) else { return nil }
    return (best, fastest(best) >= 60 ? 60 : 30)
  }
}
