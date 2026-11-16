import Foundation
import TapCore

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

func column(_ value: Float, _ format: String) -> String { String(format: format, value) }

func analyze(_ path: String) throws {
  let (samples, sampleRate) = try WAVReader.read(URL(filePath: path))
  var pipeline = TapPipeline(sampleRate: sampleRate)
  print("\(path): \(samples.count) samples at \(Int(sampleRate)) Hz")
  print("   sample     time   snr  attack  decay10  decay20  centroid  compact  spectral  lowrise highrise    tilt  verdict")
  var position = 0
  var found = 0
  while position < samples.count {
    let end = min(samples.count, position + 512)
    for candidate in pipeline.process(Array(samples[position..<end])).candidates {
      found += 1
      let shape = candidate.shape
      let verdict = pipeline.analyzer.rejection(for: shape)?.rawValue ?? "impulse"
      print(
        String(format: "%9d", candidate.onsetSample),
        column(Float(Double(candidate.onsetSample) / sampleRate), "%8.3f"),
        column(shape.snrDB, "%5.1f"), column(shape.attackMs, "%7.2f"),
        column(shape.decay10Ms, "%8.1f"), column(shape.decay20Ms, "%8.1f"),
        column(shape.centroidMs, "%9.1f"), column(shape.compactness, "%8.2f"),
        column(shape.spectralCentroidHz, "%9.0f"), column(shape.lowRiseDB, "%8.1f"),
        column(shape.highRiseDB, "%8.1f"), column(shape.tiltDB, "%7.1f"), " " + verdict)
    }
    position = end
  }
  print("\(found) transients")
}

func calibration(_ path: String) throws {
  let data = try JSONDecoder().decode(CalibrationData.self, from: Data(contentsOf: URL(filePath: path)))
  let report = try data.makeModel().report
  let chance = 100 / Float(report.zones)
  print("\(report.samples) taps, \(report.negatives) non-taps, \(data.grid.columns)x\(data.grid.rows) grid")
  print(String(format: "held-out zone accuracy    %5.1f%%  (chance %.1f%%)", report.zoneAccuracy * 100, chance))
  print(String(format: "held-out column accuracy  %5.1f%%", report.columnAccuracy * 100))
  print(String(format: "held-out row accuracy     %5.1f%%", report.rowAccuracy * 100))
  print(String(format: "mean position error       %5.3f of screen", report.meanError))
}

func shapes(_ path: String) throws {
  let data = try JSONDecoder().decode(CalibrationData.self, from: Data(contentsOf: URL(filePath: path)))
  var analyzer = EventAnalyzer(sampleRate: data.sampleRate)
  let encoder = JSONEncoder()
  for (kind, snippets) in [("tap", data.taps), ("other", data.negatives)] {
    for snippet in snippets {
      guard let analysis = analyzer.analyze(snippet.floats, trigger: snippet.triggerStart..<snippet.triggerEnd)
      else { continue }
      print(kind, String(decoding: try encoder.encode(analysis.shape), as: UTF8.self))
    }
  }
}

let arguments = CommandLine.arguments.dropFirst()
do {
  switch (arguments.first, arguments.dropFirst().first) {
  case ("analyze", let path?): try analyze(path)
  case ("calibration", let path?): try calibration(path)
  case ("shapes", let path?): try shapes(path)
  default: fail("usage: tapcli analyze <file.wav> | tapcli calibration <calibration.json> | tapcli shapes <calibration.json>")
  }
} catch {
  fail("error: \(error)")
}
