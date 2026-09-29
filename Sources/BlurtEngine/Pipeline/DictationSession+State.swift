extension DictationSession {
  func cancelAutoRelease() {
    autoReleaseTask?.cancel()
    autoReleaseTask = nil
  }
}
