import Foundation

public struct StoredSnippet: Sendable, Codable {
  public var samples: Data
  public var triggerStart: Int
  public var triggerEnd: Int
  public var onsetSample: Int
  public var zone: Int?
  public var x: Float?
  public var y: Float?
  public var pass: Int?

  public init(_ candidate: TapCandidate, target: CalibrationPlan.Target? = nil) {
    samples = candidate.snippet.withUnsafeBufferPointer { Data(buffer: $0) }
    triggerStart = candidate.trigger.lowerBound
    triggerEnd = candidate.trigger.upperBound
    onsetSample = candidate.onsetSample
    zone = target?.zone
    x = target?.x
    y = target?.y
    pass = target?.pass
  }

  public var floats: [Float] {
    samples.withUnsafeBytes { bytes in
      (0..<bytes.count / 4).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
  }
}

public struct CalibrationData: Sendable, Codable {
  public var version = 1
  public var createdAt = Date()
  public var sampleRate: Double
  public var grid: Grid
  public var taps: [StoredSnippet]
  public var negatives: [StoredSnippet]

  public init(sampleRate: Double, grid: Grid, taps: [StoredSnippet], negatives: [StoredSnippet]) {
    self.sampleRate = sampleRate
    self.grid = grid
    self.taps = taps
    self.negatives = negatives
  }

  public func makeModel(config: AnalyzerConfig = AnalyzerConfig()) throws -> TapModel {
    var analyzer = EventAnalyzer(sampleRate: sampleRate, config: config)
    var samples: [TrainingSample] = []
    for tap in taps {
      guard
        let zone = tap.zone, let x = tap.x, let y = tap.y,
        let analysis = analyzer.analyze(tap.floats, trigger: tap.triggerStart..<tap.triggerEnd)
      else { continue }
      samples.append(
        TrainingSample(features: analysis.features, zone: zone, x: x, y: y, pass: tap.pass ?? 0))
    }
    let others = negatives.compactMap {
      analyzer.analyze($0.floats, trigger: $0.triggerStart..<$0.triggerEnd)?.features
    }
    return try TapModel.train(
      taps: samples, negatives: others, grid: grid, floors: analyzer.featureFloors)
  }
}

public struct CalibrationPlan: Sendable {
  public struct Target: Sendable, Equatable {
    public let zone: Int
    public let x: Float
    public let y: Float
    public let pass: Int
  }

  public let grid: Grid
  public let tapsPerTarget: Int
  public let targets: [Target]

  public static func make(
    grid: Grid, passes: Int, tapsPerTarget: Int, using generator: inout some RandomNumberGenerator
  ) -> CalibrationPlan {
    var targets: [Target] = []
    for pass in 0..<passes {
      for zone in (0..<grid.count).shuffled(using: &generator) {
        let x = (Float(grid.column(of: zone)) + .random(in: 0.2...0.8, using: &generator)) / Float(grid.columns)
        let y = (Float(grid.row(of: zone)) + .random(in: 0.2...0.8, using: &generator)) / Float(grid.rows)
        targets.append(Target(zone: zone, x: x, y: y, pass: pass))
      }
    }
    return CalibrationPlan(grid: grid, tapsPerTarget: tapsPerTarget, targets: targets)
  }
}

public struct CalibrationSession: Sendable {
  public enum Phase: Sendable, Equatable {
    case taps
    case negatives
  }

  public let plan: CalibrationPlan
  public private(set) var phase = Phase.taps
  public private(set) var targetIndex = 0
  public private(set) var hits = 0
  public private(set) var taps: [StoredSnippet] = []
  public private(set) var negatives: [StoredSnippet] = []

  private var quietUntil: Int
  private let settle: Int

  public init(plan: CalibrationPlan, startSample: Int, sampleRate: Double) {
    self.plan = plan
    settle = Int(0.5 * sampleRate)
    quietUntil = startSample + settle
  }

  public var target: CalibrationPlan.Target? {
    phase == .taps ? plan.targets[targetIndex] : nil
  }
  public var requiredTaps: Int { plan.targets.count * plan.tapsPerTarget }

  public mutating func ingest(_ candidate: TapCandidate, minSNRDB: Float) -> Bool {
    guard candidate.onsetSample >= quietUntil, candidate.shape.snrDB >= minSNRDB else { return false }
    guard let target else {
      negatives.append(StoredSnippet(candidate))
      return true
    }
    taps.append(StoredSnippet(candidate, target: target))
    hits += 1
    if hits == plan.tapsPerTarget {
      hits = 0
      targetIndex += 1
      quietUntil = candidate.onsetSample + settle
      if targetIndex == plan.targets.count {
        phase = .negatives
        quietUntil += settle
      }
    }
    return true
  }
}
