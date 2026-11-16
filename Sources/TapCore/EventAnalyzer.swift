import Foundation

public struct AnalyzerConfig: Sendable {
  public var highpassHz = 300.0
  public var preRoll = 0.160
  public var postRoll = 0.100
  public var minSNRDB: Float = 12
  public var minLowRiseDB: Float = 10
  public var maxDecay10Ms: Float = 60

  public init() {}
}

public struct EventShape: Sendable, Codable {
  public var snrDB: Float
  public var peak: Float
  public var attackMs: Float
  public var decay10Ms: Float
  public var decay20Ms: Float
  public var centroidMs: Float
  public var compactness: Float
  public var spectralCentroidHz: Float
  public var flatness: Float
  public var lowRiseDB: Float
  public var highRiseDB: Float
  public var tiltDB: Float
}

public enum Rejection: String, Sendable, Codable {
  case weak = "too quiet"
  case airborne = "sound came through the air, not the laptop"
  case longDecay = "rings too long"
}

public struct Analysis: Sendable {
  public let onsetIndex: Int
  public let shape: EventShape
  public let features: [Float]
}

public struct EventAnalyzer {
  public let sampleRate: Double
  public let config: AnalyzerConfig
  public let featureFloors: [Float]

  private let highpass: Biquad
  private var segments: [Segment]
  private var shapeSpectrum: PowerSpectrum
  private var shapePower: [Float]
  private let shapeWindow: [Float]
  private let shapeLead: Int
  private let shapeFirstBin: Int
  private var bandSpectrum: PowerSpectrum
  private var bandPower: [Float]
  private let bandWindow: [Float]
  private let bandLead: Int
  private let bandGap: Int
  private let bandNoiseWindow: [Float]
  private let lowBand: Range<Int>
  private let highBand: Range<Int>

  private struct Segment {
    let offset: Int
    let length: Int
    let window: [Float]
    let bands: BandLayout
    var spectrum: PowerSpectrum
    var power: [Float]
    var energies: [Float]

    mutating func appendLevels(of signal: [Float], onset: Int, to features: inout [Float]) {
      let start = onset + offset
      spectrum.compute(signal[start..<start + length], window: window, into: &power)
      bands.energies(of: power, into: &energies)
      for energy in energies { features.append(10 * log10(energy + 1e-20)) }
    }
  }

  public init(sampleRate: Double, config: AnalyzerConfig = AnalyzerConfig()) {
    self.sampleRate = sampleRate
    self.config = config
    highpass = Biquad.highpass(cutoff: config.highpassHz, sampleRate: sampleRate)

    let layout: [(start: Double, end: Double, low: Double, high: Double, bands: Int, taper: Float?)] = [
      (-0.0005, 0.005, 500, 20000, 10, 0.25),
      (0.005, 0.025, 150, 20000, 20, nil),
      (0.025, 0.090, 100, 10000, 24, nil),
    ]
    segments = layout.map { spec in
      let length = Int(((spec.end - spec.start) * sampleRate).rounded())
      let size = max(16, nextPowerOfTwo(length))
      let bands = BandLayout.logSpaced(
        from: spec.low, to: spec.high, count: spec.bands, fftSize: size, sampleRate: sampleRate)
      return Segment(
        offset: Int((spec.start * sampleRate).rounded()), length: length,
        window: spec.taper.map { Window.tukey(length, taper: $0) } ?? Window.hann(length),
        bands: bands, spectrum: PowerSpectrum(size: size),
        power: [Float](repeating: 0, count: size / 2 + 1),
        energies: [Float](repeating: 0, count: bands.count))
    }
    let spectral = segments.reduce(0) { $0 + $1.bands.count }
    featureFloors = [Float](repeating: 0.5, count: spectral) + [0.2, 1, 1, 0.5, 0.02]

    shapeLead = Int((0.0005 * sampleRate).rounded())
    let shapeLength = Int((0.0105 * sampleRate).rounded())
    let shapeSize = max(16, nextPowerOfTwo(shapeLength))
    shapeSpectrum = PowerSpectrum(size: shapeSize)
    shapePower = [Float](repeating: 0, count: shapeSize / 2 + 1)
    shapeWindow = Window.hann(shapeLength)
    shapeFirstBin = max(1, Int((config.highpassHz * Double(shapeSize) / sampleRate).rounded(.up)))

    let bandLength = Int((0.042 * sampleRate).rounded())
    let bandSize = max(16, nextPowerOfTwo(bandLength))
    bandSpectrum = PowerSpectrum(size: bandSize)
    bandPower = [Float](repeating: 0, count: bandSize / 2 + 1)
    bandWindow = Window.tukey(bandLength, taper: 0.25)
    bandLead = Int((0.002 * sampleRate).rounded())
    bandGap = Int((0.005 * sampleRate).rounded())
    bandNoiseWindow = Window.hann(bandSize)
    let bands = BandLayout(edgesHz: [60, 300, 1500, 12000], fftSize: bandSize, sampleRate: sampleRate)
    lowBand = bands.ranges[0]
    highBand = bands.ranges[2]
  }

