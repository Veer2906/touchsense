import Foundation
import Testing
@testable import TapCore

@Suite struct ModelTests {
  static let grid = Grid(columns: 3, rows: 3)

  static func calibrated() throws -> (model: TapModel, session: CalibrationSession) {
    var generator = SeededGenerator(state: 7)
    let plan = CalibrationPlan.make(grid: grid, passes: 3, tapsPerTarget: 2, using: &generator)
    let spacing = Int(0.4 * Synth.sampleRate)
    let slot = 3 * spacing
    let knocks = 8
    let total = 72_000 + plan.targets.count * slot + (knocks + 4) * spacing
    var stream = Synth.noise(seconds: Double(total) / Synth.sampleRate, rms: 1e-4, using: &generator)

    for (index, target) in plan.targets.enumerated() {
      for repeatIndex in 0..<plan.tapsPerTarget {
        let amplitude = Float.random(in: 0.01...0.06, using: &generator)
        Synth.mix(
          Synth.hit(Synth.zone(target.zone), amplitude: amplitude, using: &generator),
          into: &stream, at: 72_000 + index * slot + repeatIndex * spacing)
      }
    }
    let knockStart = 72_000 + plan.targets.count * slot + 2 * spacing
    for index in 0..<knocks {
      Synth.mix(Synth.hit(Synth.knock, amplitude: 0.03, using: &generator), into: &stream, at: knockStart + index * spacing)
    }

    var session = CalibrationSession(plan: plan, startSample: 0, sampleRate: Synth.sampleRate)
    for candidate in Synth.candidates(in: stream) { _ = session.ingest(candidate, minSNRDB: 12) }

    let data = CalibrationData(
      sampleRate: Synth.sampleRate, grid: grid, taps: session.taps, negatives: session.negatives)
    let restored = try JSONDecoder().decode(CalibrationData.self, from: JSONEncoder().encode(data))
    return (try restored.makeModel(), session)
  }

  static func features(of voice: Synth.Voice, seed: UInt64, amplitude: Float = 0.03) throws -> [Float] {
    var generator = SeededGenerator(state: seed)
    var stream = Synth.noise(seconds: 2, rms: 1e-4, using: &generator)
    Synth.mix(Synth.hit(voice, amplitude: amplitude, using: &generator), into: &stream, at: 48_000)
    return try #require(Synth.candidates(in: stream).first).features
  }

  @Test func `calibration collects every tap then trains a model that generalises`() throws {
    let (model, session) = try Self.calibrated()
    #expect(session.phase == .negatives)
    #expect(session.taps.count == session.requiredTaps)
    #expect(session.negatives.count == 8)
    #expect(model.report.samples == 54)
    #expect(model.report.zoneAccuracy >= 0.85)

    var correct = 0
    var accepted = 0
    for zone in 0..<Self.grid.count {
      for trial in 0..<3 {
        let amplitude: Float = [0.008, 0.03, 0.08][trial]
        let result = model.classify(
          try Self.features(of: Synth.zone(zone), seed: UInt64(500 + zone * 10 + trial), amplitude: amplitude))
        if result.zone == zone { correct += 1 }
        if result.isTap { accepted += 1 }
      }
    }
    #expect(correct >= 24)
    #expect(accepted >= 24)
  }

  @Test func `taught non-taps and never-heard sounds are both rejected`() throws {
    let (model, _) = try Self.calibrated()
    for seed in 900..<905 {
      let knock = model.classify(try Self.features(of: Synth.knock, seed: UInt64(seed)))
      #expect(!knock.isTap)
      let ping = model.classify(try Self.features(of: Synth.ping, seed: UInt64(seed + 50)))
      #expect(!ping.isTap)
      #expect(ping.fit < 0.5)
    }
  }

  @Test func `training refuses a zone with fewer than two taps`() {
    let samples = (0..<8).map {
      TrainingSample(features: [Float($0), 1, 2], zone: $0 % 3, x: 0, y: 0, pass: $0 % 2)
    }
    #expect(throws: TrainingError.tooFewSamples(zone: 3, count: 0)) {
      try TapModel.train(taps: samples, negatives: [], grid: Grid(columns: 2, rows: 2), floors: [1, 1, 1])
    }
  }

  @Test(arguments: [Grid(columns: 2, rows: 2), Grid(columns: 3, rows: 3), Grid(columns: 4, rows: 3)])
  func `a plan visits every zone once per pass and stays inside it`(grid: Grid) {
    var generator = SeededGenerator(state: 11)
    let plan = CalibrationPlan.make(grid: grid, passes: 3, tapsPerTarget: 2, using: &generator)
    #expect(plan.targets.count == grid.count * 3)
    for pass in 0..<3 {
      #expect(Set(plan.targets.filter { $0.pass == pass }.map(\.zone)).count == grid.count)
    }
    for target in plan.targets {
      #expect(Int(target.x * Float(grid.columns)) == grid.column(of: target.zone))
      #expect(Int(target.y * Float(grid.rows)) == grid.row(of: target.zone))
    }
  }

  @Test func `cholesky factor reproduces the matrix and solves against it`() throws {
    var generator = SeededGenerator(state: 13)
    let size = 12
    let basis = (0..<size * size).map { _ in Double(Synth.gaussian(using: &generator)) }
    var matrix = [Double](repeating: 0, count: size * size)
    for row in 0..<size {
      for column in 0..<size {
        for k in 0..<size { matrix[row * size + column] += basis[row * size + k] * basis[column * size + k] }
      }
      matrix[row * size + row] += 1
    }
    let factor = try #require(cholesky(matrix, dimension: size))
    for row in 0..<size {
      for column in 0..<size {
        let product = (0..<size).reduce(0.0) { $0 + factor[row * size + $1] * factor[column * size + $1] }
        #expect(abs(product - matrix[row * size + column]) < 1e-9)
      }
    }
    let vector = (0..<size).map { Double($0) - 3 }
    let solution = forwardSolve(factor, dimension: size, vector)
    for row in 0..<size {
      let product = (0...row).reduce(0.0) { $0 + factor[row * size + $1] * solution[$1] }
      #expect(abs(product - vector[row]) < 1e-9)
    }
    #expect(cholesky([1, 2, 2, 1], dimension: 2) == nil)
  }

  @Test func `wav files round-trip`() throws {
    var generator = SeededGenerator(state: 17)
    let samples = Synth.noise(seconds: 0.1, rms: 0.1, using: &generator)
    let url = FileManager.default.temporaryDirectory.appending(path: "tapcore-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try WAVWriter(url: url, sampleRate: Synth.sampleRate)
    try writer.append(Array(samples[..<2000]))
    try writer.append(Array(samples[2000...]))
    try writer.close()
    let restored = try WAVReader.read(url)
    #expect(restored.sampleRate == Synth.sampleRate)
    #expect(restored.samples == samples)
  }
}
