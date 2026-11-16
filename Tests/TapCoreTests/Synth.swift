import Foundation
import TapCore

struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

enum Synth {
  static let sampleRate = 48_000.0

  struct Voice {
    var modes: [(frequency: Float, gain: Float)]
    var echoes: [(delay: Int, gain: Float)]
    var brightness: Float
    var burstDecay: Float = 0.003
    var modeDecay: Float = 0.012
    var thump: Float = 0
  }

  static func gaussian(using generator: inout SeededGenerator) -> Float {
    let u = Float.random(in: Float.leastNonzeroMagnitude..<1, using: &generator)
    let v = Float.random(in: 0..<1, using: &generator)
    return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
  }

  static func noise(seconds: Double, rms: Float, using generator: inout SeededGenerator) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { _ in rms * gaussian(using: &generator) }
  }

  static func zone(_ index: Int) -> Voice {
    var generator = SeededGenerator(state: UInt64(index) &+ 1000)
    return Voice(
      modes: (0..<3).map { _ in
        (.random(in: 350...2500, using: &generator), .random(in: 0.1...1, using: &generator))
      },
      echoes: (0..<3).map { _ in
        (.random(in: 10...200, using: &generator), .random(in: -0.8...0.8, using: &generator))
      },
      brightness: .random(in: 0.15...0.9, using: &generator), thump: 1)
  }

  static let knock = Voice(
    modes: [(380, 1), (520, 0.8)], echoes: [(90, 0.5)], brightness: 0.04,
    burstDecay: 0.006, modeDecay: 0.02)

  static let ping = Voice(
    modes: [(6200, 1), (9100, 0.7)], echoes: [], brightness: 0.95,
    burstDecay: 0.001, modeDecay: 0.03)

  static func hit(_ voice: Voice, amplitude: Float, using generator: inout SeededGenerator) -> [Float] {
    let count = Int(0.08 * sampleRate)
    let rate = Float(sampleRate)
    let pole = min(voice.brightness * .random(in: 0.9...1.1, using: &generator), 1)
    var smoothed: Float = 0
    var dry = [Float](repeating: 0, count: count)
    let phases = voice.modes.map { _ in Float.random(in: 0..<(2 * .pi), using: &generator) }
    for index in 0..<count {
      let time = Float(index) / rate
      smoothed += pole * (gaussian(using: &generator) * exp(-time / voice.burstDecay) - smoothed)
      var value = smoothed
      for (mode, phase) in zip(voice.modes, phases) {
        value += 0.3 * mode.gain * sin(2 * .pi * mode.frequency * time + phase) * exp(-time / voice.modeDecay)
      }
      value += voice.thump * sin(2 * .pi * 140 * time) * exp(-time / 0.02)
      dry[index] = value
    }
    var wet = dry
    for echo in voice.echoes {
      for index in echo.delay..<count { wet[index] += echo.gain * dry[index - echo.delay] }
    }
    let peak = wet.map(abs).max() ?? 1
    return wet.map { $0 * amplitude / peak }
  }

  static func mix(_ sound: [Float], into stream: inout [Float], at sample: Int) {
    for index in sound.indices where sample + index < stream.count { stream[sample + index] += sound[index] }
  }

  static func candidates(in stream: [Float]) -> [TapCandidate] {
    var pipeline = TapPipeline(sampleRate: sampleRate)
    var found: [TapCandidate] = []
    var position = 0
    while position < stream.count {
      let end = min(stream.count, position + 512)
      found += pipeline.process(Array(stream[position..<end])).candidates
      position = end
    }
    return found
  }
}
