import Foundation

public enum ScrollPose {
  private static let index = (base: 5, middle: 6, far: 7, tip: 8)
  private static let middle = (base: 9, middle: 10, far: 11, tip: 12)

  public static func matches(_ hand: HandObservation, aspect: Float) -> Bool {
    let stretch = SIMD2<Float>(aspect, 1)
    func offset(_ from: Int, _ to: Int) -> SIMD2<Float> { (hand.joints[to] - hand.joints[from]) * stretch }
    func length(_ vector: SIMD2<Float>) -> Float { (vector * vector).sum().squareRoot() }
    func straightness(_ finger: (base: Int, middle: Int, far: Int, tip: Int)) -> Float {
      let chain =
        length(offset(finger.base, finger.middle)) + length(offset(finger.middle, finger.far))
        + length(offset(finger.far, finger.tip))
      return chain > 0 ? length(offset(finger.base, finger.tip)) / chain : 0
    }

    let confident = [index.base, index.tip, middle.base, middle.tip]
      .allSatisfy { hand.confidences[$0] >= HandObservation.minimumConfidence }
    let pointing = offset(index.base, index.tip)
    let reach = length(pointing)
    guard confident, reach > 0 else { return false }
    let alongside = (offset(middle.base, middle.tip) * pointing).sum() / (reach * reach)
    let apart = length(offset(index.tip, middle.tip)) / reach
    return straightness(index) > 0.95 && straightness(middle) > 0.95 && alongside > 0.8 && apart < 0.45
  }

  public static func point(of hand: HandObservation) -> SIMD2<Float> {
    (hand.joints[index.tip] + hand.joints[middle.tip]) / 2
  }
}

public struct ScrollGesture: Sendable {
  public struct Update: Sendable {
    public let began: Bool
    public let position: SIMD2<Float>
    public let delta: SIMD2<Float>
  }

  public private(set) var activeHand: Int?
  public private(set) var lastActive = -Double.infinity

  private var posedSince: [Int: Double] = [:]
  private var lastPosed = 0.0
  private var position = SIMD2<Float>.zero
  private var smoother = OneEuroFilter(ScrollGesture.smoothing)

  private static let smoothing = OneEuroFilter.Parameters(minimumCutoff: 3, speedGain: 10)
  private let settle = 0.08
  private let grace = 0.12

  public init() {}

  public mutating func update(
    hands: [(id: Int, hand: HandObservation)], time: Double, aspect: Float, homography: Homography
  ) -> Update? {
    let bounds: ClosedRange<Float> = -0.05...1.05
    let posed = hands.filter { entry in
      guard ScrollPose.matches(entry.hand, aspect: aspect) else { return false }
      let screen = homography.apply(ScrollPose.point(of: entry.hand))
      return bounds.contains(screen.x) && bounds.contains(screen.y)
    }
    posedSince = posedSince.filter { id, _ in posed.contains { $0.id == id } }
    for entry in posed where posedSince[entry.id] == nil { posedSince[entry.id] = time }

    if let active = activeHand {
      guard let entry = posed.first(where: { $0.id == active }) else {
        if time - lastPosed > grace { activeHand = nil }
        return nil
      }
      lastPosed = time
      lastActive = time
      let current = homography.apply(smoother.filter(ScrollPose.point(of: entry.hand), at: time))
      defer { position = current }
      return Update(began: false, position: current, delta: current - position)
    }

    guard let entry = posed.first(where: { time - (posedSince[$0.id] ?? time) >= settle }) else { return nil }
    activeHand = entry.id
    lastPosed = time
    lastActive = time
    smoother = OneEuroFilter(Self.smoothing)
    position = homography.apply(smoother.filter(ScrollPose.point(of: entry.hand), at: time))
    return Update(began: true, position: position, delta: .zero)
  }
}
