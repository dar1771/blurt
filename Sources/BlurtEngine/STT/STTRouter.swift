import Foundation

public struct ShortTranscription: Sendable, Equatable {
  public let raw: String
  public let assemblyClean: String?
  public init(raw: String, assemblyClean: String?) {
    self.raw = raw
    self.assemblyClean = assemblyClean
  }
}

public protocol ShortSTTClient: Sendable {
  func transcribeShort(
    frames: AsyncStream<Data>, sampleRate: Int,
    context: TranscriptionContext?
  ) async throws -> ShortTranscription
}

public protocol LongSTTClient: Sendable {
  func transcribe(audioFileURL: URL, vocabulary: [String]) async throws -> String
}

public struct RoutedTranscription: Sendable, Equatable {
  public let mode: DictationPipelineMode
  public let raw: String
  public let assemblyClean: String?
  public let sttProvider: String?
  public let fallbackReason: String?

  public init(
    mode: DictationPipelineMode, raw: String, assemblyClean: String?, sttProvider: String? = nil,
    fallbackReason: String? = nil
  ) {
    self.mode = mode
    self.raw = raw
    self.assemblyClean = assemblyClean
    self.sttProvider = sttProvider
    self.fallbackReason = fallbackReason
  }
}

public struct STTRouter: Sendable {
  public static let shortModeCutoverSeconds: TimeInterval = 115

  private let shortClient: any ShortSTTClient
  private let longClient: any LongSTTClient
  private let shortRecordingClient: (any LongSTTClient)?
  private let shortRecordingLabel: @Sendable () -> String
  private let shortRecordingThresholdSeconds: TimeInterval
  private let cutoverDelay: Duration
  private let preferAccurateRussian: Bool

  public init(
    shortClient: any ShortSTTClient, longClient: any LongSTTClient,
    shortRecordingClient: (any LongSTTClient)? = nil,
    shortRecordingLabel: @escaping @Sendable () -> String = { "" },
    shortRecordingThresholdSeconds: TimeInterval = STTRouter.shortModeCutoverSeconds,
    cutoverDelay: Duration = .seconds(STTRouter.shortModeCutoverSeconds),
    preferAccurateRussian: Bool = false
  ) {
    self.shortClient = shortClient
    self.longClient = longClient
    self.shortRecordingClient = shortRecordingClient
    self.shortRecordingLabel = shortRecordingLabel
    self.shortRecordingThresholdSeconds = shortRecordingThresholdSeconds
    self.cutoverDelay = cutoverDelay
    self.preferAccurateRussian = preferAccurateRussian
  }

  /// Starts WAV persistence and the 115-second cutover immediately, while the
  /// short request may still be waiting briefly for press-time AX context.
  public func start(
    frames: AsyncStream<Data>, writer: any LocalAudioWriter,
    contextProvider: @escaping @Sendable () async -> TranscriptionContext?,
    vocabulary: [String], onCutover: @escaping @Sendable () -> Void = {}
  ) -> STTRoutingSession {
    let fanout = PCMFrameFanout(source: frames, writer: writer)
    let shortTask: Task<ShortTranscription, any Error>?
    if preferAccurateRussian {
      fanout.stopShortFeed()
      shortTask = nil
    } else {
      shortTask = Task {
        let context = await contextProvider()
        return try await shortClient.transcribeShort(
          frames: fanout.shortFrames, sampleRate: SyncSTTLimits.sampleRate,
          context: context)
      }
    }
    let cutoverState = STTCutoverState()
    let cutoverTask = Task {
      try? await Task.sleep(for: cutoverDelay)
      guard !Task.isCancelled else { return }
      cutoverState.markReached()
      shortTask?.cancel()
      fanout.stopShortFeed()
      onCutover()
    }
    return STTRoutingSession(
      shortTask: shortTask, cutoverTask: cutoverTask,
      audioCompletion: fanout.completion, longClient: longClient,
      shortRecordingClient: shortRecordingClient,
      shortRecordingLabel: shortRecordingLabel,
      shortRecordingThresholdSeconds: shortRecordingThresholdSeconds,
      vocabulary: vocabulary, stopShortFeed: { fanout.stopShortFeed() },
      cutoverState: cutoverState, preferAccurateRussian: preferAccurateRussian)
  }
}

