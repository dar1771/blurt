public protocol TextNormalizer: Sendable {
  func normalize(rawTranscript: String, vocabulary: [String]) async throws -> String
  func normalizeWithMetadata(rawTranscript: String, vocabulary: [String]) async throws -> NormalizedText
}

public struct NormalizedText: Sendable, Equatable {
  public let text: String
  public let model: String?

  public init(text: String, model: String? = nil) {
    self.text = text
    self.model = model
  }
}

extension TextNormalizer {
  public func normalizeWithMetadata(
    rawTranscript: String, vocabulary: [String]
  ) async throws -> NormalizedText {
    NormalizedText(text: try await normalize(rawTranscript: rawTranscript, vocabulary: vocabulary))
  }
}

enum NormalizationFallback {
  static func short(
    normalized: String?, assemblyClean: String?, raw: String
  ) -> String {
    normalized.trimmedNonEmpty()
      ?? assemblyClean.trimmedNonEmpty()
      ?? raw
  }

  static func long(normalized: String?, raw: String) -> String {
    normalized.trimmedNonEmpty() ?? raw
  }
}
