import Foundation
import Testing
import TapCore

@Suite struct DetectionTests {
  @Test func `every tap is found and timed to within a millisecond`() {
    var generator = SeededGenerator(state: 1)
    var stream = Synth.noise(seconds: 8, rms: 1e-4, using: &generator)
    let starts = (0..<12).map { 48_000 + $0 * 24_000 + Int.random(in: 0..<4000, using: &generator) }
    for (index, start) in starts.enumerated() {
      let amplitude = Float.random(in: 0.004...0.06, using: &generator)
      Synth.mix(Synth.hit(Synth.zone(index % 9), amplitude: amplitude, using: &generator), into: &stream, at: start)
    }

    let pipeline = TapPipeline(sampleRate: Synth.sampleRate)
    let found = Synth.candidates(in: stream)
    #expect(found.count == starts.count)
    for (candidate, start) in zip(found, starts) {
      #expect(abs(candidate.onsetSample - start) <= 48)
      #expect(pipeline.analyzer.rejection(for: candidate.shape) == nil)
    }
  }

  @Test func `steady room noise with hum and slow drift never triggers`() {
    var generator = SeededGenerator(state: 2)
    var stream = Synth.noise(seconds: 20, rms: 2e-4, using: &generator)
    for index in stream.indices {
      let time = Float(index) / Float(Synth.sampleRate)
      stream[index] *= 1 + 0.4 * sin(2 * .pi * 0.2 * time)
      stream[index] += 1e-3 * sin(2 * .pi * 60 * time)
    }
    #expect(Synth.candidates(in: stream).isEmpty)
  }

  @Test func `a sustained noise burst is heard but not called a tap`() {
    var generator = SeededGenerator(state: 3)
    var stream = Synth.noise(seconds: 3, rms: 1e-4, using: &generator)
    Synth.mix(Synth.noise(seconds: 0.3, rms: 0.02, using: &generator), into: &stream, at: 72_000)

    let pipeline = TapPipeline(sampleRate: Synth.sampleRate)
    let found = Synth.candidates(in: stream)
    #expect(!found.isEmpty)
    for candidate in found { #expect(pipeline.analyzer.rejection(for: candidate.shape) != nil) }
  }

  @Test func `a tone that swells in is not called a tap`() {
    var generator = SeededGenerator(state: 4)
    var stream = Synth.noise(seconds: 3, rms: 1e-4, using: &generator)
    for index in 0..<24_000 {
      let time = Float(index) / Float(Synth.sampleRate)
      let envelope = min(1, time / 0.04)
      let value = sin(2 * .pi * 900 * time) + 0.5 * sin(2 * .pi * 1800 * time) + 0.3 * sin(2 * .pi * 3600 * time)
      stream[72_000 + index] += 0.02 * envelope * value
    }

    let pipeline = TapPipeline(sampleRate: Synth.sampleRate)
    for candidate in Synth.candidates(in: stream) {
      #expect(pipeline.analyzer.rejection(for: candidate.shape) != nil)
    }
  }

  @Test func `a sharp click with no thump through the laptop body is not called a tap`() throws {
    var generator = SeededGenerator(state: 6)
    var stream = Synth.noise(seconds: 3, rms: 1e-4, using: &generator)
    for index in stream.indices {
      stream[index] += 3e-4 * sin(2 * .pi * 90 * Float(index) / Float(Synth.sampleRate))
    }
    Synth.mix(Synth.hit(Synth.ping, amplitude: 0.02, using: &generator), into: &stream, at: 72_000)

    let pipeline = TapPipeline(sampleRate: Synth.sampleRate)
    let click = try #require(Synth.candidates(in: stream).first)
    #expect(pipeline.analyzer.rejection(for: click.shape) == .airborne)
  }

  @Test func `two taps 200 ms apart are separate events`() {
    var generator = SeededGenerator(state: 5)
    var stream = Synth.noise(seconds: 3, rms: 1e-4, using: &generator)
    for start in [72_000, 81_600] {
      Synth.mix(Synth.hit(Synth.zone(4), amplitude: 0.03, using: &generator), into: &stream, at: start)
    }
    #expect(Synth.candidates(in: stream).count == 2)
  }
}
