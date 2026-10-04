import BlurtEngine
import Foundation

#if DEBUG
  /// Lets a signed local build replay a saved recording through the same API
  /// key and long-transcription path without exposing the key to a CLI tool.
  enum DebugFileTranscription {
    static func runIfRequested() -> Bool {
      let arguments = ProcessInfo.processInfo.arguments
      if let option = arguments.firstIndex(of: "--transcribe-fast-file"),
        arguments.indices.contains(option + 1)
      {
        runFastTranscription(at: arguments[option + 1])
        return true
      }
      if let option = arguments.firstIndex(of: "--normalize-file"),
        arguments.indices.contains(option + 1)
      {
        let textURL = URL(fileURLWithPath: arguments[option + 1])
        Task {
          do {
            let raw = try String(contentsOf: textURL, encoding: .utf8)
            let result = try await OpenRouterTextNormalizer(
              apiKeyProvider: { OpenRouterAPIKeyStore.current }
            ).normalizeWithMetadata(rawTranscript: raw, vocabulary: VocabularyStore().terms)
            FileHandle.standardOutput.write(
              Data(("[\(result.model ?? "unknown")]\n" + result.text + "\n").utf8))
            exit(EXIT_SUCCESS)
          } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
          }
        }
        return true
      }
      guard let option = arguments.firstIndex(of: "--transcribe-file"),
        arguments.indices.contains(option + 1)
      else { return false }
      let audioURL = URL(fileURLWithPath: arguments[option + 1])
      Task {
        do {
          let text = try await AssemblyAILongTranscriber().transcribe(
            audioFileURL: audioURL, vocabulary: VocabularyStore().terms)
          FileHandle.standardOutput.write(Data((text + "\n").utf8))
          exit(EXIT_SUCCESS)
        } catch {
          FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
          exit(EXIT_FAILURE)
        }
      }
      return true
    }

    private static func runFastTranscription(at path: String) {
      let audioURL = URL(fileURLWithPath: path)
      Task {
        do {
          let text = try await OpenRouterTranscriber().transcribe(
            audioFileURL: audioURL, vocabulary: VocabularyStore().terms)
          FileHandle.standardOutput.write(Data((text + "\n").utf8))
          exit(EXIT_SUCCESS)
        } catch {
          FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
          exit(EXIT_FAILURE)
        }
      }
    }
  }
#endif

/// The set of engine collaborators `AppCoordinator` composes into a
/// `DictationSession` — exactly the three pipeline seams, since
/// `MicCaptureProtocol` itself carries the mic's side features (the loudness
/// `levels` stream and `warmUp()`, both defaulted for stubs). Bundling them
/// behind one value lets the app swap the whole pipeline for deterministic test
/// doubles (see `DictationComponents.uiTest()`) without `AppCoordinator` knowing
/// which implementation it got — production wiring stays the default.
struct DictationComponents {
  let mic: any MicCaptureProtocol
  let transcriber: any TranscriberProtocol
  let injector: any InjectorProtocol
  let vibePipeline: VibeDictationPipeline?
  let fastVibePipeline: VibeDictationPipeline?
  let focusContextProvider: (@Sendable () -> TranscriptionContext?)?

  /// The real pipeline: a fresh `MicCapture`, Russian Universal-2 transcription,
  /// and the clipboard-paste injector. This is what `AppCoordinator` builds, so
  /// production behavior is unchanged by the test seam existing.
  static func production() -> DictationComponents {
    let short = AssemblyAITranscriber()
    return DictationComponents(
      mic: MicCapture(), transcriber: short, injector: KeyInjector(),
      vibePipeline: VibeDictationPipeline(
        router: STTRouter(
          shortClient: short, longClient: AssemblyAILongTranscriber(),
          preferAccurateRussian: true),
        normalizer: OpenRouterTextNormalizer(
          apiKeyProvider: { OpenRouterAPIKeyStore.current }),
        normalizationModel: { OpenRouterModelStore().modelID }),
      fastVibePipeline: VibeDictationPipeline(
        router: STTRouter(
          shortClient: short, longClient: OpenRouterTranscriber(),
          preferAccurateRussian: true),
        sttLabel: { "OpenRouter \(FastTranscriptionModelStore().modelID)" }),
      focusContextProvider: nil)
  }
}

// The key-storage seam (`APIKeyGateway`, with `ProductionAPIKeyStore` and the
// UI tests' `InMemoryAPIKeyStore`) lives in the engine —
// `Sources/BlurtEngine/Config/APIKeyGateway.swift` — so hosts and tests share
// one set of conformances.
//
// The UI-test sentinel API keys live in the shared `UITestIdentifiers`
// (Shared/UITestIdentifiers.swift), alongside the other test-facing constants —
// no longer an unconditionally-compiled enum here.