public final class STTRoutingSession: Sendable {
  private let shortTask: Task<ShortTranscription, any Error>?
  private let cutoverTask: Task<Void, Never>
  private let audioCompletion: Task<Void, any Error>
  private let longClient: any LongSTTClient
  private let shortRecordingClient: (any LongSTTClient)?
  private let shortRecordingLabel: @Sendable () -> String
  private let shortRecordingThresholdSeconds: TimeInterval
  private let vocabulary: [String]
  private let stopShortFeed: @Sendable () -> Void
  private let cutoverState: STTCutoverState
  private let preferAccurateRussian: Bool

  fileprivate init(
    shortTask: Task<ShortTranscription, any Error>?, cutoverTask: Task<Void, Never>,
    audioCompletion: Task<Void, any Error>, longClient: any LongSTTClient,
    shortRecordingClient: (any LongSTTClient)?,
    shortRecordingLabel: @escaping @Sendable () -> String,
    shortRecordingThresholdSeconds: TimeInterval,
    vocabulary: [String], stopShortFeed: @escaping @Sendable () -> Void,
    cutoverState: STTCutoverState, preferAccurateRussian: Bool
  ) {
    self.shortTask = shortTask
    self.cutoverTask = cutoverTask
    self.audioCompletion = audioCompletion
    self.longClient = longClient
    self.shortRecordingClient = shortRecordingClient
    self.shortRecordingLabel = shortRecordingLabel
    self.shortRecordingThresholdSeconds = shortRecordingThresholdSeconds
    self.vocabulary = vocabulary
    self.stopShortFeed = stopShortFeed
    self.cutoverState = cutoverState
    self.preferAccurateRussian = preferAccurateRussian
  }

  public func stop(durationSeconds: TimeInterval, audioFileURL: URL) async throws -> RoutedTranscription {
    cutoverTask.cancel()
    let preparationStart = ContinuousClock.now
    try await audioCompletion.value
    RequestLatency.stage("audio-finalize-wait", since: preparationStart)
    if preferAccurateRussian || cutoverState.wasReached
      || durationSeconds >= STTRouter.shortModeCutoverSeconds
    {
      shortTask?.cancel()
      stopShortFeed()
      var fallbackReason: String?
      if durationSeconds < shortRecordingThresholdSeconds, let shortRecordingClient {
        do {
          let raw = try await shortRecordingClient.transcribe(
            audioFileURL: audioFileURL, vocabulary: vocabulary)
          return RoutedTranscription(
            mode: .long, raw: raw, assemblyClean: nil,
            sttProvider: shortRecordingLabel())
        } catch {
          if error is CancellationError || Task.isCancelled { throw error }
          // Keep the established Russian route available if OpenRouter fails.
          fallbackReason = "Использовано резервное распознавание: \(error.localizedDescription)"
        }
      }
      let raw = try await longClient.transcribe(
        audioFileURL: audioFileURL, vocabulary: vocabulary)
      return RoutedTranscription(
        mode: .long, raw: raw, assemblyClean: nil, fallbackReason: fallbackReason)
    }
    guard let shortTask else { throw CancellationError() }
    let short = try await shortTask.value
    // The dictation endpoint chooses its own model. In Russian-first mode it can
    // return phonetic Latin text even with language_codes=["ru"]. The saved WAV
    // lets Universal-2 retry with an explicit Russian language code.
    if Self.looksLikeLatinTransliteration(short.raw),
      let russian = try? await longClient.transcribe(
        audioFileURL: audioFileURL, vocabulary: vocabulary)
    {
      return RoutedTranscription(mode: .long, raw: russian, assemblyClean: nil)
    }
    return RoutedTranscription(
      mode: .short, raw: short.raw, assemblyClean: short.assemblyClean)
  }

  private static func looksLikeLatinTransliteration(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    guard !scalars.contains(where: { (0x0400...0x052F).contains($0.value) }) else { return false }
    let latinLetters = scalars.filter {
      (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
    }
    return latinLetters.count >= 16 && text.split(whereSeparator: { $0.isWhitespace }).count >= 3
  }

  public func cancel() {
    cutoverTask.cancel()
    shortTask?.cancel()
    stopShortFeed()
    audioCompletion.cancel()
  }
}

final class STTCutoverState: Sendable {
  private let reached = Mutex(false)

  var wasReached: Bool { reached.withLock { $0 } }
  func markReached() { reached.withLock { $0 = true } }
}
