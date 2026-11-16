import Foundation

public struct Grid: Sendable, Codable, Equatable {
  public var columns: Int
  public var rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
  }

  public var count: Int { columns * rows }
  public func column(of zone: Int) -> Int { zone % columns }
  public func row(of zone: Int) -> Int { zone / columns }

  public func center(of zone: Int) -> SIMD2<Float> {
    SIMD2(
      (Float(column(of: zone)) + 0.5) / Float(columns),
      (Float(row(of: zone)) + 0.5) / Float(rows))
  }
}

public struct TrainingSample: Sendable {
  public var features: [Float]
  public var zone: Int
  public var x: Float
  public var y: Float
  public var pass: Int

  public init(features: [Float], zone: Int, x: Float, y: Float, pass: Int) {
    self.features = features
    self.zone = zone
    self.x = x
    self.y = y
    self.pass = pass
  }
}

public enum TrainingError: Error, Equatable, CustomStringConvertible {
  case noSamples
  case inconsistentFeatures
  case tooFewSamples(zone: Int, count: Int)
  case singular

  public var description: String {
    switch self {
    case .noSamples: "no usable taps were captured"
    case .inconsistentFeatures: "captured taps do not share one feature layout"
    case .tooFewSamples(let zone, let count): "zone \(zone + 1) has only \(count) usable taps"
    case .singular: "tap features are degenerate"
    }
  }
}

public struct CVReport: Sendable, Codable, Equatable {
  public var zoneAccuracy: Float
  public var columnAccuracy: Float
  public var rowAccuracy: Float
  public var meanError: Float
  public var samples: Int
  public var negatives: Int
  public var zones: Int
}

public struct Classification: Sendable {
  public let isTap: Bool
  public let score: Float
  public let fit: Float
  public let negativeVote: Float
  public let zone: Int
  public let probabilities: [Float]
  public let x: Float
  public let y: Float
  public let distance: Float
}

struct ZoneGaussians: Sendable {
  let dimension: Int
  let mean: [Double]
  let scale: [Double]
  let factor: [Double]
  let centers: [[Double]?]

  init?(samples: [TrainingSample], zones: Int, floors: [Float]) {
    guard let dimension = samples.first?.features.count else { return nil }
    let count = Double(samples.count)

    var mean = [Double](repeating: 0, count: dimension)
    for sample in samples {
      for index in 0..<dimension { mean[index] += Double(sample.features[index]) }
    }
    for index in 0..<dimension { mean[index] /= count }

    var scale = [Double](repeating: 0, count: dimension)
    for sample in samples {
      for index in 0..<dimension {
        let deviation = Double(sample.features[index]) - mean[index]
        scale[index] += deviation * deviation
      }
    }
    for index in 0..<dimension {
      scale[index] = max((scale[index] / max(count - 1, 1)).squareRoot(), Double(floors[index]))
    }

    let standardized = samples.map { sample in
      (0..<dimension).map { (Double(sample.features[$0]) - mean[$0]) / scale[$0] }
    }
    var sums = [[Double]](repeating: [Double](repeating: 0, count: dimension), count: zones)
    var members = [Int](repeating: 0, count: zones)
    for (sample, vector) in zip(samples, standardized) {
      members[sample.zone] += 1
      for index in 0..<dimension { sums[sample.zone][index] += vector[index] }
    }
    let zoneMeans: [[Double]?] = (0..<zones).map { zone in
      members[zone] > 0 ? sums[zone].map { $0 / Double(members[zone]) } : nil
    }

    var covariance = [Double](repeating: 0, count: dimension * dimension)
    for (sample, vector) in zip(samples, standardized) {
      guard let zoneMean = zoneMeans[sample.zone] else { continue }
      let residual = (0..<dimension).map { vector[$0] - zoneMean[$0] }
      for row in 0..<dimension {
        for column in 0...row { covariance[row * dimension + column] += residual[row] * residual[column] }
      }
    }
    let present = members.count { $0 > 0 }
    let freedom = Double(max(samples.count - present, 1))
    for row in 0..<dimension {
      for column in 0...row {
        let value = covariance[row * dimension + column] / freedom
        covariance[row * dimension + column] = value
        covariance[column * dimension + row] = value
      }
    }

    let size = Double(dimension)
    var trace = 0.0
    var traceOfSquare = 0.0
    for index in 0..<dimension { trace += covariance[index * dimension + index] }
    for value in covariance { traceOfSquare += value * value }
    let numerator = (1 - 2 / size) * traceOfSquare + trace * trace
    let denominator = (freedom + 1 - 2 / size) * (traceOfSquare - trace * trace / size)
    let shrinkage = max(denominator > 0 ? min(1, numerator / denominator) : 1, 0.05)
    let target = max(trace / size, 1e-6)
    for index in covariance.indices { covariance[index] *= 1 - shrinkage }
    for index in 0..<dimension { covariance[index * dimension + index] += shrinkage * target }

    guard let factor = cholesky(covariance, dimension: dimension) else { return nil }
    self.dimension = dimension
    self.mean = mean
    self.scale = scale
    self.factor = factor
    centers = zoneMeans.map { $0.map { forwardSolve(factor, dimension: dimension, $0) } }
  }

  func whiten(_ features: [Float]) -> [Double] {
    let standardized = (0..<dimension).map { (Double(features[$0]) - mean[$0]) / scale[$0] }
    return forwardSolve(factor, dimension: dimension, standardized)
  }

  func squaredDistances(from point: [Double]) -> [Double] {
    centers.map { center in center.map { squaredDistance(point, $0) } ?? .infinity }
  }
}

