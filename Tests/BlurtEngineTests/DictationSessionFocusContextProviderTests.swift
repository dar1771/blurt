import Testing

@testable import BlurtEngine

@Suite("DictationSession host focus context")
struct DictationSessionFocusContextProviderTests {
  @Test("a supplied ordinary target is remembered, and a missing target fails closed")
  func hostFocusContextSafety() async throws {
    let safe = makeSession(
      mode: .transcript("UI transcript."),
      focusContextProvider: {
        TranscriptionContext(
          appName: "UI Test", fieldLabel: "Test destination", priorText: nil)
      })
    await safe.session.press()
    await safe.session.release()
    await safe.session.waitForIdle()
    #expect(await safe.session.recentDictations.entries.first?.text == "UI transcript.")
    #expect(await safe.session.capturedContext?.targetIsSecure == false)

    let unknown = makeSession(
      mode: .transcript("must not be remembered."), focusContextProvider: { nil })
    await unknown.session.press()
    await unknown.session.release()
    await unknown.session.waitForIdle()
    #expect(await unknown.session.capturedContext?.targetIsSecure == true)
    #expect(await unknown.session.recentDictations.entries.isEmpty)
  }
}
