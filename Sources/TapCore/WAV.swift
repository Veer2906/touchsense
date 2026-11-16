import Foundation

public enum WAVError: Error {
  case cannotCreate(URL)
  case malformed
  case unsupportedFormat(tag: UInt16, bits: UInt16)
}

public final class WAVWriter {
  private let handle: FileHandle
  private var dataBytes = 0

  public init(url: URL, sampleRate: Double) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw WAVError.cannotCreate(url)
    }
    handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Self.header(sampleRate: UInt32(sampleRate), dataBytes: 0))
    self.sampleRate = UInt32(sampleRate)
  }

  private let sampleRate: UInt32

  public func append(_ samples: [Float]) throws {
    try handle.write(contentsOf: samples.withUnsafeBufferPointer { Data(buffer: $0) })
    dataBytes += samples.count * 4
  }

  public func close() throws {
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: UInt32(dataBytes)))
    try handle.close()
  }

  private static func header(sampleRate: UInt32, dataBytes: UInt32) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(36 + dataBytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(3))
    append(UInt16(1))
    append(sampleRate)
    append(sampleRate * 4)
    append(UInt16(4))
    append(UInt16(32))
    data.append(contentsOf: Array("data".utf8))
    append(dataBytes)
    return data
  }
}

public enum WAVReader {
  public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let data = try Data(contentsOf: url)
    return try data.withUnsafeBytes { bytes in
      func integer<T: FixedWidthInteger>(_ offset: Int, _: T.Type) throws -> T {
        guard offset + MemoryLayout<T>.size <= bytes.count else { throw WAVError.malformed }
        return T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
      }
      func tag(_ offset: Int) throws -> String {
        guard offset + 4 <= bytes.count else { throw WAVError.malformed }
        return String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
      }
      guard try tag(0) == "RIFF", try tag(8) == "WAVE" else { throw WAVError.malformed }

      var format: (tag: UInt16, channels: Int, rate: Double, bits: UInt16)?
      var offset = 12
      while offset + 8 <= bytes.count {
        let name = try tag(offset)
        let size = Int(try integer(offset + 4, UInt32.self))
        let body = offset + 8
        if name == "fmt " {
          var kind = try integer(body, UInt16.self)
          if kind == 0xFFFE { kind = try integer(body + 24, UInt16.self) }
          format = (
            kind, Int(try integer(body + 2, UInt16.self)),
            Double(try integer(body + 4, UInt32.self)), try integer(body + 14, UInt16.self)
          )
        } else if name == "data" {
          guard let format, format.channels > 0 else { throw WAVError.malformed }
          let width = Int(format.bits) / 8
          let length = size == 0 ? bytes.count - body : min(size, bytes.count - body)
          let frames = length / (width * format.channels)
          var samples = [Float](repeating: 0, count: frames)
          for frame in 0..<frames {
            let position = body + frame * width * format.channels
            switch (format.tag, format.bits) {
            case (3, 32):
              samples[frame] = Float(bitPattern: try integer(position, UInt32.self))
            case (1, 16):
              samples[frame] = Float(try integer(position, Int16.self)) / 32768
            case (1, 24):
              let low = Int32(try integer(position, UInt16.self))
              let high = Int32(try integer(position + 2, Int8.self))
              samples[frame] = Float(high << 16 | low) / 8_388_608
            case (1, 32):
              samples[frame] = Float(try integer(position, Int32.self)) / 2_147_483_648
            default:
              throw WAVError.unsupportedFormat(tag: format.tag, bits: format.bits)
            }
          }
          return (samples, format.rate)
        }
        offset = body + size + (size & 1)
      }
      throw WAVError.malformed
    }
  }
}
