import Foundation

/// Transcribes the saved WAV directly; no text-normalization request is made.
public struct OpenRouterTranscriber: LongSTTClient {
  public static let defaultModel = "microsoft/mai-transcribe-2"

  private let apiKeyProvider: @Sendable () -> String?
  private let modelProvider: @Sendable () -> String
  private let transport: any HTTPTransport
  private let endpoint: URL

  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { OpenRouterAPIKeyStore.current },
    modelProvider: @escaping @Sendable () -> String = { FastTranscriptionModelStore().modelID },
    transport: any HTTPTransport = URLSession.shared,
    endpoint: URL = URL(staticString: "https://openrouter.ai/api/v1/audio/transcriptions")
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.modelProvider = modelProvider
    self.transport = transport
    self.endpoint = endpoint
  }

  public func transcribe(audioFileURL: URL, vocabulary: [String]) async throws -> String {
    guard let key = apiKeyProvider()?.trimmedNonEmpty() else {
      throw OpenRouterTranscriptionError.missingAPIKey
    }
    let model = modelProvider()
    let audio = try Data(contentsOf: audioFileURL, options: .mappedIfSafe)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setUserAgent()
    request.httpBody = try JSONEncoder().encode(
      Request(
        model: model,
        inputAudio: InputAudio(data: audio.base64EncodedString(), format: "wav"),
        language: "ru",
        provider: model == Self.defaultModel
          ? Provider(
            options: ProviderOptions(
              azure: AzureOptions(
                enhancedMode: EnhancedMode(modelOptions: ModelOptions(transcribeStyle: "clean")),
                phraseList: PhraseList(phrases: vocabulary)))) : nil))
    let (data, response) = try await transport.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw OpenRouterTranscriptionError.httpStatus(http.statusCode)
    }
    guard let text = try JSONDecoder().decode(Response.self, from: data).text.trimmedNonEmpty()
    else { throw OpenRouterTranscriptionError.emptyResponse }
    return text
  }

  struct Request: Encodable {
    let model: String
    let inputAudio: InputAudio
    let language: String
    let provider: Provider?

    enum CodingKeys: String, CodingKey {
      case model, language, provider
      case inputAudio = "input_audio"
    }
  }
  struct InputAudio: Encodable {
    let data: String
    let format: String
  }
  struct Provider: Encodable { let options: ProviderOptions }
  struct ProviderOptions: Encodable { let azure: AzureOptions }
  struct AzureOptions: Encodable {
    let enhancedMode: EnhancedMode
    let phraseList: PhraseList
  }
  struct EnhancedMode: Encodable { let modelOptions: ModelOptions }
  struct ModelOptions: Encodable { let transcribeStyle: String }
  struct PhraseList: Encodable { let phrases: [String] }
  struct Response: Decodable { let text: String }
}

enum OpenRouterTranscriptionError: Error, LocalizedError, Sendable {
  case missingAPIKey
  case httpStatus(Int)
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Добавьте ключ OpenRouter в настройках VibeDictate."
    case .httpStatus(let status): "Ошибка распознавания OpenRouter: код \(status)."
    case .emptyResponse: "OpenRouter вернул пустую расшифровку."
    }
  }
}

public struct FastTranscriptionModelStore {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public static var defaultsKey: String { DefaultsKey.fastTranscriptionModel.key }
  public var modelID: String {
    defaults.string(forKey: Self.defaultsKey).trimmedNonEmpty()
      ?? OpenRouterTranscriber.defaultModel
  }
  public func save(_ modelID: String) {
    defaults.set(modelID.trimmedNonEmpty(), forKey: Self.defaultsKey)
  }
}
