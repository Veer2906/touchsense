import Foundation

public struct DetectorConfig: Sendable {
  public var bandEdgesHz: [Double] = [300, 700, 1500, 3000, 6000, 12000, 20000]
  public var frameDuration = 0.0053
  public var minBandExcessDB: Float = 9
  public var sigmaFactor: Float = 4.5
  public var minActiveBands = 3
  public var triggerDB: Float = 6
  public var riseDB: Float = 5
  public var warmup = 0.3
  public var floorTimeConstant = 0.5
  public var hotTimeConstant = 8.0
  public var hotRunLimit = 1.0
  public var holdoff = 0.12

  public init() {}
}

public struct DetectorFrame: Sendable {
  public let startSample: Int
  public let detection: Float
  public let triggered: Bool
}

public struct OnsetDetector {
  public let config: DetectorConfig
  public let frameSize: Int
  public let hop: Int

  private var spectrum: PowerSpectrum
  private let window: [Float]
  private let bands: BandLayout
  private var power: [Float]
  private var energies: [Float]
  private var floorDB: [Float]
  private var deviationDB: [Float]
  private var recent: [Float] = []
  private var buffer: [Float] = []
  private var bufferStart = 0
  private var frameIndex = 0
  private var holdoffUntil = 0
  private var hotRun = 0
  private let warmupFrames: Int
  private let holdoffFrames: Int
  private let hotRunFrames: Int
  private let quietRate: Float
  private let hotRate: Float

  public init(sampleRate: Double, config: DetectorConfig = DetectorConfig()) {
    self.config = config
    frameSize = max(64, nextPowerOfTwo(Int(sampleRate * config.frameDuration)))
    hop = frameSize / 4
    spectrum = PowerSpectrum(size: frameSize)
    window = Window.hann(frameSize)
    bands = BandLayout(edgesHz: config.bandEdgesHz, fftSize: frameSize, sampleRate: sampleRate)
    power = [Float](repeating: 0, count: frameSize / 2 + 1)
    energies = [Float](repeating: 0, count: bands.count)
    floorDB = [Float](repeating: 0, count: bands.count)
    deviationDB = [Float](repeating: 0, count: bands.count)
    let frameRate = sampleRate / Double(hop)
    warmupFrames = max(8, Int(config.warmup * frameRate))
    holdoffFrames = max(1, Int(config.holdoff * frameRate))
    hotRunFrames = max(1, Int(config.hotRunLimit * frameRate))
    quietRate = Float(1 - exp(-1 / (config.floorTimeConstant * frameRate)))
    hotRate = Float(1 - exp(-1 / (config.hotTimeConstant * frameRate)))
  }

  public mutating func process(_ samples: [Float]) -> [DetectorFrame] {
    buffer.append(contentsOf: samples)
    var frames: [DetectorFrame] = []
    var offset = 0
    while buffer.count - offset >= frameSize {
      frames.append(analyze(at: offset))
      offset += hop
    }
    buffer.removeFirst(offset)
    bufferStart += offset
    return frames
  }

  private mutating func analyze(at offset: Int) -> DetectorFrame {
    spectrum.compute(buffer[offset..<offset + frameSize], window: window, into: &power)
    bands.energies(of: power, into: &energies)
    for band in energies.indices { energies[band] = 10 * log10(energies[band] + 1e-20) }
    let start = bufferStart + offset
    defer { frameIndex += 1 }

    if frameIndex == 0 {
      floorDB = energies
      return DetectorFrame(startSample: start, detection: 0, triggered: false)
    }
    if frameIndex < warmupFrames {
      for band in energies.indices {
        let difference = energies[band] - floorDB[band]
        floorDB[band] += difference / Float(frameIndex + 1)
        deviationDB[band] += (abs(difference) - deviationDB[band]) / Float(frameIndex)
      }
      return DetectorFrame(startSample: start, detection: 0, triggered: false)
    }

    var active = 0
    var sum: Float = 0
    for band in energies.indices {
      let excess = energies[band] - floorDB[band]
      let threshold = max(config.minBandExcessDB, config.sigmaFactor * 1.2533 * deviationDB[band])
      if excess > threshold { active += 1 }
      sum += max(0, excess)
    }
    let detection = sum / Float(energies.count)
    let rise = detection - (recent.min() ?? detection)

    let hot = active > 0 || detection > config.triggerDB / 2
    hotRun = hot ? hotRun + 1 : 0
    let rate = hot && hotRun < hotRunFrames ? hotRate : quietRate
    for band in energies.indices {
      let difference = energies[band] - floorDB[band]
      floorDB[band] += rate * difference
      deviationDB[band] += rate * (abs(difference) - deviationDB[band])
    }

    recent.append(detection)
    if recent.count > 4 { recent.removeFirst() }

    let triggered =
      frameIndex >= holdoffUntil && active >= config.minActiveBands
      && detection >= config.triggerDB && rise >= config.riseDB
    if triggered { holdoffUntil = frameIndex + holdoffFrames }
    return DetectorFrame(startSample: start, detection: detection, triggered: triggered)
  }
}
