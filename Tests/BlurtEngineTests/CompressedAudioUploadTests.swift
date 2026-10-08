import AVFoundation
import Foundation
import Testing

@testable import BlurtEngine

@Suite("Compressed audio upload")
struct CompressedAudioUploadTests {
  @Test("AAC preserves the full duration, source and channel layout", arguments: [1, 83, 600])
  func completeRecording(seconds: Int) throws {
    let url = try recording(seconds: seconds)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try Data(contentsOf: url)
    let prepared = try CompressedAudioUpload.prepare(url, compressed: true)
    #expect(prepared.format == "m4a")
    #expect(prepared.data.count < original.count)
    if seconds > 1 { #expect(prepared.data.count < original.count / 3) }
    #expect(try Data(contentsOf: url) == original)
    let copy = url.deletingPathExtension().appendingPathExtension("m4a")
    defer { try? FileManager.default.removeItem(at: copy) }
    try prepared.data.write(to: copy)
    let decoded = try AVAudioFile(forReading: copy)
    #expect(decoded.processingFormat.channelCount == 1)
    #expect(decoded.processingFormat.sampleRate == 16_000)
    #expect(abs(Double(decoded.length) / 16_000 - Double(seconds)) < 0.15)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 8192))
    var frames: AVAudioFramePosition = 0
    while decoded.framePosition < decoded.length {
      try decoded.read(into: buffer)
      #expect(buffer.frameLength > 0)
      frames += AVAudioFramePosition(buffer.frameLength)
    }
    #expect(frames == decoded.length)
  }

  @Test("Opt-out and invalid audio retain original bytes")
  func originalFallback() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data([1, 2, 3, 4])
    try original.write(to: url)
    for enabled in [true, false] {
      let upload = try CompressedAudioUpload.prepare(url, compressed: enabled)
      #expect(upload.format == "wav")
      #expect(upload.data == original)
    }
    let defaults = freshDefaults()
    let store = AudioUploadCompressionStore(defaults: defaults)
    #expect(store.isEnabled)
    defaults.set(false, forKey: AudioUploadCompressionStore.defaultsKey)
    #expect(!store.isEnabled)
  }

  @Test("Cancellation does not fall back to another upload")
  func cancelledPreparation() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try CompressedAudioUpload.prepare(URL(fileURLWithPath: "/nonexistent.wav"), compressed: true)
    }
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test("Unsupported compressed format retries once with unchanged WAV", arguments: [400, 415, 401])
  func compressedWireFallback(status: Int) async throws {
    let url = try recording(seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try Data(contentsOf: url)
    let formats = ValueBox([String]())
    let transcriber = OpenRouterTranscriber(
      apiKeyProvider: { "key" }, modelProvider: { OpenRouterTranscriber.defaultModel },
      compressionEnabledProvider: { true },
      transport: FakeHTTPTransport { request in
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let audio = body?["input_audio"] as? [String: String]
        formats.value.append(audio?["format"] ?? "missing")
        if formats.value.count == 1 { return (status, Data()) }
        #expect(audio?["data"] == original.base64EncodedString())
        return (200, Data(#"{"text":"Готово."}"#.utf8))
      })
    if status == 401 {
      await #expect(throws: OpenRouterTranscriptionError.self) {
        try await transcriber.transcribe(audioFileURL: url, vocabulary: [])
      }
      #expect(formats.value == ["m4a"])
    } else {
      #expect(try await transcriber.transcribe(audioFileURL: url, vocabulary: []) == "Готово.")
      #expect(formats.value == ["m4a", "wav"])
    }
  }

  private func recording(seconds: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let output = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      ])
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
    let channel = try #require(buffer.floatChannelData?[0])
    buffer.frameLength = 1600
    for sample in 0..<1600 { channel[sample] = Float(sin(Double(sample) * 0.1)) * 0.2 }
    for _ in 0..<(seconds * 10) { try output.write(from: buffer) }
    return url
  }
}
