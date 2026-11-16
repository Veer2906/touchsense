import CoreAudio
import Foundation

public struct AudioChunk: Sendable {
  public let samples: [Float]
  public let hostTime: Double
}

public struct InputDevice: Sendable {
  public let id: AudioDeviceID
  public let name: String
  public let sampleRate: Double
  public let isBuiltIn: Bool
}

public enum AudioInputError: Error, CustomStringConvertible {
  case coreAudio(String, OSStatus)

  public var description: String {
    switch self {
    case .coreAudio(let operation, let status): "\(operation) failed (\(status))"
    }
  }
}

public enum AudioInput {
  public static func devices() -> [InputDevice] {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap(device)
  }

  public static func preferredDevice() -> InputDevice? {
    let all = devices()
    if let builtIn = all.first(where: \.isBuiltIn) { return builtIn }
    let fallback: AudioDeviceID? = value(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0)
    return all.first { $0.id == fallback } ?? all.first
  }

  private static func device(_ id: AudioDeviceID) -> InputDevice? {
    guard inputChannels(id) > 0 else { return nil }
    let transport: UInt32? = value(id, kAudioDevicePropertyTransportType, initial: 0)
    let rate: Float64? = value(id, kAudioDevicePropertyNominalSampleRate, initial: 0)
    var name: Unmanaged<CFString>?
    var address = propertyAddress(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
    guard let rate, rate > 0 else { return nil }
    return InputDevice(
      id: id,
      name: status == noErr ? (name?.takeRetainedValue() as String?) ?? "microphone" : "microphone",
      sampleRate: rate, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
  }

  private static func inputChannels(_ id: AudioDeviceID) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  static func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var result = initial
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : nil
  }
}

public final class AudioCapture {
  public let device: InputDevice
  private var procedure: AudioDeviceIOProcID?
  private var continuation: AsyncStream<AudioChunk>.Continuation?
  private let queue = DispatchQueue(label: "local.tapsense.audio", qos: .userInteractive)

  public init(device: InputDevice) {
    self.device = device
  }

  public func start() throws -> AsyncStream<AudioChunk> {
    var frames: UInt32 = 512
    var address = AudioInput.propertyAddress(kAudioDevicePropertyBufferFrameSize)
    AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

    let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    var status = AudioDeviceCreateIOProcIDWithBlock(&procedure, device.id, queue) { _, input, inputTime, _, _ in
      let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
      guard let buffer = buffers.first, let data = buffer.mData, buffer.mNumberChannels > 0 else { return }
      let channels = Int(buffer.mNumberChannels)
      let count = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
      let samples = data.assumingMemoryBound(to: Float.self)
      continuation.yield(
        AudioChunk(
          samples: (0..<count).map { samples[$0 * channels] },
          hostTime: Double(inputTime.pointee.mHostTime) * secondsPerTick))
    }
    guard status == noErr, let procedure else {
      throw AudioInputError.coreAudio("opening \(device.name)", status)
    }
    status = AudioDeviceStart(device.id, procedure)
    guard status == noErr else {
      AudioDeviceDestroyIOProcID(device.id, procedure)
      self.procedure = nil
      throw AudioInputError.coreAudio("starting \(device.name)", status)
    }
    self.continuation = continuation
    return stream
  }

  public func stop() {
    guard let procedure else { return }
    AudioDeviceStop(device.id, procedure)
    AudioDeviceDestroyIOProcID(device.id, procedure)
    self.procedure = nil
    continuation?.finish()
    continuation = nil
  }
}
