import AVFoundation
import Foundation

/// Transport copy only. The recording retained in history is never modified.
struct CompressedAudioUpload {
  let data: Data
  let format: String

  static func prepare(_ source: URL, compressed: Bool) throws -> Self {
    try Task.checkCancellation()
    let original = try Data(contentsOf: source, options: .mappedIfSafe)
    guard compressed else { return Self(data: original, format: "wav") }
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibedictate-upload-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      let encodingStart = ContinuousClock.now
      try encode(source, to: temporary)
      RequestLatency.stage("stt-encode", since: encodingStart, bytes: 0)
      try Task.checkCancellation()
      let encoded = try Data(contentsOf: temporary)
      guard !encoded.isEmpty, encoded.count < original.count else {
        return Self(data: original, format: "wav")
      }
      return Self(data: encoded, format: "m4a")
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Unavailable codec or malformed input: retain the original upload path.
      try Task.checkCancellation()
      return Self(data: original, format: "wav")
    }
  }

  private static func encode(_ source: URL, to destination: URL) throws {
    let input = try AVAudioFile(forReading: source)
    let output = try AVAudioFile(
      forWriting: destination,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: input.processingFormat.sampleRate,
        AVNumberOfChannelsKey: input.processingFormat.channelCount,
        AVEncoderBitRateKey: 48_000,
      ], commonFormat: input.processingFormat.commonFormat,
      interleaved: input.processingFormat.isInterleaved)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
      throw CocoaError(.fileReadUnknown)
    }
    while input.framePosition < input.length {
      try Task.checkCancellation()
      try input.read(into: buffer)
      guard buffer.frameLength > 0 else { throw CocoaError(.fileReadUnknown) }
      try output.write(from: buffer)
    }
    // The writer closes and finalizes the M4A container before prepare reads it.
  }
}

public struct AudioUploadCompressionStore {
  public static var defaultsKey: String { DefaultsKey.audioUploadCompression.key }
  public static let defaultValue = true
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var isEnabled: Bool {
    defaults.object(forKey: Self.defaultsKey) as? Bool ?? Self.defaultValue
  }
}
