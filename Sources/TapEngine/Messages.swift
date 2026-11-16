import Foundation
import TapCore

struct WaveMessage: Encodable {
  let type = "wave"
  let column: Int
  let low: [Float]
  let high: [Float]
  let detection: [Float]
  let threshold: Float
}

struct EventMessage: Encodable {
  let type = "event"
  let column: Int
  let tap: Bool
  let why: String?
  let snr: Float
  let x: Float?
  let y: Float?
}

struct StatusMessage: Encodable {
  struct Pointer: Encodable {
    let error: Float
    let millimetres: Float
    let lag: Double
    let quad: [[Float]]
  }

  let type = "status"
  let mic: String
  let device: String
  let sampleRate: Double
  let camera: String
  let cameraName: String
  let fps: Int
  let screenCheck: Bool
  let pointer: Pointer?
}

struct HandsMessage: Encodable {
  struct Hand: Encodable {
    let id: Int
    let joints: [Float]
    let confidences: [Float]
    let displayed: Bool
    let screen: [Float]?
  }

  let type = "hands"
  let hands: [Hand]
}

struct ScrollMessage: Encodable {
  let type = "scroll"
  let x: Float
  let y: Float
}

struct NoticeMessage: Encodable {
  let type = "notice"
  let text: String
}

struct PreviewMessage: Encodable {
  let type = "preview"
  let jpeg: Data
}

struct CalibrationMessage: Encodable {
  let type = "calibration"
  let phase: String
  var done: Int?
  var total: Int?
  var x: Float?
  var y: Float?
  var heard: Bool?
  var note: String?
  var error: Float?
  var millimetres: Float?
  var lag: Double?
  var problem: String?
}

struct EventRecord: Encodable {
  let time: Date
  let sample: Int
  let tap: Bool
  let why: String?
  let shape: EventShape
  let x: Float?
  let y: Float?
}

struct WaveColumns {
  var size = 96
  private(set) var firstColumn = 0
  private(set) var low: [Float] = []
  private(set) var high: [Float] = []
  private(set) var detection: [Float] = []
  private var currentLow: Float = 0
  private var currentHigh: Float = 0
  private var filled = 0

  mutating func add(_ samples: [Float], detection level: Float) {
    for sample in samples {
      currentLow = min(currentLow, sample)
      currentHigh = max(currentHigh, sample)
      filled += 1
      if filled == size {
        low.append(currentLow)
        high.append(currentHigh)
        detection.append(level)
        currentLow = 0
        currentHigh = 0
        filled = 0
      }
    }
  }

  mutating func drain(minimum: Int, threshold: Float) -> WaveMessage? {
    guard low.count >= minimum else { return nil }
    defer {
      firstColumn += low.count
      low.removeAll(keepingCapacity: true)
      high.removeAll(keepingCapacity: true)
      detection.removeAll(keepingCapacity: true)
    }
    return WaveMessage(column: firstColumn, low: low, high: high, detection: detection, threshold: threshold)
  }
}
