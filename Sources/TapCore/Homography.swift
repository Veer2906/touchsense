import Foundation

public struct Homography: Sendable, Codable, Equatable {
  public var elements: [Double]

  public init(elements: [Double]) {
    precondition(elements.count == 9, "a homography has nine elements")
    self.elements = elements
  }

  public func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
    let x = Double(point.x)
    let y = Double(point.y)
    let w = elements[6] * x + elements[7] * y + elements[8]
    return SIMD2(
      Float((elements[0] * x + elements[1] * y + elements[2]) / w),
      Float((elements[3] * x + elements[4] * y + elements[5]) / w))
  }

  public var inverse: Homography? {
    let m = elements
    let cofactors = [
      m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
      m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
      m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
    ]
    let determinant = m[0] * cofactors[0] + m[1] * cofactors[3] + m[2] * cofactors[6]
    guard abs(determinant) > 1e-12 else { return nil }
    return Homography(elements: cofactors.map { $0 / determinant })
  }

  public static func fit(from source: [SIMD2<Float>], to destination: [SIMD2<Float>]) -> Homography? {
    guard source.count == destination.count, source.count >= 4,
      let sourceFrame = Normalization(source), let destinationFrame = Normalization(destination)
    else { return nil }

    var normal = [Double](repeating: 0, count: 64)
    var right = [Double](repeating: 0, count: 8)
    for (from, to) in zip(source, destination) {
      let (x, y) = sourceFrame.normalize(from)
      let (u, v) = destinationFrame.normalize(to)
      for (row, value) in [([x, y, 1, 0, 0, 0, -u * x, -u * y], u), ([0, 0, 0, x, y, 1, -v * x, -v * y], v)] {
        for i in 0..<8 {
          right[i] += row[i] * value
          for j in 0..<8 { normal[i * 8 + j] += row[i] * row[j] }
        }
      }
    }
    guard let h = choleskySolve(normal, dimension: 8, right) else { return nil }

    let s = sourceFrame
    let d = destinationFrame
    let inner = multiply(h + [1], [s.scale, 0, -s.scale * s.x, 0, s.scale, -s.scale * s.y, 0, 0, 1])
    let outer = multiply([1 / d.scale, 0, d.x, 0, 1 / d.scale, d.y, 0, 0, 1], inner)
    guard abs(outer[8]) > 1e-12 else { return nil }
    return Homography(elements: outer.map { $0 / outer[8] })
  }

  private struct Normalization {
    let x: Double
    let y: Double
    let scale: Double

    init?(_ points: [SIMD2<Float>]) {
      let count = Double(points.count)
      let x = points.reduce(0) { $0 + Double($1.x) } / count
      let y = points.reduce(0) { $0 + Double($1.y) } / count
      let spread = points.reduce(0) { $0 + hypot(Double($1.x) - x, Double($1.y) - y) } / count
      guard spread > 1e-9 else { return nil }
      self.x = x
      self.y = y
      scale = 2.0.squareRoot() / spread
    }

    func normalize(_ point: SIMD2<Float>) -> (Double, Double) {
      ((Double(point.x) - x) * scale, (Double(point.y) - y) * scale)
    }
  }

  private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
    var product = [Double](repeating: 0, count: 9)
    for row in 0..<3 {
      for column in 0..<3 {
        for k in 0..<3 { product[row * 3 + column] += a[row * 3 + k] * b[k * 3 + column] }
      }
    }
    return product
  }
}
