import Foundation
import Testing
@testable import TapCore

@Suite struct PointerTests {
  static let camera = Homography(elements: [0.52, 0.11, 0.2, -0.06, 0.48, 0.25, 0.18, 0.09, 1])
  static let aspect: Float = 1.54

  static func hand(at tip: SIMD2<Float>, spread: Float = 0.06) -> HandObservation {
    let joints = (0..<HandObservation.jointCount).map { index -> SIMD2<Float> in
      let finger = Float((index + 3) / 4)
      let segment = Float((index + 3) % 4)
      return index == HandObservation.indexTip
        ? tip : tip + SIMD2(spread * (finger - 2) * 0.4, spread * (2.5 - segment * 0.5))
    }
    return HandObservation(joints: joints, confidences: [Float](repeating: 0.9, count: HandObservation.jointCount))
  }

  @Test func `a homography is recovered from point pairs and inverts`() throws {
    var generator = SeededGenerator(state: 21)
    let source = (0..<16).map { _ in
      SIMD2<Float>(.random(in: 0...1, using: &generator), .random(in: 0...1, using: &generator))
    }
    let fitted = try #require(Homography.fit(from: source, to: source.map(Self.camera.apply)))
    let inverse = try #require(fitted.inverse)
    for point in source {
      let mapped = fitted.apply(point)
      let expected = Self.camera.apply(point)
      #expect(abs(mapped.x - expected.x) < 1e-4 && abs(mapped.y - expected.y) < 1e-4)
      let back = inverse.apply(mapped)
      #expect(abs(back.x - point.x) < 1e-4 && abs(back.y - point.y) < 1e-4)
    }
    #expect(Homography.fit(from: Array(source.prefix(3)), to: Array(source.prefix(3))) == nil)
  }

  @Test func `calibration recovers the mapping and the camera lag from moving fingertips`() throws {
    var generator = SeededGenerator(state: 22)
    let toCamera = try #require(Self.camera.inverse)
    let trueLag = 0.09
    let samples = PointerCalibration.targets(columns: 4, rows: 4, inset: 0.08).map { target -> PointerSample in
      let contact = toCamera.apply(target)
      let approach = contact + SIMD2(.random(in: -0.2...0.2, using: &generator), .random(in: 0.1...0.25, using: &generator))
      var offsets: [Double] = []
      var tips: [SIMD2<Float>] = []
      var offset = -0.15 + Double.random(in: 0..<0.033, using: &generator)
      while offset < 0.45 {
        let sinceTouch = offset - trueLag
        let away = Float(sinceTouch < -0.03 ? min(1, (-sinceTouch - 0.03) / 0.2) : sinceTouch > 0.1 ? min(1, (sinceTouch - 0.1) / 0.2) : 0)
        let noise = SIMD2<Float>(Synth.gaussian(using: &generator), Synth.gaussian(using: &generator)) * 0.0008
        offsets.append(offset)
        tips.append(contact + (approach - contact) * away + noise)
        offset += 1.0 / 30
      }
      return PointerSample(target: target, offsets: offsets, tips: tips)
    }

    let mapping = try #require(PointerCalibration.solve(samples, aspect: Self.aspect))
    #expect(abs(mapping.lag - (trueLag + 0.035)) < 0.05)
    #expect(mapping.error < 0.01)
    #expect(mapping.samples >= 14)
    let probe = SIMD2<Float>(0.4, 0.7)
    let mapped = mapping.homography.apply(toCamera.apply(probe))
    #expect(abs(mapped.x - probe.x) < 0.01 && abs(mapped.y - probe.y) < 0.01)
  }

  @Test func `calibration discards a tap whose fingertip was somewhere else`() throws {
    let toCamera = try #require(Self.camera.inverse)
    var samples = PointerCalibration.targets(columns: 4, rows: 4, inset: 0.08).map { target in
      PointerSample(target: target, offsets: [-0.03, 0, 0.03, 0.06], tips: [SIMD2<Float>](repeating: toCamera.apply(target), count: 4))
    }
    samples[5].tips = samples[5].tips.map { $0 + SIMD2(0.2, -0.15) }
    let mapping = try #require(PointerCalibration.solve(samples, aspect: Self.aspect))
    #expect(mapping.samples == 15)
    #expect(mapping.error < 0.002)
  }

