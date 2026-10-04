import Foundation
import Testing

@testable import BlurtEngine

@Suite("OpenRouter fast transcription")
struct OpenRouterTranscriberTests {
  @Test("MAI request carries Russian, audio, vocabulary and clean mode")
  func maiRequest() async throws {
    let audio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: audio)
    defer { try? FileManager.default.removeItem(at: audio) }
    let captured = Mutex<URLRequest?>(nil)
    let client = OpenRouterTranscriber(
      apiKeyProvider: { "test-key" },
      transport: FakeHTTPTransport { request in
        captured.withLock { $0 = request }
        return (200, json(["text": " Привет, Claude Code. "]))
      })
    let text = try await client.transcribe(audioFileURL: audio, vocabulary: ["Claude Code"])
    #expect(text == "Привет, Claude Code.")
    let request = try #require(captured.withLock { $0 })
    #expect(request.url?.path == "/api/v1/audio/transcriptions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["model"] as? String == OpenRouterTranscriber.defaultModel)
    #expect(payload["language"] as? String == "ru")
    let input = try #require(payload["input_audio"] as? [String: String])
    #expect(input["format"] == "wav")
    #expect(input["data"] == Data([1, 2, 3, 4]).base64EncodedString())
    let provider = try #require(payload["provider"] as? [String: Any])
    let options = try #require(provider["options"] as? [String: Any])
    let azure = try #require(options["azure"] as? [String: Any])
    let phraseList = try #require(azure["phraseList"] as? [String: Any])
    #expect(phraseList["phrases"] as? [String] == ["Claude Code"])
  }

  @Test("other models omit MAI-specific options")
  func otherModel() async throws {
    let audio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
    try Data([1]).write(to: audio)
    defer { try? FileManager.default.removeItem(at: audio) }
    let captured = Mutex<URLRequest?>(nil)
    let client = OpenRouterTranscriber(
      apiKeyProvider: { "test-key" }, modelProvider: { "openai/whisper-large-v3" },
      transport: FakeHTTPTransport { request in
        captured.withLock { $0 = request }
        return (200, json(["text": "Готово"]))
      })
    _ = try await client.transcribe(audioFileURL: audio, vocabulary: ["Swift"])
    let body = try #require(captured.withLock { $0?.httpBody })
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["provider"] == nil)
  }
}
