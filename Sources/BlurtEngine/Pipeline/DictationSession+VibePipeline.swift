import Foundation

extension DictationSession {
  func startVibeRouting(frames: AsyncStream<Data>) async {
    guard let pipeline = activeVibePipeline, let job = currentJob else { return }
    var record = DictationRecord(job: job, status: .processing)
    currentRecord = record
    pipeline.onRecordChanged(record)
    do {
      let writer = try pipeline.makeAudioWriter(job.id)
      localAudioWriter = writer
      record.audioRelativePath = await writer.relativePath
      currentRecord = record
      pipeline.onRecordChanged(record)

      let press = pressContext
      let clock = clock
      let jobID = job.id
      routingSession = pipeline.router.start(
        frames: frames, writer: writer,
        contextProvider: {
          let resolved = await press?.wait(within: Self.contextWaitBudget, clock: clock)
          return resolved ?? press?.pressKnown
        },
        vocabulary: keyTermsProvider(),
        onCutover: { [weak self] in
          Task { await self?.enterLongMode(jobID: jobID) }
        })
    } catch {
      try? await mic.cancelCapture()
      await failVibeRecord(error)
    }
  }

  func enterLongMode(jobID: UUID) {
    guard currentJob?.id == jobID, phase == .recording else { return }
    if var record = currentRecord {
      record.pipelineMode = .long
      currentRecord = record
      activeVibePipeline?.onRecordChanged(record)
    }
    setPhase(.longMode)
  }

  func runVibeTranscribeNormalizeInject() async {
    // A cancel can clear the route after release claimed `.transcribing` but
    // before its pipeline task starts. That is a completed cancellation, not
    // an upload setup failure.
    guard phase != .cancelled, !Task.isCancelled else { return }
    guard let pipeline = activeVibePipeline, let route = routingSession,
      let writer = localAudioWriter, let job = currentJob, var record = currentRecord
    else {
      setPhase(.failed(.sttFailed(underlying: DictationPipelineError.uploadNeverStarted)))
      return
    }
    defer { clearCompletedVibeJob(id: job.id) }

    do {
      let bytesPerSecond = Int64(
        SyncSTTLimits.sampleRate * SyncSTTLimits.channelCount * (SyncSTTLimits.bitDepth / 8))
      record.durationMs = Int64(recordedByteCount) * 1_000 / bytesPerSecond
      record.targetAppName = capturedContext?.appName ?? record.targetAppName
      record.targetWindowTitle = capturedContext?.windowTitle
      let routed = try await route.stop(
        durationSeconds: Double(record.durationMs) / 1_000,
        audioFileURL: await writer.fileURL)
      if Task.isCancelled { return }
      await normalizeAndDeliverVibe(
        record: completedRecord(record, routed: routed), routed: routed,
        job: job, pipeline: pipeline)
    } catch {
      if Task.isCancelled || error is CancellationError { return }
      currentRecord = record
      await failVibeRecord(error)
      return
    }
  }

  private func clearCompletedVibeJob(id: UUID) {
    guard currentJob?.id == id else { return }
    routingSession = nil
    localAudioWriter = nil
    currentJob = nil
    currentRecord = nil
  }

  private func completedRecord(
    _ initialRecord: DictationRecord, routed: RoutedTranscription
  ) -> DictationRecord {
    var record = initialRecord
    record.pipelineMode = routed.mode
    record.sttProvider =
      routed.mode == .short ? "AssemblyAI Dictation API" : activeVibePipeline?.sttLabel() ?? "AssemblyAI Universal-2"
    record.rawTranscript = routed.raw
    record.assemblyCleanTranscript = routed.assemblyClean
    currentRecord = record
    activeVibePipeline?.onRecordChanged(record)
    return record
  }

