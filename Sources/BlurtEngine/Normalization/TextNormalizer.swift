public protocol TextNormalizer: Sendable {
  func normalize(rawTranscript: String, vocabulary: [String]) async throws -> String
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