  @Test func `tracks keep their identity while hands move and expire when they leave`() {
    var tracker = HandTracker()
    var first: [Int] = []
    for step in 0..<30 {
      let time = Double(step) / 30
      let ids = tracker.update(
        with: HandFrame(time: time, hands: [
          Self.hand(at: SIMD2(0.2 + 0.01 * Float(step), 0.3)), Self.hand(at: SIMD2(0.8, 0.7 - 0.005 * Float(step))),
        ]))
      if step == 0 { first = ids }
      #expect(ids == first)
    }
    #expect(tracker.tracks.count == 2)
    _ = tracker.update(with: HandFrame(time: 2, hands: [Self.hand(at: SIMD2(0.5, 0.3))]))
    #expect(tracker.tracks.count == 1)
    #expect(!first.contains(tracker.tracks[0].id))
  }

  @Test func `a fingertip that teleports for one frame is dropped, a real relocation is kept`() {
    var tracker = HandTracker()
    for step in 0..<40 {
      var tip = SIMD2<Float>(0.4 + 0.002 * Float(step), 0.5)
      if step == 20 { tip = SIMD2(0.8, 0.1) }
      if step >= 30 { tip = SIMD2(0.42 + 0.01 * Float(step - 30), 0.3) }
      var hand = Self.hand(at: SIMD2(0.4, 0.5))
      hand.joints[HandObservation.indexTip] = tip
      _ = tracker.update(with: HandFrame(time: Double(step) / 60, hands: [hand]))
    }
    let samples = tracker.tracks[0].samples
    #expect(!samples.contains { $0.tip.x > 0.7 })
    #expect(samples.count == 39)
    #expect(samples.last?.tip.y == 0.3)
  }

  @Test func `a tap goes to the finger that moved in, not a still, displayed or off-screen hand`() throws {
    let toCamera = try #require(Self.camera.inverse)
    let mapping = PointerMapping(homography: Self.camera, lag: 0.05, error: 0.005, samples: 16)
    let touch = SIMD2<Float>(0.62, 0.41)
    var tracker = HandTracker()
    var shownID = -1
    for step in 0..<45 {
      let time = Double(step) / 30
      let progress = Float(min(1, max(0, (0.95 - time) / 0.4)))
      let ids = tracker.update(
        with: HandFrame(time: time, hands: [
          Self.hand(at: toCamera.apply(touch) + SIMD2(0.1, 0.2) * progress),
          Self.hand(at: toCamera.apply(SIMD2(0.2, 0.2))),
          Self.hand(at: toCamera.apply(SIMD2(0.8, 0.8)) + SIMD2(0.05, 0) * progress),
          Self.hand(at: toCamera.apply(SIMD2(1.6, 0.5)) + SIMD2(0.1, 0.1) * progress),
        ]))
      shownID = ids[2]
    }
    tracker.markDisplayed(shownID)

    let resolved = try #require(TouchResolver.resolve(tracks: tracker.tracks, tapTime: 1.0, mapping: mapping))
    #expect(abs(resolved.screen.x - touch.x) < 0.01 && abs(resolved.screen.y - touch.y) < 0.01)
    #expect(TouchResolver.resolve(tracks: tracker.tracks, tapTime: 5.0, mapping: mapping) == nil)
  }

  @Test func `a hand that lines up with one in the screen image is recognised as displayed`() throws {
    let toCamera = try #require(Self.camera.inverse)
    let onScreen = Self.hand(at: SIMD2(0.5, 0.4), spread: 0.05)
    let seen = HandObservation(joints: onScreen.joints.map(toCamera.apply), confidences: onScreen.confidences)
    #expect(DisplayedHands.matches(seen, mappedBy: Self.camera, against: [onScreen], aspect: Self.aspect))

    let real = HandObservation(joints: seen.joints.map { $0 + SIMD2(0.12, 0.05) }, confidences: seen.confidences)
    #expect(!DisplayedHands.matches(real, mappedBy: Self.camera, against: [onScreen], aspect: Self.aspect))
    #expect(!DisplayedHands.matches(seen, mappedBy: Self.camera, against: [], aspect: Self.aspect))
  }
}