  public func rejection(for shape: EventShape) -> Rejection? {
    if shape.snrDB < config.minSNRDB { return .weak }
    if shape.lowRiseDB < config.minLowRiseDB { return .airborne }
    if shape.decay10Ms > config.maxDecay10Ms { return .longDecay }
    return nil
  }

  public mutating func analyze(_ signal: [Float], trigger: Range<Int>) -> Analysis? {
    var filter = highpass
    let filtered = filter.process(signal)
    guard
      let onset = pickOnset(in: filtered, trigger: trigger),
      onset >= samples(0.015), onset + samples(0.090) <= signal.count
    else { return nil }

    let shape = measureShape(signal: signal, filtered: filtered, onset: onset)
    var features: [Float] = []
    features.reserveCapacity(featureFloors.count)
    for index in segments.indices {
      segments[index].appendLevels(of: signal, onset: onset, to: &features)
    }
    let mean = features.reduce(0, +) / Float(features.count)
    for index in features.indices { features[index] -= mean }
    features += [shape.attackMs, shape.decay10Ms, shape.decay20Ms, shape.centroidMs, shape.compactness]
    return Analysis(onsetIndex: onset, shape: shape, features: features)
  }

  private func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

  private func pickOnset(in filtered: [Float], trigger: Range<Int>) -> Int? {
    let lower = max(0, trigger.lowerBound - samples(0.008))
    let upper = min(filtered.count, trigger.upperBound + samples(0.0015))
    let count = upper - lower
    let margin = 16
    guard count > 4 * margin else { return nil }

    var sums = [Double](repeating: 0, count: count + 1)
    var squares = [Double](repeating: 0, count: count + 1)
    for index in 0..<count {
      let value = Double(filtered[lower + index])
      sums[index + 1] = sums[index] + value
      squares[index + 1] = squares[index] + value * value
    }
    func variance(_ from: Int, _ to: Int) -> Double {
      let length = Double(to - from)
      let mean = (sums[to] - sums[from]) / length
      return max((squares[to] - squares[from]) / length - mean * mean, 0)
    }

    var best = margin
    var lowest = Double.infinity
    for split in margin..<(count - margin) {
      let criterion =
        Double(split) * log(variance(0, split) + 1e-18)
        + Double(count - split) * log(variance(split, count) + 1e-18)
      if criterion < lowest {
        lowest = criterion
        best = split
      }
    }
    return lower + best
  }

