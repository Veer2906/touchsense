import Foundation

public struct OneEuroFilter: Sendable {
  public struct Parameters: Sendable {
    public var minimumCutoff: Float
    public var speedGain: Float
    public var derivativeCutoff: Float = 1

    public init(minimumCutoff: Float, speedGain: Float) {
      self.minimumCutoff = minimumCutoff
      self.speedGain = speedGain
    }
  }

  private let parameters: Parameters
  private var value: SIMD2<Float>?
  private var velocity = SIMD2<Float>.zero
  private var time = 0.0

  public init(_ parameters: Parameters) {
    self.parameters = parameters
  }

  public mutating func filter(_ point: SIMD2<Float>, at time: Double) -> SIMD2<Float> {
    guard let previous = value, time > self.time, time - self.time < 0.25 else {
      value = point
      velocity = .zero
      self.time = time
      return point
    }
    let elapsed = Float(time - self.time)
    func blend(cutoff: Float) -> Float {
      let tau = 1 / (2 * .pi * cutoff)
      return 1 / (1 + tau / elapsed)
    }
    let rawVelocity = (point - previous) / elapsed
    velocity += blend(cutoff: parameters.derivativeCutoff) * (rawVelocity - velocity)
    let speed = (velocity * velocity).sum().squareRoot()
    let smoothed = previous + blend(cutoff: parameters.minimumCutoff + parameters.speedGain * speed) * (point - previous)
    value = smoothed
    self.time = time
    return smoothed
  }
}