  func normalizeAndDeliverVibe(
    record initialRecord: DictationRecord, routed: RoutedTranscription, job: DictationJob,
    pipeline: VibeDictationPipeline
  ) async {
    var record = initialRecord

    var normalized: NormalizedText?
    if let normalizer = pipeline.normalizer, routed.raw.trimmedNonEmpty() != nil {
      setPhase(.normalizing)
      normalized = try? await normalizer.normalizeWithMetadata(
        rawTranscript: routed.raw, vocabulary: keyTermsProvider())
      if Task.isCancelled { return }
    }
    record.normalizedTranscript = normalized?.text.trimmedNonEmpty()
    if record.normalizedTranscript != nil {
      record.normalizationProvider = "OpenRouter"
      record.normalizationModel = normalized?.model ?? pipeline.normalizationModel()
    }

    let selected =
      routed.mode == .short
      ? NormalizationFallback.short(
        normalized: record.normalizedTranscript,
        assemblyClean: record.assemblyCleanTranscript, raw: record.rawTranscript)
      : NormalizationFallback.long(
        normalized: record.normalizedTranscript, raw: record.rawTranscript)
    let expanded = TextShortcutExpander.expand(selected, using: textShortcutsProvider())
    guard let spoken = selected.trimmedNonEmpty(), let text = expanded.trimmedNonEmpty() else {
      record.status = .ready
      record.finishedAt = Date()
      currentRecord = record
      pipeline.onRecordChanged(record)
      setPhase(.idle)
      return
    }

    record.status = .ready
    record.finishedAt = Date()
    currentRecord = record
    pipeline.onRecordChanged(record)
    deliverVibeTranscript(text: text, spoken: spoken)

    // A completed job may outlive the key sequence that started it. Generation
    // and the current app determine whether auto-insertion is still safe.
    // A stale or displaced result remains in history without typing elsewhere.
    let currentTarget = await seams.captureFrontmost()
    guard
      AutoInsertionEligibility().canInsert(
        job: job, newestGeneration: latestGeneration,
        currentBundleIdentifier: currentTarget?.bundleIdentifier,
        currentWindowTitle: nil)
    else {
      setPhase(.idle)
      return
    }
    await injectVibe(text, job: job, record: &record)
  }

  private func deliverVibeTranscript(text: String, spoken: String) {
    seams.logTranscript(spoken, capturedContext)
    if capturedContext?.targetIsSecure != true {
      recentDictations.record(
        text, spoken: spoken, style: styleNameProvider(), at: Date())
    }
    onTranscriptDelivered?(text, recentDictations)
  }

  private func injectVibe(_ text: String, job: DictationJob, record: inout DictationRecord) async {
    setPhase(.injecting)
    do {
      try await injector.insert(
        recordID: job.id, text: text, after: capturedContext?.priorText,
        windowTitle: capturedContext?.windowTitle)
      if Task.isCancelled { return }
      record.insertionStatus = .inserted
      currentRecord = record
      activeVibePipeline?.onRecordChanged(record)
      setPhase(.pasted)
    } catch {
      if error is CancellationError || Task.isCancelled { return }
      if let blurt = error as? BlurtError, blurt.isQuietDegradation {
        record.insertionStatus = .targetLost
        setPhase(.noTarget)
      } else {
        record.insertionStatus = .failed
        record.errorMessage = error.localizedDescription
        if let blurt = error as? BlurtError {
          setPhase(.failed(blurt))
        } else {
          setPhase(.failed(.targetAppLost))
        }
      }
      currentRecord = record
      activeVibePipeline?.onRecordChanged(record)
    }
  }

  func failVibeRecord(_ error: any Error) async {
    guard var record = currentRecord else {
      setPhase(.failed(.sttFailed(underlying: error)))
      return
    }
    record.finishedAt = Date()
    record.status = .failed
    record.errorMessage = error.localizedDescription
    currentRecord = record
    activeVibePipeline?.onRecordChanged(record)
    if let blurt = error as? BlurtError {
      setPhase(.failed(blurt))
    } else {
      setPhase(.failed(.sttFailed(underlying: error)))
    }
  }

  func discardVibeRecording() async {
    guard let job = currentJob else { return }
    routingSession?.cancel()
    let writer = localAudioWriter
    activeVibePipeline?.onRecordDiscarded(job.id)
    routingSession = nil
    localAudioWriter = nil
    currentJob = nil
    currentRecord = nil
    await writer?.cancelAndDelete()
  }
}
