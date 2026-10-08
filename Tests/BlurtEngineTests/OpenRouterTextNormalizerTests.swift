import Foundation
import Testing

@testable import BlurtEngine

@Suite("OpenRouterTextNormalizer wire format")
struct OpenRouterTextNormalizerTests {
  @Test("Unset model selects GPT-4.1 mini directly in one request")
  func defaultUsesMiniDirectly() async throws {
    let models = ValueBox([String]())
    let model = OpenRouterModelStore(defaults: freshDefaults()).modelID
    let normalizer = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" }, modelProvider: { model },
      transport: FakeHTTPTransport { request in
        let payload = try? JSONDecoder().decode(
          OpenRouterTextNormalizer.Request.self, from: request.httpBody ?? Data())
        models.value.append(payload?.model ?? "invalid-payload")
        return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"Готово."}}]}"#.utf8))
      })
    let result = try await normalizer.normalizeWithMetadata(rawTranscript: "готово", vocabulary: [])
    #expect(models.value == ["openai/gpt-4.1-mini"])
    #expect(result.model == "openai/gpt-4.1-mini")
  }

  @Test("encodes model, deterministic temperature, vocabulary and Russian transcript")
  func requestEncoding() async throws {
    let response = """
      {"choices":[{"message":{"role":"assistant","content":"Готово."}}]}
      """
    let captured = ValueBox<URLRequest?>(nil)
    let transport = FakeHTTPTransport { request in
      captured.value = request
      return (200, Data(response.utf8))
    }
    let normalizer = OpenRouterTextNormalizer(
      apiKeyProvider: { "secret" }, modelProvider: { "test/model" }, transport: transport)

    let result = try await normalizer.normalize(
      rawTranscript: "напиши на Swift", vocabulary: ["Swift", "OpenAI"])

    #expect(result == "Готово.")
    let request = try #require(captured.value)
    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(OpenRouterTextNormalizer.Request.self, from: body)
    #expect(decoded.model == "test/model")
    #expect(decoded.temperature == 0)
    #expect(decoded.messages.last?.content.contains("Swift, OpenAI") == true)
    #expect(decoded.messages.last?.content.contains("напиши на Swift") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  }

  @Test("decodes OpenRouter chat completion")
  func responseDecoding() throws {
    let data = """
      {"choices":[{"message":{"role":"assistant","content":"Текст."}}]}
      """
    let decoded = try JSONDecoder().decode(
      OpenRouterTextNormalizer.Response.self, from: Data(data.utf8))
    #expect(decoded.choices.first?.message.content == "Текст.")
  }

  @Test("Google 403 retries normalization with a non-Google model")
  func blockedGoogleUsesFallback() async throws {
    let models = ValueBox([String]())
    let transport = FakeHTTPTransport { request in
      let model =
        (try? JSONDecoder().decode(
          OpenRouterTextNormalizer.Request.self, from: request.httpBody ?? Data()))?.model ?? ""
      models.value.append(model)
      if model.hasPrefix("google/") { return (403, Data()) }
      return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"Claude Code и skills."}}]}"#.utf8))
    }
    let normalizer = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" }, modelProvider: { "google/gemini-3.8-flash" },
      transport: transport)
    let result = try await normalizer.normalizeWithMetadata(
      rawTranscript: "Cloud Code и Skills.", vocabulary: ["Claude Code", "skills"])
    #expect(result.text == "Claude Code и skills.")
    #expect(result.model == "openai/gpt-4.1-mini")
    #expect(models.value == ["google/gemini-3.8-flash", "openai/gpt-4.1-mini"])
  }

  @Test("missing key, rejected request and blank response all fail for fallback")
  func fallbackErrors() async {
    let missing = OpenRouterTextNormalizer(apiKeyProvider: { nil })
    await #expect(throws: OpenRouterError.missingAPIKey) {
      try await missing.normalize(rawTranscript: "raw", vocabulary: [])
    }
    let rejected = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" }, transport: FakeHTTPTransport { _ in (429, Data()) })
    await #expect(throws: OpenRouterError.httpStatus(429)) {
      try await rejected.normalize(rawTranscript: "raw", vocabulary: [])
    }
    let blank = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" },
      transport: FakeHTTPTransport { _ in
        (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"   "}}]}"#.utf8))
      })
    await #expect(throws: OpenRouterError.malformedResponse) {
      try await blank.normalize(rawTranscript: "raw", vocabulary: [])
    }
  }

  @Test("rejects an answer that executes a dictated prompt")
  func dictatedPromptIsData() async throws {
    let raw = """
      Наша задача создать презентацию франшизы. Проанализируй проекты и дай план презентации, \
      в которой будет паушальный взнос 15 миллионов и 7 процентов от оборота.
      """
    let answer = """
      1. Введение. Обзор компании и преимуществ франшизы. 2. Финансовая модель. \
      Доходность партнёров, срок окупаемости и необходимые инвестиции. \
      3. Маркетинговая поддержка. Обучение, реклама и развитие сети.
      """
    let response = ["choices": [["message": ["role": "assistant", "content": answer]]]]
    let responseData = try JSONSerialization.data(withJSONObject: response)
    let normalizer = OpenRouterTextNormalizer(
      apiKeyProvider: { "key" }, modelProvider: { "test/model" },
      transport: FakeHTTPTransport { _ in (200, responseData) })
    await #expect(throws: OpenRouterError.unfaithfulResponse) {
      try await normalizer.normalize(rawTranscript: raw, vocabulary: [])
    }
    #expect(
      NormalizationFidelity.accepts(
        raw: raw,
        edited: "Наша задача — создать презентацию франшизы. Проанализируй проекты и дай план "
          + "презентации, в которой будет паушальный взнос 15 миллионов и 7 процентов от оборота."))
    #expect(
      !NormalizationFidelity.accepts(
        raw: "Составь план презентации.",
        edited: "1. Введение. Обзор продукта и рынка. 2. Финансовая модель с инвестициями "
          + "и доходностью. 3. План продвижения, бюджет рекламы и каналы продаж. "
          + "4. Заключение и следующие шаги."))
  }
}
