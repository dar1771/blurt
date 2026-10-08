import Foundation
import Testing

@testable import BlurtEngine

@Suite("OpenRouter fast transcription")
struct OpenRouterTranscriberTests {
  @Test("a temporary 429 retries the same audio after a bounded pause")
  func rateLimitRecovers() async throws {
    let audio = try temporaryAudio()
    defer { try? FileManager.default.removeItem(at: audio) }
    let calls = Counter()
    let delays = Mutex<[TimeInterval]>([])
    let bodies = Mutex<[Data]>([])
    let client = OpenRouterTranscriber(
      apiKeyProvider: { "test-key" },
      transport: FakeHTTPTransport { request in
        bodies.withLock { $0.append(request.httpBody ?? Data()) }
        return calls.next() == 1 ? (429, Data()) : (200, json(["text": "Готово"]))
      }, sleep: { delay in delays.withLock { $0.append(delay) } })
    #expect(try await client.transcribe(audioFileURL: audio, vocabulary: []) == "Готово")
    #expect(calls.value == 2)
    #expect(delays.withLock { $0 } == [2])
    #expect(bodies.withLock { $0.count == 2 && $0[0] == $0[1] })
  }

  @Test("persistent 429 stops after three requests; authentication is never retried")
  func retryLimit() async throws {
    let audio = try temporaryAudio()
    defer { try? FileManager.default.removeItem(at: audio) }
    for status in [429, 401] {
      let calls = Counter()
      let delays = Mutex<[TimeInterval]>([])
      let client = OpenRouterTranscriber(
        apiKeyProvider: { "test-key" },
        transport: FakeHTTPTransport { _ in
          _ = calls.next()
          return (status, Data())
        }, sleep: { delay in delays.withLock { $0.append(delay) } })
      await #expect(throws: OpenRouterTranscriptionError.self) {
        try await client.transcribe(audioFileURL: audio, vocabulary: [])
      }
      #expect(calls.value == (status == 429 ? 3 : 1))
      #expect(delays.withLock { $0 } == (status == 429 ? [2, 4] : []))
    }
  }

  @Test("cancellation during backoff prevents a second upload")
  func cancelledBackoff() async throws {
    let audio = try temporaryAudio()
    defer { try? FileManager.default.removeItem(at: audio) }
    let calls = Counter()
    let client = OpenRouterTranscriber(
      apiKeyProvider: { "test-key" },
      transport: FakeHTTPTransport { _ in
        _ = calls.next()
        return (429, Data())
      }, sleep: { _ in throw CancellationError() })
    await #expect(throws: CancellationError.self) {
      try await client.transcribe(audioFileURL: audio, vocabulary: [])
    }
    #expect(calls.value == 1)
  }

  private func temporaryAudio() throws -> URL {
    let audio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: audio)
    return audio
  }

  @Test("Retry-After is honored; an excessive delay fails without an early retry")
  func providerDelay() async throws {
    let audio = try temporaryAudio()
    defer { try? FileManager.default.removeItem(at: audio) }
    for header in ["7", "60", "Thu, 01 Jan 2099 00:00:00 GMT"] {
      let calls = Counter()
      let delays = Mutex<[TimeInterval]>([])
      let client = OpenRouterTranscriber(
        apiKeyProvider: { "test-key" },
        transport: FakeHTTPTransport(headers: ["Retry-After": header]) { _ in
          return calls.next() == 1 ? (429, Data()) : (200, json(["text": "Готово"]))
        }, sleep: { value in delays.withLock { $0.append(value) } })
      if header == "7" {
        #expect(try await client.transcribe(audioFileURL: audio, vocabulary: []) == "Готово")
        #expect(calls.value == 2)
        #expect(delays.withLock { $0 } == [7])
      } else {
        await #expect(throws: OpenRouterTranscriptionError.self) {
          try await client.transcribe(audioFileURL: audio, vocabulary: [])
        }
        #expect(calls.value == 1)
        #expect(delays.withLock { $0.isEmpty })
      }
    }
  }

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
