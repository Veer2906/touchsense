import Accelerate
import Foundation

func nextPowerOfTwo(_ value: Int) -> Int {
  var power = 1
  while power < value { power <<= 1 }
  return power
}

public enum Window {
  public static func hann(_ count: Int) -> [Float] {
    (0..<count).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(count)) }
  }

  public static func tukey(_ count: Int, taper: Float) -> [Float] {
    let edge = max(1, Int(Float(count) * taper / 2))
    return (0..<count).map { index in
      let distance = min(index, count - 1 - index)
      return distance >= edge ? 1 : 0.5 - 0.5 * cos(.pi * Float(distance) / Float(edge))
    }
  }
}

public struct PowerSpectrum {
  public let size: Int
  public var binCount: Int { size / 2 + 1 }

  private let transform: vDSP.DiscreteFourierTransform<Float>
  private var inputReal: [Float]
  private let inputImaginary: [Float]
  private var outputReal: [Float]
  private var outputImaginary: [Float]

  public init(size: Int) {
    precondition(size >= 16 && size & (size - 1) == 0, "spectrum size must be a power of two")
    guard
      let transform = try? vDSP.DiscreteFourierTransform(
        count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    else { preconditionFailure("vDSP rejected a power-of-two transform size") }
    self.size = size
    self.transform = transform
    inputReal = [Float](repeating: 0, count: size)
    inputImaginary = [Float](repeating: 0, count: size)
    outputReal = [Float](repeating: 0, count: size)
    outputImaginary = [Float](repeating: 0, count: size)
  }

  public mutating func compute(
    _ signal: ArraySlice<Float>, window: [Float]? = nil, into power: inout [Float]
  ) {
    let count = min(signal.count, size)
    let base = signal.startIndex
    if let window {
      for index in 0..<count { inputReal[index] = signal[base + index] * window[index] }
    } else {
      for index in 0..<count { inputReal[index] = signal[base + index] }
    }
    for index in count..<size { inputReal[index] = 0 }
    transform.transform(
      inputReal: inputReal, inputImaginary: inputImaginary,
      outputReal: &outputReal, outputImaginary: &outputImaginary)
    for bin in 0..<binCount {
      power[bin] = outputReal[bin] * outputReal[bin] + outputImaginary[bin] * outputImaginary[bin]
    }
  }
}

public struct BandLayout: Sendable {
  public let ranges: [Range<Int>]
  public var count: Int { ranges.count }

  public init(edgesHz: [Double], fftSize: Int, sampleRate: Double) {
    let binHz = sampleRate / Double(fftSize)
    let top = fftSize / 2
    let limit = 0.49 * sampleRate
    ranges = zip(edgesHz, edgesHz.dropFirst()).map { low, high in
      let low = min(low, limit)
      let high = min(high, limit)
      let first = max(1, Int((low / binHz).rounded(.up)))
      let last = min(top, Int((high / binHz).rounded(.up)))
      if first < last { return first..<last }
      let nearest = min(max(1, Int(((low * high).squareRoot() / binHz).rounded())), top - 1)
      return nearest..<(nearest + 1)
    }
  }

  public static func logSpaced(
    from low: Double, to high: Double, count: Int, fftSize: Int, sampleRate: Double
  ) -> BandLayout {
    let edges = (0...count).map { low * pow(high / low, Double($0) / Double(count)) }
    return BandLayout(edgesHz: edges, fftSize: fftSize, sampleRate: sampleRate)
  }

  public func energies(of power: [Float], into output: inout [Float]) {
    for (index, range) in ranges.enumerated() {
      var sum: Float = 0
      for bin in range { sum += power[bin] }
      output[index] = sum
    }
  }
}

public struct Biquad: Sendable {
  private let b0: Float
  private let b1: Float
  private let b2: Float
  private let a1: Float
  private let a2: Float
  private var z1: Float = 0
  private var z2: Float = 0

  public static func highpass(cutoff: Double, sampleRate: Double) -> Biquad {
    let omega = 2 * Double.pi * min(cutoff, 0.45 * sampleRate) / sampleRate
    let alpha = sin(omega) / 2.0.squareRoot()
    let cosine = cos(omega)
    let a0 = 1 + alpha
    return Biquad(
      b0: Float((1 + cosine) / 2 / a0), b1: Float(-(1 + cosine) / a0),
      b2: Float((1 + cosine) / 2 / a0), a1: Float(-2 * cosine / a0), a2: Float((1 - alpha) / a0))
  }

  private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
    self.b0 = b0
    self.b1 = b1
    self.b2 = b2
    self.a1 = a1
    self.a2 = a2
  }

  public mutating func process(_ input: [Float]) -> [Float] {
    var output = input
    for index in input.indices {
      let x = input[index]
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      output[index] = y
    }
    return output
  }
}
