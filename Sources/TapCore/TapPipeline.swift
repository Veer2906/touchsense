import Foundation

public struct TapCandidate: Sendable {
  public let onsetSample: Int
  public let snippet: [Float]
  public let trigger: Range<Int>
  public let shape: EventShape
  public let features: [Float]
}

public struct TapPipeline {
  public let sampleRate: Double
  public private(set) var totalSamples = 0
  public private(set) var analyzer: EventAnalyzer

  private var detector: OnsetDetector
  private var history: [Float] = []
  private var historyStart = 0
  private var pending: [Int] = []
  private let preRoll: Int
  private let postRoll: Int
  private let retained: Int

  public var triggerDB: Float { detector.config.triggerDB }

  public init(
    sampleRate: Double, detector: DetectorConfig = DetectorConfig(),
    analyzer: AnalyzerConfig = AnalyzerConfig()
  ) {
    self.sampleRate = sampleRate
    self.detector = OnsetDetector(sampleRate: sampleRate, config: detector)
    self.analyzer = EventAnalyzer(sampleRate: sampleRate, config: analyzer)
    preRoll = Int(analyzer.preRoll * sampleRate)
    postRoll = Int(analyzer.postRoll * sampleRate)
    retained = preRoll + self.detector.frameSize + postRoll + Int(sampleRate)
  }

  public mutating func process(_ chunk: [Float]) -> (frames: [DetectorFrame], candidates: [TapCandidate]) {
    history.append(contentsOf: chunk)
    totalSamples += chunk.count
    let frames = detector.process(chunk)
    for frame in frames where frame.triggered { pending.append(frame.startSample) }

    var candidates: [TapCandidate] = []
    while let trigger = pending.first, totalSamples >= trigger + detector.frameSize + postRoll {
      pending.removeFirst()
      let start = trigger - preRoll
      guard start >= historyStart else { continue }
      let end = trigger + detector.frameSize + postRoll
      let snippet = Array(history[(start - historyStart)..<(end - historyStart)])
      let range = preRoll..<(preRoll + detector.frameSize)
      guard let analysis = analyzer.analyze(snippet, trigger: range) else { continue }
      candidates.append(
        TapCandidate(
          onsetSample: start + analysis.onsetIndex, snippet: snippet, trigger: range,
          shape: analysis.shape, features: analysis.features))
    }

    if history.count > 2 * retained {
      let excess = history.count - retained
      history.removeFirst(excess)
      historyStart += excess
    }
    return (frames, candidates)
  }
}