public struct TapModel: Sendable {
  public let grid: Grid
  public let report: CVReport

  let gaussians: ZoneGaussians
  let positions: [SIMD2<Float>]
  let temperature: Double
  let threshold: Double
  let tapPoints: [[Double]]
  let negativePoints: [[Double]]

  public static func train(
    taps: [TrainingSample], negatives: [[Float]], grid: Grid, floors: [Float]
  ) throws -> TapModel {
    guard let dimension = taps.first?.features.count else { throw TrainingError.noSamples }
    guard
      floors.count == dimension,
      taps.allSatisfy({ $0.features.count == dimension && (0..<grid.count).contains($0.zone) }),
      negatives.allSatisfy({ $0.count == dimension })
    else { throw TrainingError.inconsistentFeatures }
    for zone in 0..<grid.count {
      let count = taps.count { $0.zone == zone }
      guard count >= 2 else { throw TrainingError.tooFewSamples(zone: zone, count: count) }
    }

    let passes = Set(taps.map(\.pass)).sorted()
    let folds =
      passes.count >= 2
      ? passes.map { pass in taps.indices.filter { taps[$0].pass == pass } }
      : taps.indices.map { [$0] }

    var heldOut: [(sample: TrainingSample, distances: [Double])] = []
    for fold in folds {
      let excluded = Set(fold)
      let training = taps.indices.filter { !excluded.contains($0) }.map { taps[$0] }
      guard let fitted = ZoneGaussians(samples: training, zones: grid.count, floors: floors) else {
        throw TrainingError.singular
      }
      for index in fold {
        let distances = fitted.squaredDistances(from: fitted.whiten(taps[index].features))
        heldOut.append((taps[index], distances))
      }
    }

    func loss(_ temperature: Double) -> Double {
      heldOut.reduce(0) { total, entry in
        total - log(max(posterior(entry.distances, temperature: temperature)[entry.sample.zone], 1e-6))
      }
    }
    let temperature = [1.0, 2, 4, 8, 16, 32, 64, 128].min { loss($0) < loss($1) } ?? 1

    var zoneHits = 0
    var columnHits = 0
    var rowHits = 0
    var error: Float = 0
    for entry in heldOut {
      let probabilities = posterior(entry.distances, temperature: temperature)
      let predicted = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
      if predicted == entry.sample.zone { zoneHits += 1 }
      if grid.column(of: predicted) == grid.column(of: entry.sample.zone) { columnHits += 1 }
      if grid.row(of: predicted) == grid.row(of: entry.sample.zone) { rowHits += 1 }
      var estimate = SIMD2<Float>.zero
      for zone in 0..<grid.count { estimate += Float(probabilities[zone]) * grid.center(of: zone) }
      let offset = estimate - SIMD2(entry.sample.x, entry.sample.y)
      error += (offset * offset).sum().squareRoot()
    }
    let total = Float(heldOut.count)
    let report = CVReport(
      zoneAccuracy: Float(zoneHits) / total, columnAccuracy: Float(columnHits) / total,
      rowAccuracy: Float(rowHits) / total, meanError: error / total,
      samples: taps.count, negatives: negatives.count, zones: grid.count)

    let nearest = heldOut.map { $0.distances.min() ?? 0 }.filter(\.isFinite)
    let threshold = max(2.5 * quantile(nearest, 0.9), 1e-6)

    guard let gaussians = ZoneGaussians(samples: taps, zones: grid.count, floors: floors) else {
      throw TrainingError.singular
    }
    let positions = (0..<grid.count).map { zone in
      let members = taps.filter { $0.zone == zone }
      return members.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.x, $1.y) } / Float(members.count)
    }
    return TapModel(
      grid: grid, report: report, gaussians: gaussians, positions: positions,
      temperature: temperature, threshold: threshold,
      tapPoints: taps.map { gaussians.whiten($0.features) },
      negativePoints: negatives.map { gaussians.whiten($0) })
  }

  public func classify(_ features: [Float]) -> Classification {
    let point = gaussians.whiten(features)
    let distances = gaussians.squaredDistances(from: point)
    let nearest = distances.min() ?? .infinity
    let probabilities = Self.posterior(distances, temperature: temperature)
    let zone = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0

    var position = SIMD2<Float>.zero
    for index in positions.indices { position += Float(probabilities[index]) * positions[index] }

    let ratio = nearest / threshold
    let fit = 1 / (1 + ratio * ratio * ratio * ratio)
    let vote = negativeVote(for: point)
    return Classification(
      isTap: fit >= 0.5 && vote < 0.5, score: Float(fit * (1 - vote)), fit: Float(fit),
      negativeVote: Float(vote), zone: zone, probabilities: probabilities.map { Float($0) },
      x: position.x, y: position.y, distance: Float(nearest))
  }

  private func negativeVote(for point: [Double]) -> Double {
    let neighbours = 3
    guard negativePoints.count >= neighbours else { return 0 }
    let labelled =
      tapPoints.map { (squaredDistance(point, $0), false) }
      + negativePoints.map { (squaredDistance(point, $0), true) }
    let closest = labelled.sorted { $0.0 < $1.0 }.prefix(neighbours)
    return Double(closest.count { $0.1 }) / Double(neighbours)
  }

  private static func posterior(_ distances: [Double], temperature: Double) -> [Double] {
    let nearest = distances.min() ?? 0
    let weights = distances.map { $0.isFinite ? exp(-($0 - nearest) / (2 * temperature)) : 0 }
    let total = weights.reduce(0, +)
    guard total > 0 else { return distances.map { _ in 1 / Double(distances.count) } }
    return weights.map { $0 / total }
  }
}
