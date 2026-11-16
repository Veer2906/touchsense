import Foundation

public struct HandObservation: Sendable {
  public static let jointCount = 21
  public static let indexTip = 8
  public static let minimumConfidence: Float = 0.3

  public var joints: [SIMD2<Float>]
  public var confidences: [Float]

  public init(joints: [SIMD2<Float>], confidences: [Float]) {
    precondition(joints.count == Self.jointCount && confidences.count == Self.jointCount, "a hand has 21 joints")
    self.joints = joints
    self.confidences = confidences
  }

  public var tip: SIMD2<Float> { joints[Self.indexTip] }
  public var tipConfidence: Float { confidences[Self.indexTip] }

  public var center: SIMD2<Float> {
    var sum = SIMD2<Float>.zero
    var count: Float = 0
    for (joint, confidence) in zip(joints, confidences) where confidence >= Self.minimumConfidence {
      sum += joint
      count += 1
    }
    return count > 0 ? sum / count : joints[0]
  }
}

public struct HandFrame: Sendable {
  public var time: Double
  public var hands: [HandObservation]
  public var aspect: Float

  public init(time: Double, hands: [HandObservation], aspect: Float = 16.0 / 9) {
    self.time = time
    self.hands = hands
    self.aspect = aspect
  }
}

public struct HandTracker: Sendable {
  public struct Sample: Sendable {
    public let time: Double
    public let tip: SIMD2<Float>
  }

  public struct Track: Sendable {
    public let id: Int
    public fileprivate(set) var hand: HandObservation
    public fileprivate(set) var samples: [Sample] = []
    public fileprivate(set) var lastSeen: Double
    public fileprivate(set) var displayed = false
    fileprivate var held: Sample?
    fileprivate var lastRaw: Sample?
    fileprivate var smoother: OneEuroFilter?

    fileprivate mutating func add(_ raw: Sample) {
      func plausible(_ from: Sample, _ to: Sample) -> Bool {
        let elapsed = to.time - from.time
        let moved = ((to.tip - from.tip) * (to.tip - from.tip)).sum().squareRoot()
        return elapsed > 0.25 || moved <= 0.03 + 3 * Float(elapsed)
      }
      guard let last = lastRaw, !plausible(last, raw) else {
        accept(raw)
        held = nil
        return
      }
      if let held, plausible(held, raw) {
        accept(held)
        accept(raw)
        self.held = nil
      } else {
        held = raw
      }
    }

    private mutating func accept(_ raw: Sample) {
      lastRaw = raw
      samples.append(Sample(time: raw.time, tip: smoother?.filter(raw.tip, at: raw.time) ?? raw.tip))
    }

    public func tip(at time: Double, within tolerance: Double) -> SIMD2<Float>? {
      median(samples.filter { abs($0.time - time) <= tolerance }.map(\.tip))
    }

    public func travel(from start: Double, to end: Double) -> Float {
      let path = samples.filter { $0.time >= start && $0.time <= end }.map(\.tip)
      return zip(path, path.dropFirst()).reduce(0) { $0 + (($1.1 - $1.0) * ($1.1 - $1.0)).sum().squareRoot() }
    }
  }

  public private(set) var tracks: [Track] = []
  public private(set) var latestTime = -Double.infinity
  private var nextID = 0
  private let history = 1.5
  private let timeout = 0.6
  private let reach: Float = 0.12
  private let smoothing: OneEuroFilter.Parameters?

  public init(smoothing: OneEuroFilter.Parameters? = nil) {
    self.smoothing = smoothing
  }

  public mutating func update(with frame: HandFrame) -> [Int] {
    latestTime = frame.time
    tracks.removeAll { frame.time - $0.lastSeen > timeout }
    var claimed = Set<Int>()
    var ids: [Int] = []
    for hand in frame.hands {
      let center = hand.center
      let nearest = tracks.indices
        .filter { !claimed.contains($0) }
        .map { ($0, ((tracks[$0].hand.center - center) * (tracks[$0].hand.center - center)).sum().squareRoot()) }
        .min { $0.1 < $1.1 }
      let index: Int
      if let nearest, nearest.1 < reach {
        index = nearest.0
        tracks[index].hand = hand
        tracks[index].lastSeen = frame.time
      } else {
        index = tracks.count
        tracks.append(
          Track(id: nextID, hand: hand, lastSeen: frame.time, smoother: smoothing.map(OneEuroFilter.init)))
        nextID += 1
      }
      claimed.insert(index)
      if hand.tipConfidence >= HandObservation.minimumConfidence {
        tracks[index].add(Sample(time: frame.time, tip: hand.tip))
      }
      ids.append(tracks[index].id)
    }
    for index in tracks.indices { tracks[index].samples.removeAll { frame.time - $0.time > history } }
    return ids
  }

  public mutating func markDisplayed(_ id: Int) {
    guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
    tracks[index].displayed = true
  }
}
