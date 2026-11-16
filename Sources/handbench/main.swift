import AVFoundation
import Foundation
import TapCore
import TapEngine

struct ExternalHand: Codable {
  var joints: [[Float]]
  var confidence: Float
  var confidences: [Float]?
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

func visionFrames(video: URL, times: [Double]) async throws -> [HandFrame] {
  let asset = AVURLAsset(url: video)
  guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("no video track") }
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ])
  output.alwaysCopiesSampleData = false
  reader.add(output)
  reader.startReading()

  let detector = HandDetector()
  var frames: [HandFrame] = []
  while frames.count < times.count, let sample = output.copyNextSampleBuffer() {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
    frames.append(HandFrame(time: times[frames.count], hands: detector.detect(in: buffer)))
  }
  return frames
}

func externalFrames(file: URL, times: [Double]) throws -> [HandFrame] {
  let decoded = try JSONDecoder().decode([[ExternalHand]].self, from: Data(contentsOf: file))
  return zip(times, decoded).map { time, hands in
    HandFrame(
      time: time,
      hands: hands.filter { $0.joints.count == HandObservation.jointCount }.map { hand in
        HandObservation(
          joints: hand.joints.map { SIMD2($0[0], $0[1]) },
          confidences: [Float](repeating: hand.confidence, count: HandObservation.jointCount))
      })
  }
}

func percentile(_ values: [Float], _ fraction: Float) -> Float {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return .nan }
  return sorted[min(sorted.count - 1, Int(fraction * Float(sorted.count)))]
}

func score(_ name: String, frames: [HandFrame], record: SessionRecord, smoothing: OneEuroFilter.Parameters?) {
  var tracker = HandTracker(smoothing: smoothing)
  var samples: [PointerSample] = []
  var next = 0
  var withHand = 0
  for frame in frames {
    _ = tracker.update(with: frame)
    if !frame.hands.isEmpty { withHand += 1 }
    while next < record.attempts.count, frame.time >= record.attempts[next].time + 0.45 {
      let attempt = record.attempts[next]
      if let sample = PointerCalibration.sample(target: attempt.target, tapTime: attempt.time, tracks: tracker.tracks) {
        samples.append(sample)
      }
      next += 1
    }
  }

  let millimetres = record.screenWidthMM
  let scale = SIMD2<Float>(millimetres, millimetres / record.aspect)
  func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    (((a - b) * scale) * ((a - b) * scale)).sum().squareRoot()
  }
  let coverage = String(format: "%3.0f%%", 100 * Float(withHand) / Float(max(frames.count, 1)))
  let label = name.padding(toLength: 26, withPad: " ", startingAt: 0)
  guard let mapping = PointerCalibration.solve(samples, aspect: record.aspect) else {
    print("\(label) \(coverage)  \(samples.count)/\(record.attempts.count)   no mapping could be fitted")
    return
  }

  let pairs = samples.compactMap { sample in sample.tip(at: mapping.lag).map { (tip: $0, target: sample.target) } }
  let heldOut: [Float] = pairs.indices.compactMap { index in
    var others = pairs
    let left = others.remove(at: index)
    return Homography.fit(from: others.map(\.tip), to: others.map(\.target))
      .map { distance($0.apply(left.tip), left.target) }
  }
  var wobble: [Float] = []
  for sample in samples {
    let still = zip(sample.offsets, sample.tips).filter { abs($0.0 - mapping.lag) <= 0.04 }
      .map { mapping.homography.apply($0.1) }
    guard still.count >= 3 else { continue }
    let centre = still.reduce(SIMD2<Float>.zero, +) / Float(still.count)
    wobble += still.map { distance($0, centre) }
  }
  let jitter = (wobble.map { $0 * $0 }.reduce(0, +) / Float(max(wobble.count, 1))).squareRoot()

  print(
    label, coverage, String(format: " %2d/%-2d", samples.count, record.attempts.count),
    String(format: "  %2d", mapping.samples),
    String(format: "  %6.1f", mapping.error * millimetres),
    String(format: "  %6.1f  %6.1f  %6.1f", percentile(heldOut, 0.5), percentile(heldOut, 0.9), heldOut.max() ?? .nan),
    String(format: "  %5.2f", jitter), String(format: "  %4.0f", mapping.lag * 1000))
}

