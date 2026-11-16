import Foundation
import TapCore
import os

public struct Viewport: Sendable {
  public var x: Float
  public var y: Float
  public var width: Float
  public var height: Float

  public init(x: Float, y: Float, width: Float, height: Float) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public actor Engine {
  public enum Output: Sendable {
    case message(String)
    case click(x: Float, y: Float)
    case scroll(x: Float, y: Float, dx: Float, dy: Float, began: Bool)
    case startRecording(URL)
    case stopRecording
  }

  public nonisolated let outputs: AsyncStream<Output>

  private struct PendingTap {
    let time: Double
    let sample: Int
    let column: Int
    let shape: EventShape
  }

  private struct PointerSession {
    let targets: [SIMD2<Float>]
    let viewport: Viewport
    var samples: [PointerSample] = []
    var tapTime: Double?
    var quietUntil: Double
    var note: String?
  }

  private let output: AsyncStream<Output>.Continuation
  private let store: Store
  private let encoder = JSONEncoder()
  private let log = Logger(subsystem: "local.tapsense", category: "engine")

  private var deviceName = ""
  private var sampleRate = 0.0
  private var pipeline: TapPipeline?
  private var columns = WaveColumns()
  private var lastDetection: Float = 0
  private var anchor = (sample: 0, time: 0.0)
  private var audioTime = 0.0
  private var recorder: WAVWriter?
  private var recordingURL: URL?

  private var cameraState = "starting"
  private var cameraName = ""
  private static let smoothing = OneEuroFilter.Parameters(minimumCutoff: 2, speedGain: 8)

  private var tracker = HandTracker(smoothing: Engine.smoothing)
  private var fps = 0
  private var frameCount = 0
  private var frameSecond = 0
  private var screenHands: [HandObservation] = []
  private var screenHandsSeen = -Double.infinity
  private var screenCheck = false
  private var aspect: Float = 1.54
  private var screenWidthMM: Float = 290

  private var mapping: PointerMapping?
  private var pending: [PendingTap] = []
  private var scroll = ScrollGesture()
  private var calibration: PointerSession?
  private var sessionDirectory: URL?
  private var sessionAudio: WAVWriter?
  private var sessionRecord: SessionRecord?
  private var captureScript: [(label: String, seconds: Double)] = []
  private var captureNotice = ""

  public init(directory: URL) {
    (outputs, output) = AsyncStream<Output>.makeStream()
    store = Store(directory: directory)
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    encoder.dateEncodingStrategy = .iso8601
    do {
      try store.prepare()
      mapping = try store.loadPointer()?.mapping
    } catch {
      log.error("saved pointer calibration unusable: \(error, privacy: .public)")
    }
  }

  public func setScreen(aspect: Float, widthMM: Float) {
    self.aspect = aspect
    if widthMM > 0 { screenWidthMM = widthMM }
  }

  public func capture(_ script: [(label: String, seconds: Double)]) {
    captureScript = script
  }

  private func advanceCapture() {
    if sessionRecord?.phases == nil {
      guard !captureScript.isEmpty, cameraState == "ok", calibration == nil, sessionDirectory == nil,
        let directory = try? store.makeSessionDirectory()
      else { return }
      var start = audioTime
      var phases: [SessionRecord.Phase] = []
      for step in captureScript {
        phases.append(SessionRecord.Phase(label: step.label, start: start, end: start + step.seconds))
        start += step.seconds
      }
      captureScript = []
      sessionDirectory = directory
      sessionRecord = SessionRecord(
        aspect: aspect, screenWidthMM: screenWidthMM, sampleRate: sampleRate, mapping: mapping, phases: phases)
      output.yield(.startRecording(directory))
    }
    guard let phases = sessionRecord?.phases else { return }
    let notice: String
    if let phase = phases.first(where: { audioTime < $0.end }) {
      notice = "RECORDING · \(phase.label) · \(Int((phase.end - audioTime).rounded(.up))) s"
    } else {
      notice = "recording finished"
      endSession(mapping: sessionRecord?.mapping)
    }
    if notice != captureNotice {
      captureNotice = notice
      send(NoticeMessage(text: notice))
    }
  }

  public func record(to url: URL) {
    recordingURL = url
  }

  public func setCamera(state: String) {
    cameraState = state
    sendStatus()
  }

  public func run(audio: AsyncStream<AudioChunk>, device: String, sampleRate: Double) async {
    deviceName = device
    self.sampleRate = sampleRate
    pipeline = TapPipeline(sampleRate: sampleRate)
    columns.size = max(1, Int(sampleRate / 500))
    if let recordingURL { recorder = try? WAVWriter(url: recordingURL, sampleRate: sampleRate) }
    sendStatus()
    log.notice("listening on \(device, privacy: .public) at \(sampleRate, format: .fixed(precision: 0)) Hz")
    for await chunk in audio { process(chunk) }
  }

  public func run(camera: AsyncStream<CameraFrame>, name: String) async {
    cameraName = name
    cameraState = "ok"
    tracker = HandTracker(smoothing: Self.smoothing)
    sendStatus()
    log.notice("watching \(name, privacy: .public)")
    for await frame in camera { handle(frame) }
    cameraState = "missing"
    fps = 0
    sendStatus()
  }

  public func run(screen: AsyncStream<HandFrame>) async {
    screenCheck = true
    sendStatus()
    log.notice("checking the screen image for displayed hands")
    for await frame in screen {
      screenHands = frame.hands
      screenHandsSeen = tracker.latestTime
    }
    screenCheck = false
    sendStatus()
  }

  public func sendStatus() {
    var pointer: StatusMessage.Pointer?
    if let mapping, let inverse = mapping.homography.inverse {
      let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
      pointer = StatusMessage.Pointer(
        error: mapping.error, millimetres: mapping.error * screenWidthMM, lag: mapping.lag,
        quad: corners.map(inverse.apply).map { [$0.x, $0.y] })
    }
    send(
      StatusMessage(
        mic: pipeline == nil ? "starting" : "ok", device: deviceName, sampleRate: sampleRate,
        camera: cameraState, cameraName: cameraName, fps: fps, screenCheck: screenCheck, pointer: pointer))
  }

  public func beginCalibration(viewport: Viewport) {
    guard calibration == nil, pipeline != nil else { return }
    guard cameraState == "ok" else {
      send(CalibrationMessage(phase: "failed", problem: "the iPhone camera is not running"))
      return
    }
    calibration = PointerSession(
      targets: PointerCalibration.targets(columns: 4, rows: 4, inset: 0.08), viewport: viewport,
      quietUntil: audioTime + 0.6)
    pending.removeAll()
    if let directory = try? store.makeSessionDirectory() {
      sessionDirectory = directory
      sessionRecord = SessionRecord(aspect: aspect, screenWidthMM: screenWidthMM, sampleRate: sampleRate)
      sessionAudio = try? WAVWriter(url: directory.appending(path: "audio.wav"), sampleRate: sampleRate)
      output.yield(.startRecording(directory))
    }
    sendProgress()
  }

  private func endSession(mapping: PointerMapping?) {
    guard let directory = sessionDirectory else { return }
    output.yield(.stopRecording)
    try? sessionAudio?.close()
    sessionAudio = nil
    sessionRecord?.mapping = mapping
    if let data = try? JSONEncoder().encode(sessionRecord) {
      try? data.write(to: directory.appending(path: "session.json"))
    }
    sessionDirectory = nil
    sessionRecord = nil
  }

  public func cancelCalibration() {
    guard calibration != nil else { return }
    calibration = nil
    endSession(mapping: nil)
    send(CalibrationMessage(phase: "cancelled"))
  }

  public func clearCalibration() {
    do {
      try store.archivePointer()
      mapping = nil
    } catch {
      log.error("could not archive pointer calibration: \(error, privacy: .public)")
    }
    sendStatus()
  }

  private func process(_ chunk: AudioChunk) {
    anchor = (pipeline?.totalSamples ?? 0, chunk.hostTime)
    audioTime = chunk.hostTime + Double(chunk.samples.count) / sampleRate
    try? recorder?.append(chunk.samples)
    if let sessionAudio {
      if sessionRecord?.audioStart == nil { sessionRecord?.audioStart = chunk.hostTime }
      try? sessionAudio.append(chunk.samples)
    }
    guard let result = pipeline?.process(chunk.samples), let pipeline else { return }

    lastDetection = result.frames.map(\.detection).max() ?? lastDetection
    columns.add(chunk.samples, detection: lastDetection)
    if let wave = columns.drain(minimum: 16, threshold: pipeline.triggerDB) { send(wave) }

    for candidate in result.candidates { handle(candidate, analyzer: pipeline.analyzer) }
    resolve()
    advanceCapture()
  }

  private func handle(_ candidate: TapCandidate, analyzer: EventAnalyzer) {
    let time = anchor.time + Double(candidate.onsetSample - anchor.sample) / sampleRate
    let shape = candidate.shape
    let rejection = analyzer.rejection(for: shape)
    let tap = PendingTap(
      time: time, sample: candidate.onsetSample, column: candidate.onsetSample / columns.size, shape: shape)

    if let session = calibration {
      if rejection == nil, session.tapTime == nil, time >= session.quietUntil {
        calibration?.tapTime = time
        sendProgress()
      }
      return
    }
    guard rejection == nil, mapping != nil, cameraState == "ok" else {
      report(tap, tap: rejection == nil, why: rejection?.rawValue, at: nil)
      return
    }
    pending.append(tap)
  }

  private func handle(_ item: CameraFrame) {
    let ids = tracker.update(with: item.frame)
    if let mapping, tracker.latestTime - screenHandsSeen < 1.5, !screenHands.isEmpty {
      for (hand, id) in zip(item.frame.hands, ids)
      where DisplayedHands.matches(hand, mappedBy: mapping.homography, against: screenHands, aspect: aspect) {
        tracker.markDisplayed(id)
      }
    }

    send(
      HandsMessage(
        hands: zip(item.frame.hands, ids).map { hand, id in
          let track = tracker.tracks.first { $0.id == id }
          let steady = track?.samples.last.flatMap { $0.time == item.frame.time ? $0.tip : nil }
          var joints = hand.joints
          if let steady { joints[HandObservation.indexTip] = steady }
          return HandsMessage.Hand(
            id: id, joints: joints.flatMap { [$0.x, $0.y] }, confidences: hand.confidences,
            displayed: track?.displayed ?? false,
            screen: steady.flatMap { tip in mapping.map { $0.homography.apply(tip) } }.map { [$0.x, $0.y] })
        }))
    if let preview = item.preview { send(PreviewMessage(jpeg: preview)) }

    if let mapping, calibration == nil, sessionRecord?.phases == nil {
      let real = zip(ids, item.frame.hands)
        .filter { id, _ in tracker.tracks.first { $0.id == id }?.displayed != true }
        .map { (id: $0, hand: $1) }
      if let update = scroll.update(
        hands: real, time: item.frame.time, aspect: item.frame.aspect, homography: mapping.homography)
      {
        send(ScrollMessage(x: update.position.x, y: update.position.y))
        output.yield(
          .scroll(
            x: update.position.x, y: update.position.y, dx: update.delta.x, dy: update.delta.y,
            began: update.began))
      }
    }

    frameCount += 1
    if Int(item.frame.time) != frameSecond {
      frameSecond = Int(item.frame.time)
      if frameCount != fps {
        fps = frameCount
        sendStatus()
      }
      frameCount = 0
    }
    resolve()
  }

  private func resolve() {
    let seen = tracker.latestTime
    if let mapping {
      var waiting: [PendingTap] = []
      for tap in pending {
        guard seen >= tap.time + mapping.lag + PointerCalibration.window || audioTime > tap.time + 0.7 else {
          waiting.append(tap)
          continue
        }
        if abs(scroll.lastActive - (tap.time + mapping.lag)) < 0.4 {
          report(tap, tap: false, why: "two-finger scroll", at: nil)
        } else if let touch = TouchResolver.resolve(tracks: tracker.tracks, tapTime: tap.time, mapping: mapping) {
          let point = touch.screen.clamped(lowerBound: SIMD2(0, 0), upperBound: SIMD2(1, 1))
          report(tap, tap: true, why: nil, at: point)
          if sessionRecord?.phases == nil { output.yield(.click(x: point.x, y: point.y)) }
        } else {
          report(tap, tap: false, why: "no fingertip on the screen", at: nil)
        }
      }
      pending = waiting
    }
    if let tapTime = calibration?.tapTime, seen >= tapTime + 0.45 || audioTime > tapTime + 1.2 {
      captureCalibrationTap(at: tapTime)
    }
  }

  private func captureCalibrationTap(at tapTime: Double) {
    guard var session = calibration else { return }
    session.tapTime = nil
    session.quietUntil = tapTime + 0.5
    let target = session.targets[session.samples.count]
    let display = SIMD2(
      session.viewport.x + target.x * session.viewport.width,
      session.viewport.y + target.y * session.viewport.height)
    let sample = PointerCalibration.sample(target: display, tapTime: tapTime, tracks: tracker.tracks)
    sessionRecord?.attempts.append(SessionRecord.Attempt(time: tapTime, target: display, accepted: sample != nil))
    if let sample {
      session.samples.append(sample)
      session.note = nil
    } else {
      session.note = "heard a tap but the camera saw no fingertip"
    }
    calibration = session
    if session.samples.count == session.targets.count { finishCalibration() } else { sendProgress() }
  }

  private func finishCalibration() {
    guard let session = calibration else { return }
    calibration = nil
    let solved = PointerCalibration.solve(session.samples, aspect: aspect)
    endSession(mapping: solved)
    guard let solved else {
      send(CalibrationMessage(phase: "failed", problem: "the fingertip was not visible at enough targets"))
      return
    }
    guard solved.error <= 0.04 else {
      send(
        CalibrationMessage(
          phase: "failed",
          problem: "fingertip positions were inconsistent (\(Int(solved.error * screenWidthMM)) mm off)"))
      return
    }
    mapping = solved
    do {
      try store.save(PointerRecord(mapping: solved, samples: session.samples))
    } catch {
      log.error("could not save pointer calibration: \(error, privacy: .public)")
    }
    log.notice(
      "pointer calibrated: error \(solved.error, format: .fixed(precision: 4)) lag \(solved.lag, format: .fixed(precision: 3)) from \(solved.samples) taps"
    )
    send(
      CalibrationMessage(
        phase: "done", error: solved.error, millimetres: solved.error * screenWidthMM, lag: solved.lag))
    sendStatus()
  }

  private func sendProgress() {
    guard let session = calibration else { return }
    let target = session.targets[session.samples.count]
    send(
      CalibrationMessage(
        phase: "taps", done: session.samples.count, total: session.targets.count, x: target.x, y: target.y,
        heard: session.tapTime != nil, note: session.note))
  }

  private func report(_ tap: PendingTap, tap isTap: Bool, why: String?, at point: SIMD2<Float>?) {
    send(
      EventMessage(
        column: tap.column, tap: isTap, why: why, snr: tap.shape.snrDB, x: point?.x, y: point?.y))
    let record = EventRecord(
      time: Date(), sample: tap.sample, tap: isTap, why: why, shape: tap.shape, x: point?.x, y: point?.y)
    if let line = try? encoder.encode(record) { store.appendEvent(line) }
  }

  private func send(_ message: some Encodable) {
    guard let data = try? encoder.encode(message) else { return }
    output.yield(.message(String(decoding: data, as: UTF8.self)))
  }
}
