import Foundation

public struct PointerMapping: Sendable, Codable {
  public var homography: Homography
  public var lag: Double
  public var error: Float
  public var samples: Int
}

public struct PointerSample: Sendable, Codable {
  public var target: SIMD2<Float>
  public var offsets: [Double]
  public var tips: [SIMD2<Float>]

  public init(target: SIMD2<Float>, offsets: [Double], tips: [SIMD2<Float>]) {
    self.target = target
    self.offsets = offsets
    self.tips = tips
  }

  public func tip(at lag: Double) -> SIMD2<Float>? {
    median(zip(offsets, tips).filter { abs($0.0 - lag) <= PointerCalibration.window }.map(\.1))
  }
}

public enum PointerCalibration {
  public static let window = 0.03

  public static func targets(columns: Int, rows: Int, inset: Float) -> [SIMD2<Float>] {
    let span = 1 - 2 * inset
    var targets: [SIMD2<Float>] = []
    for row in 0..<rows {
      for column in 0..<columns {
        let x = inset + span * Float(column) / Float(columns - 1)
        let y = inset + span * Float(row) / Float(rows - 1)
        targets.append(SIMD2(x, y))
      }
    }
    return targets
  }

  public static func sample(
    target: SIMD2<Float>, tapTime: Double, tracks: [HandTracker.Track]
  ) -> PointerSample? {
    let window = (tapTime - 0.15)...(tapTime + 0.45)
    func travel(_ track: HandTracker.Track) -> Float { track.travel(from: tapTime - 0.5, to: tapTime + 0.3) }
    let mover = tracks
      .filter { track in track.samples.contains { window.contains($0.time) } }
      .max { travel($0) < travel($1) }
    guard let mover else { return nil }
    let seen = mover.samples.filter { window.contains($0.time) }
    return PointerSample(target: target, offsets: seen.map { $0.time - tapTime }, tips: seen.map(\.tip))
  }

  public static func solve(_ samples: [PointerSample], aspect: Float) -> PointerMapping? {
    typealias Pair = (tip: SIMD2<Float>, target: SIMD2<Float>)
    func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
      let offset = (a - b) * SIMD2(1, 1 / aspect)
      return (offset * offset).sum().squareRoot()
    }
    func pairs(at lag: Double) -> [Pair] {
      samples.compactMap { sample in sample.tip(at: lag).map { ($0, sample.target) } }
    }
    func fit(_ pairs: [Pair]) -> Homography? {
      Homography.fit(from: pairs.map(\.tip), to: pairs.map(\.target))
    }

    let required = max(6, samples.count * 3 / 4)
    var trials: [(lag: Double, error: Float)] = []
    for step in 0...50 {
      let lag = -0.10 + 0.01 * Double(step)
      let candidates = pairs(at: lag)
      guard candidates.count >= required, let homography = fit(candidates) else { continue }
      let squares = candidates.map { distance(homography.apply($0.tip), $0.target) }.map { $0 * $0 }
      trials.append((lag, (squares.reduce(0, +) / Float(squares.count)).squareRoot()))
    }
    guard let best = trials.min(by: { $0.error < $1.error }) else { return nil }
    let plateau = trials.filter { $0.error <= 1.15 * best.error + 1e-5 }.map(\.lag)
    let lag = plateau.reduce(0, +) / Double(plateau.count)

    var kept = pairs(at: lag)
    guard var homography = fit(kept) else { return nil }
    while kept.count > 6 {
      let residuals = kept.map { distance(homography.apply($0.tip), $0.target) }
      guard
        let worst = residuals.indices.max(by: { residuals[$0] < residuals[$1] }),
        residuals[worst] > max(3 * (median(residuals) ?? 0), 0.015)
      else { break }
      var trimmed = kept
      trimmed.remove(at: worst)
      guard let refit = fit(trimmed) else { break }
      kept = trimmed
      homography = refit
    }

    let heldOut: [Float] = kept.indices.compactMap { index in
      var others = kept
      let left = others.remove(at: index)
      return fit(others).map { distance($0.apply(left.tip), left.target) }
    }
    guard let error = median(heldOut) else { return nil }
    return PointerMapping(homography: homography, lag: lag, error: error, samples: kept.count)
  }
}

public enum TouchResolver {
  public static func resolve(
    tracks: [HandTracker.Track], tapTime: Double, mapping: PointerMapping
  ) -> (track: Int, screen: SIMD2<Float>)? {
    let moment = tapTime + mapping.lag
    let bounds: ClosedRange<Float> = -0.04...1.04
    let candidates = tracks.compactMap { track -> (id: Int, screen: SIMD2<Float>, travel: Float)? in
      guard !track.displayed, let tip = track.tip(at: moment, within: PointerCalibration.window) else {
        return nil
      }
      let screen = mapping.homography.apply(tip)
      guard bounds.contains(screen.x), bounds.contains(screen.y) else { return nil }
      return (track.id, screen, track.travel(from: moment - 0.4, to: moment))
    }
    return candidates.max { $0.travel < $1.travel }.map { ($0.id, $0.screen) }
  }
}

public enum DisplayedHands {
  public static func matches(
    _ hand: HandObservation, mappedBy homography: Homography, against screenHands: [HandObservation],
    aspect: Float
  ) -> Bool {
    let stretch = SIMD2<Float>(aspect, 1)
    let mapped = hand.joints.map { homography.apply($0) * stretch }
    return screenHands.contains { candidate in
      var total: Float = 0
      var count = 0
      var low = SIMD2<Float>(repeating: .infinity)
      var high = SIMD2<Float>(repeating: -.infinity)
      for index in 0..<HandObservation.jointCount
      where candidate.confidences[index] >= HandObservation.minimumConfidence {
        let joint = candidate.joints[index] * stretch
        low = pointwiseMin(low, joint)
        high = pointwiseMax(high, joint)
        guard hand.confidences[index] >= HandObservation.minimumConfidence else { continue }
        total += ((mapped[index] - joint) * (mapped[index] - joint)).sum().squareRoot()
        count += 1
      }
      guard count >= 8 else { return false }
      let size = ((high - low) * (high - low)).sum().squareRoot()
      return total / Float(count) < 0.3 * size
    }
  }
}
