import Foundation
import TapCore

struct PointerRecord: Codable {
  var createdAt = Date()
  var mapping: PointerMapping
  var samples: [PointerSample]
}

public struct SessionRecord: Codable, Sendable {
  public struct Attempt: Codable, Sendable {
    public var time: Double
    public var target: SIMD2<Float>
    public var accepted: Bool
  }

  public struct Phase: Codable, Sendable {
    public var label: String
    public var start: Double
    public var end: Double
  }

  public var aspect: Float
  public var screenWidthMM: Float
  public var sampleRate: Double
  public var audioStart: Double?
  public var attempts: [Attempt] = []
  public var mapping: PointerMapping?
  public var phases: [Phase]?
}

struct Store: Sendable {
  let directory: URL

  private var pointerURL: URL { directory.appending(path: "pointer.json") }
  private var eventsURL: URL { directory.appending(path: "events.jsonl") }

  func prepare() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func loadPointer() throws -> PointerRecord? {
    guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
    return try JSONDecoder().decode(PointerRecord.self, from: Data(contentsOf: pointerURL))
  }

  func save(_ record: PointerRecord) throws {
    try archivePointer()
    try JSONEncoder().encode(record).write(to: pointerURL, options: .atomic)
  }

  func archivePointer() throws {
    guard FileManager.default.fileExists(atPath: pointerURL.path) else { return }
    let stamp = Date().formatted(.iso8601.timeSeparator(.omitted).dateSeparator(.omitted))
    try FileManager.default.moveItem(at: pointerURL, to: directory.appending(path: "pointer-\(stamp).json"))
  }

  func makeSessionDirectory() throws -> URL {
    let stamp = Date().formatted(.iso8601.timeSeparator(.omitted).dateSeparator(.omitted))
    let url = directory.appending(path: "sessions/\(stamp)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func appendEvent(_ line: Data) {
    if !FileManager.default.fileExists(atPath: eventsURL.path) {
      FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line + Data("\n".utf8))
  }
}