func scrollReport(frames: [HandFrame], record: SessionRecord) {
  guard let mapping = record.mapping, let start = frames.first?.time else {
    print("no saved mapping in this session, so scrolling cannot be replayed")
    return
  }
  var tracker = HandTracker()
  var gesture = ScrollGesture()
  var posed: [Int: Int] = [:]
  var scrolled: [Int: Int] = [:]
  var begins: [Double] = []
  var distance: Float = 0
  for frame in frames {
    let ids = tracker.update(with: frame)
    let second = Int(frame.time - start)
    if frame.hands.contains(where: { ScrollPose.matches($0, aspect: frame.aspect) }) { posed[second, default: 0] += 1 }
    let hands = zip(ids, frame.hands).map { (id: $0, hand: $1) }
    if let update = gesture.update(hands: hands, time: frame.time, aspect: frame.aspect, homography: mapping.homography) {
      scrolled[second, default: 0] += 1
      if update.began { begins.append(frame.time - start) }
      distance += abs(update.delta.y) * record.screenWidthMM / record.aspect + abs(update.delta.x) * record.screenWidthMM
    }
  }
  print("second: frames in the two-finger pose / frames that scrolled")
  let last = Int((frames.last?.time ?? start) - start)
  print((0...last).map { "\($0):\(posed[$0] ?? 0)/\(scrolled[$0] ?? 0)" }.joined(separator: " "))
  print("scrolls started at:", begins.map { String(format: "%.1f", $0) }.joined(separator: " "))
  print(String(format: "total finger travel while scrolling: %.0f mm", distance))
}

var arguments = Array(CommandLine.arguments.dropFirst())
var dump: URL?
if let flag = arguments.firstIndex(of: "--dump"), flag + 1 < arguments.count {
  dump = URL(filePath: arguments[flag + 1])
  arguments.removeSubrange(flag...flag + 1)
}
guard let first = arguments.first else {
  fail("usage: handbench <session-dir> [apple|<landmarks.json>]... [--dump <file.json>]")
}
let directory = URL(filePath: first)
let variants = arguments.count > 1 ? Array(arguments.dropFirst()) : ["apple"]
do {
  let record = try JSONDecoder().decode(
    SessionRecord.self, from: Data(contentsOf: directory.appending(path: "session.json")))
  let times = try JSONDecoder().decode([Double].self, from: Data(contentsOf: directory.appending(path: "frames.json")))
  print("\(times.count) frames, \(record.attempts.count) taps heard, screen \(Int(record.screenWidthMM)) mm wide")
  print("variant                    hand  tip    kept  trimmed  all-median  p90     max   jitter  lag")
  print("                           seen  seen         mm       mm          mm      mm    mm      ms")
  let smoothers: [(String, OneEuroFilter.Parameters?)] = [
    ("", nil),
    (" + smooth 2/8", OneEuroFilter.Parameters(minimumCutoff: 2, speedGain: 8)),
    (" + smooth 1/15", OneEuroFilter.Parameters(minimumCutoff: 1, speedGain: 15)),
    (" + smooth 4/20", OneEuroFilter.Parameters(minimumCutoff: 4, speedGain: 20)),
  ]
  for variant in variants {
    let frames: [HandFrame]
    if variant == "apple" {
      frames = try await visionFrames(video: directory.appending(path: "video.mov"), times: times)
    } else {
      frames = try externalFrames(file: URL(filePath: variant), times: times)
    }
    if let dump, variant == "apple" {
      let hands = frames.map { frame in
        frame.hands.map {
          ExternalHand(joints: $0.joints.map { [$0.x, $0.y] }, confidence: $0.tipConfidence, confidences: $0.confidences)
        }
      }
      try JSONEncoder().encode(hands).write(to: dump)
    }
    let name = variant == "apple" ? variant : URL(filePath: variant).deletingPathExtension().lastPathComponent
    if record.phases != nil {
      scrollReport(frames: frames, record: record)
      continue
    }
    for (suffix, smoothing) in smoothers {
      score(name + suffix, frames: frames, record: record, smoothing: smoothing)
    }
  }
} catch {
  fail("error: \(error)")
}
