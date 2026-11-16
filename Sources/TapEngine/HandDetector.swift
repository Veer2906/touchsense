import CoreVideo
import TapCore
import Vision

public struct HandDetector {
  private static let joints: [VNHumanHandPoseObservation.JointName] = [
    .wrist,
    .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
    .indexMCP, .indexPIP, .indexDIP, .indexTip,
    .middleMCP, .middlePIP, .middleDIP, .middleTip,
    .ringMCP, .ringPIP, .ringDIP, .ringTip,
    .littleMCP, .littlePIP, .littleDIP, .littleTip,
  ]

  private let request = VNDetectHumanHandPoseRequest()

  public init(maximumHands: Int = 4) {
    request.maximumHandCount = maximumHands
  }

  public func detect(in buffer: CVPixelBuffer) -> [HandObservation] {
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
    guard (try? handler.perform([request])) != nil else { return [] }
    return (request.results ?? []).compactMap { observation in
      guard let points = try? observation.recognizedPoints(.all) else { return nil }
      var joints: [SIMD2<Float>] = []
      var confidences: [Float] = []
      for name in Self.joints {
        let point = points[name]
        joints.append(SIMD2(Float(point?.location.x ?? 0), 1 - Float(point?.location.y ?? 0)))
        confidences.append(point?.confidence ?? 0)
      }
      return HandObservation(joints: joints, confidences: confidences)
    }
  }
}