  private mutating func measureShape(signal: [Float], filtered: [Float], onset: Int) -> EventShape {
    let noiseRange = (onset - samples(0.015))..<(onset - samples(0.001))
    var noisePower: Float = 0
    for index in noiseRange { noisePower += filtered[index] * filtered[index] }
    noisePower /= Float(noiseRange.count)

    var peak: Float = 0
    var peakIndex = onset
    for index in onset..<min(filtered.count, onset + samples(0.030)) where abs(filtered[index]) > peak {
      peak = abs(filtered[index])
      peakIndex = index
    }

    let span = samples(0.090)
    let early = samples(0.025)
    var total: Float = 0
    var earlyEnergy: Float = 0
    var positive: Float = 0
    var weighted: Float = 0
    for index in 0..<span {
      let energy = filtered[onset + index] * filtered[onset + index] - noisePower
      total += energy
      if index < early { earlyEnergy += energy }
      positive += max(energy, 0)
      weighted += max(energy, 0) * Float(index)
    }

    var decay10 = span
    var decay20 = span
    if total > 0 {
      var elapsed: Float = 0
      var reached10 = false
      for index in 0..<span {
        elapsed += filtered[onset + index] * filtered[onset + index] - noisePower
        let remaining = total - elapsed
        if !reached10 && remaining <= 0.1 * total {
          decay10 = index + 1
          reached10 = true
        }
        if remaining <= 0.01 * total {
          decay20 = index + 1
          break
        }
      }
    }

    let start = onset - shapeLead
    shapeSpectrum.compute(
      signal[start..<start + shapeWindow.count], window: shapeWindow, into: &shapePower)
    var energy: Float = 0
    var moment: Float = 0
    var logSum: Float = 0
    let bins = shapeFirstBin..<shapePower.count
    for bin in bins {
      energy += shapePower[bin]
      moment += shapePower[bin] * Float(bin)
      logSum += log(shapePower[bin] + 1e-20)
    }
    let binHz = Float(sampleRate) / Float(shapeSpectrum.size)
    let msPerSample = 1000 / Float(sampleRate)

    let eventStart = onset - bandLead
    let event = bandPowers(of: signal[eventStart..<eventStart + bandWindow.count], window: bandWindow)
    let ambient = ambientPowers(in: signal, before: eventStart - bandGap)
    func level(_ power: Float) -> Float { 10 * log10(power + 1e-14) }

    return EventShape(
      snrDB: 20 * log10(max(peak, 1e-9) / max(noisePower.squareRoot(), 1e-7)),
      peak: peak,
      attackMs: Float(peakIndex - onset) * msPerSample,
      decay10Ms: Float(decay10) * msPerSample,
      decay20Ms: Float(decay20) * msPerSample,
      centroidMs: positive > 0 ? weighted / positive * msPerSample : 0,
      compactness: total > 0 ? min(max(earlyEnergy / total, 0), 1) : 0,
      spectralCentroidHz: energy > 0 ? moment / energy * binHz : 0,
      flatness: energy > 0 ? exp(logSum / Float(bins.count)) / (energy / Float(bins.count)) : 0,
      lowRiseDB: level(event.low) - level(ambient.low),
      highRiseDB: level(event.high) - level(ambient.high),
      tiltDB: level(max(event.low - ambient.low, 0.05 * ambient.low))
        - level(max(event.high - ambient.high, 0.05 * ambient.high)))
  }

  private mutating func ambientPowers(in signal: [Float], before end: Int) -> (low: Float, high: Float) {
    let length = bandNoiseWindow.count
    guard end >= length else {
      let quiet = signal[0..<max(end, 1)]
      return bandPowers(of: quiet, window: Window.hann(quiet.count))
    }
    var lows: [Float] = []
    var highs: [Float] = []
    var start = end - length
    while start >= 0 && lows.count < 5 {
      let powers = bandPowers(of: signal[start..<start + length], window: bandNoiseWindow)
      lows.append(powers.low)
      highs.append(powers.high)
      start -= length / 2
    }
    return (median(lows) ?? 0, median(highs) ?? 0)
  }

  private mutating func bandPowers(of signal: ArraySlice<Float>, window: [Float]) -> (low: Float, high: Float) {
    bandSpectrum.compute(signal, window: window, into: &bandPower)
    let weight = window.reduce(0) { $0 + $1 * $1 }
    guard weight > 0 else { return (0, 0) }
    let scale = 2 / (Float(bandSpectrum.size) * weight)
    return (bandPower[lowBand].reduce(0, +) * scale, bandPower[highBand].reduce(0, +) * scale)
  }
}
