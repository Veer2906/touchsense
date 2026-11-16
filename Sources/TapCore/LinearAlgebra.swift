func cholesky(_ matrix: [Double], dimension: Int) -> [Double]? {
  var factor = [Double](repeating: 0, count: dimension * dimension)
  for row in 0..<dimension {
    for column in 0...row {
      var sum = matrix[row * dimension + column]
      for k in 0..<column { sum -= factor[row * dimension + k] * factor[column * dimension + k] }
      if row == column {
        guard sum > 0 else { return nil }
        factor[row * dimension + row] = sum.squareRoot()
      } else {
        factor[row * dimension + column] = sum / factor[column * dimension + column]
      }
    }
  }
  return factor
}

func forwardSolve(_ factor: [Double], dimension: Int, _ vector: [Double]) -> [Double] {
  var solution = vector
  for row in 0..<dimension {
    var sum = vector[row]
    for k in 0..<row { sum -= factor[row * dimension + k] * solution[k] }
    solution[row] = sum / factor[row * dimension + row]
  }
  return solution
}

func squaredDistance(_ a: [Double], _ b: [Double]) -> Double {
  var sum = 0.0
  for index in a.indices {
    let difference = a[index] - b[index]
    sum += difference * difference
  }
  return sum
}

func quantile(_ values: [Double], _ fraction: Double) -> Double {
  let sorted = values.sorted()
  guard let last = sorted.last else { return 0 }
  let position = fraction * Double(sorted.count - 1)
  let lower = Int(position)
  guard lower + 1 < sorted.count else { return last }
  return sorted[lower] + (sorted[lower + 1] - sorted[lower]) * (position - Double(lower))
}

func choleskySolve(_ matrix: [Double], dimension: Int, _ vector: [Double]) -> [Double]? {
  guard let factor = cholesky(matrix, dimension: dimension) else { return nil }
  var solution = forwardSolve(factor, dimension: dimension, vector)
  for row in stride(from: dimension - 1, through: 0, by: -1) {
    var sum = solution[row]
    for k in (row + 1)..<dimension { sum -= factor[k * dimension + row] * solution[k] }
    solution[row] = sum / factor[row * dimension + row]
  }
  return solution
}

func median(_ values: [Float]) -> Float? {
  guard !values.isEmpty else { return nil }
  let sorted = values.sorted()
  let middle = sorted.count / 2
  return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

func median(_ points: [SIMD2<Float>]) -> SIMD2<Float>? {
  guard let x = median(points.map(\.x)), let y = median(points.map(\.y)) else { return nil }
  return SIMD2(x, y)
}
