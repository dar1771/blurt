import AVFoundation
import AppKit
import BlurtEngine

extension HistoryModel {
  var injector: KeyInjector { historyInjector }

  func insertLast() {
    Task {
      guard let store = historyStore else { return }
      do {
        let newest = try await store.newest()
        switch LatestDictationDecision.resolve(records: newest.map { [$0] } ?? []) {
        case .insert(let recordID, let text):
          try await injector.insert(recordID: recordID, text: text)
          message = "Последняя диктовка вставлена."
        case .processing: message = "Последняя диктовка ещё обрабатывается."
        case .failed: message = "Последняя диктовка завершилась ошибкой."
        case .noHistory: message = "История пока пуста."
        case .readyWithoutText: message = "В последней диктовке нет готового текста."
        }
      } catch { message = error.localizedDescription }
    }
  }

  func insert(_ record: DictationRecord) {
    Task {
      do {
        guard let stored = try await historyStore?.record(id: record.id),
          let text = stored.preferredText
        else { return }
        try await injector.insert(recordID: record.id, text: text)
        message = "Текст вставлен."
      } catch { message = error.localizedDescription }
    }
  }

  func copy(_ record: DictationRecord) {
    guard let text = record.preferredText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    message = "Текст скопирован."
  }

  func togglePlayback(_ record: DictationRecord) {
    if playingRecordID == record.id {
      guard let audioPlayer else { return }
      if audioPlayer.isPlaying {
        audioPlayer.pause()
        isPlaying = false
      } else {
        isPlaying = audioPlayer.play()
      }
      return
    }
    stopPlayback()
    guard let path = record.audioRelativePath,
      let url = try? Self.applicationSupportURL().appending(path: path)
    else { return }
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.prepareToPlay()
      audioPlayer = player
      playingRecordID = record.id
      playbackDuration = player.duration
      isPlaying = player.play()
      playbackTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(200))
          guard !Task.isCancelled else { return }
          self?.refreshPlayback()
        }
      }
    } catch {
      message = "Не удалось открыть аудио: \(error.localizedDescription)"
    }
  }

  func seekPlayback(to seconds: TimeInterval) {
    guard let audioPlayer else { return }
    audioPlayer.currentTime = min(max(seconds, 0), audioPlayer.duration)
    playbackSeconds = audioPlayer.currentTime
  }

  func stopPlayback() {
    playbackTask?.cancel()
    playbackTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    playingRecordID = nil
    playbackSeconds = 0
    playbackDuration = 0
    isPlaying = false
  }

  private func refreshPlayback() {
    guard let audioPlayer else { return }
    playbackSeconds = audioPlayer.currentTime
    if isPlaying && !audioPlayer.isPlaying {
      stopPlayback()
    }
  }

  func showAudioFile(_ record: DictationRecord) {
    guard let path = record.audioRelativePath,
      let url = try? Self.applicationSupportURL().appending(path: path)
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func delete(_ record: DictationRecord) {
    if playingRecordID == record.id { stopPlayback() }
    Task {
      do {
        if let path = record.audioRelativePath,
          let url = try? Self.applicationSupportURL().appending(path: path)
        {
          try? FileManager.default.removeItem(at: url)
        }
        try await historyStore?.delete(id: record.id)
        selection = nil
        await load()
      } catch { message = error.localizedDescription }
    }
  }

  func clearHistory() {
    stopPlayback()
    Task {
      do {
        for record in try await historyStore?.all() ?? [] {
          if let path = record.audioRelativePath,
            let url = try? Self.applicationSupportURL().appending(path: path)
          {
            try? FileManager.default.removeItem(at: url)
          }
        }
        try await historyStore?.deleteAll()
        activeRecord = nil
        selection = nil
        await load()
        message = "История очищена."
      } catch { message = error.localizedDescription }
    }
  }
}
