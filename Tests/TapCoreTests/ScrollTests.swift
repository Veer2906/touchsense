import Foundation
import Testing
import TapCore

@Suite struct ScrollTests {
  static let identity = Homography(elements: [1, 0, 0, 0, 1, 0, 0, 0, 1])

  static func hand(at tip: SIMD2<Float>, extended: Set<Int>) -> HandObservation {
    var joints = [SIMD2<Float>](repeating: tip + SIMD2(0, 0.3), count: HandObservation.jointCount)
    for finger in 1...4 {
      let base = tip + SIMD2(0.03 * Float(finger - 1), 0.16)
      let step: SIMD2<Float> = extended.contains(finger) ? SIMD2(0, -0.053) : SIMD2(0.004, -0.02)
      for segment in 0..<4 {
        let fold: Float = extended.contains(finger) || segment < 2 ? 1 : -0.5
        joints[1 + finger * 4 + segment] =
          segment == 0 ? base : joints[finger * 4 + segment] + step * fold
      }
    }
    return HandObservation(joints: joints, confidences: [Float](repeating: 0.9, count: HandObservation.jointCount))
  }

  @Test func `two straight fingers side by side are the scroll pose, one finger or a spread pair is not`() {
    #expect(ScrollPose.matches(Self.hand(at: SIMD2(0.5, 0.4), extended: [1, 2]), aspect: 1))
    #expect(ScrollPose.matches(Self.hand(at: SIMD2(0.5, 0.4), extended: [1, 2, 3, 4]), aspect: 1))
    #expect(!ScrollPose.matches(Self.hand(at: SIMD2(0.5, 0.4), extended: [1]), aspect: 1))
    #expect(!ScrollPose.matches(Self.hand(at: SIMD2(0.5, 0.4), extended: []), aspect: 1))

    var spread = Self.hand(at: SIMD2(0.5, 0.4), extended: [1, 2])
    for joint in 10...12 { spread.joints[joint].x += 0.04 * Float(joint - 9) }
    #expect(!ScrollPose.matches(spread, aspect: 1))

    var unsure = Self.hand(at: SIMD2(0.5, 0.4), extended: [1, 2])
    unsure.confidences[12] = 0.1
    #expect(!ScrollPose.matches(unsure, aspect: 1))
  }

  @Test func `a held pose starts a scroll, follows the fingers, rides out a dropped frame and ends when released`() throws {
    var gesture = ScrollGesture()
    var updates: [ScrollGesture.Update] = []
    var travelled: Float = 0
    for step in 0..<60 {
      let time = Double(step) / 60
      let y = 0.3 + 0.004 * Float(min(step, 40))
      let posed = step < 40 && step != 20
      let hand = Self.hand(at: SIMD2(0.5, y), extended: posed ? [1, 2] : [1])
      if let update = gesture.update(hands: [(id: 7, hand: hand)], time: time, aspect: 1, homography: Self.identity) {
        updates.append(update)
        travelled += update.delta.y
      }
    }
    let first = try #require(updates.first)
    #expect(first.began)
    #expect(first.delta == .zero)
    #expect(updates.dropFirst().allSatisfy { !$0.began })
    #expect(updates.count >= 30)
    #expect(abs(travelled - 0.004 * 34) < 0.02)
    #expect(gesture.activeHand == nil)
  }

  @Test func `a one-finger hand never scrolls and a pose off the screen is ignored`() {
    var gesture = ScrollGesture()
    for step in 0..<30 {
      let time = Double(step) / 60
      let pointing = Self.hand(at: SIMD2(0.5, 0.3 + 0.01 * Float(step)), extended: [1])
      let outside = Self.hand(at: SIMD2(1.4, 0.5), extended: [1, 2])
      #expect(
        gesture.update(
          hands: [(id: 1, hand: pointing), (id: 2, hand: outside)], time: time, aspect: 1, homography: Self.identity)
          == nil)
    }
  }
}
