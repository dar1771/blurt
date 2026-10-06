import AppKit
import BlurtEngine
import Combine
import Foundation

/// Optional service independent of recording, transcription and injection.
@MainActor
final class ClipboardSyncModel: ObservableObject {
  @Published private(set) var enabled = false
  @Published private(set) var paused = false
  @Published private(set) var hasKey = false
  @Published private(set) var status = "Выключено"
  private var service: ClipboardSyncService?
  private var polling: Task<Void, Never>?
  private var lifecycle: Task<Void, Never>?
  private var generation = UUID()
  private var lastCount = 0
  private var lastFingerprint: Data?
  private var localChangedAt = Date.distantPast
  private var fileWrites: [UUID: Task<[URL], Error>] = [:]
  private var incomingCount: Int?
  private var sending = false
  private var testing = false

  func launch(testing: Bool) {
    self.testing = testing
    guard !testing else { return }
    do { hasKey = try ClipboardSyncStorage.readKey() != nil } catch { status = error.localizedDescription }
    if UserDefaults.standard.bool(forKey: ClipboardSyncStorage.enabledKey), hasKey { setEnabled(true) }
  }

  func setEnabled(_ value: Bool) {
    guard !testing else { return }
    enabled = value && hasKey
    paused = false
    UserDefaults.standard.set(enabled, forKey: ClipboardSyncStorage.enabledKey)
    restart()
  }

  func togglePause() {
    paused.toggle()
    restart()
  }

  func installCode(_ code: String) {
    guard !testing else { return }
    do {
      let data = try ClipboardSyncKey.decodeCode(code)
      try ClipboardSyncStorage.saveKey(data)
      hasKey = true
      status = "Код группы сохранён. Включите синхронизацию на обоих Mac."
      if enabled { restart() }
    } catch { status = error.localizedDescription }
  }

  func generateCode() -> String? {
    guard !testing else { return nil }
    do {
      let key = try ClipboardSyncKey.generate()
      try ClipboardSyncStorage.saveKey(key)
      hasKey = true
      if enabled { restart() }
      status = "Новая группа создана. Введите этот код на остальных Mac."
      return try ClipboardSyncKey.encodeCode(key)
    } catch {
      status = error.localizedDescription
      return nil
    }
  }

  func revealCode() -> String? {
    guard !testing else { return nil }
    do {
      guard let key = try ClipboardSyncStorage.readKey() else { return nil }
      return try ClipboardSyncKey.encodeCode(key)
    } catch {
      status = error.localizedDescription
      return nil
    }
  }

  func copyCode(_ code: String) {
    let item = NSPasteboardItem()
    item.setString(code, forType: .string)
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([item])
  }

  func sendNow() { Task { await sendCurrent(force: true) } }

  func clearReceivedFiles() async {
    guard !testing else { return }
    generation = UUID()
    polling?.cancel()
    lifecycle?.cancel()
    let previous = service
    service = nil
    if let previous { await previous.stop() }
    for task in fileWrites.values { _ = try? await task.value }
    do {
      try ClipboardSyncStorage.removeCache()
      status = "Полученные файлы удалены."
    } catch { status = error.localizedDescription }
    if enabled && !paused { restart() }
  }

  func reset() async -> Bool {
    enabled = false
    paused = false
    generation = UUID()
    polling?.cancel()
    lifecycle?.cancel()
    if let service { await service.stop() }
    service = nil
    guard !testing else { return true }
    for task in fileWrites.values { _ = try? await task.value }
    do {
      try ClipboardSyncStorage.saveKey(nil)
      try ClipboardSyncStorage.removeCache()
      hasKey = false
      status = "Выключено"
      return true
    } catch {
      status = error.localizedDescription
      return false
    }
  }

  private func restart() {
    generation = UUID()
    let token = generation
    polling?.cancel()
    lifecycle?.cancel()
    let previous = service
    service = nil
    lifecycle = Task {
      if let previous { await previous.stop() }
      guard generation == token, enabled, !paused else {
        updateStatus(paused ? "На паузе" : "Выключено", token: token)
        return
      }
      do {
        guard let key = try ClipboardSyncStorage.readKey() else { return }
        let stored = UserDefaults.standard.string(forKey: ClipboardSyncStorage.deviceKey)
        let deviceID = stored.flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(deviceID.uuidString, forKey: ClipboardSyncStorage.deviceKey)
        let transport = ClipboardSyncService(deviceID: deviceID, key: key)
        service = transport
        lastCount = NSPasteboard.general.changeCount
        // The existing clipboard is only an echo-suppression baseline. An
        // unsupported or oversized copy must never block starting the service.
        if let baseline = try? ClipboardSyncPasteboard.snapshot() {
          let files = try? await Task.detached { try ClipboardSyncFiles.read(baseline.files) }.value
          guard generation == token else {
            await transport.stop()
            return
          }
          lastFingerprint = ClipboardSyncPasteboard.contentFingerprint(baseline, files: files ?? [])
          lastCount = baseline.changeCount
        } else {
          lastFingerprint = nil
          lastCount = NSPasteboard.general.changeCount
        }
        localChangedAt = .distantPast
        try await transport.start(
          onReceiveStarted: { [weak self] in await self?.captureIncomingCount(token: token) },
          onReceive: { [weak self] payload in await self?.receive(payload, token: token) },
          onStatus: { [weak self] message in await self?.updateStatus(message, token: token) })
        guard generation == token else {
          await transport.stop()
          return
        }
        polling = Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            await self.sendCurrent(force: false)
          }
        }
      } catch { updateStatus(error.localizedDescription, token: token) }
    }
  }

  private func captureIncomingCount(token: UUID) {
    if generation == token { incomingCount = NSPasteboard.general.changeCount }
  }

  private func updateStatus(_ message: String, token: UUID) {
    if generation == token { status = message }
  }

  private func sendCurrent(force: Bool) async {
    guard enabled, !paused, !sending, let service else { return }
    let token = generation
    let count = NSPasteboard.general.changeCount
    guard force || count != lastCount else { return }
    if count != lastCount { localChangedAt = Date() }
    lastCount = count
    do {
      guard let snapshot = try ClipboardSyncPasteboard.snapshot() else { return }
      guard force || !snapshot.files.isEmpty || snapshot.fingerprint != lastFingerprint else { return }
      sending = true
      defer { sending = false }
      let files = try await Task.detached { try ClipboardSyncFiles.read(snapshot.files) }.value
      guard generation == token, NSPasteboard.general.changeCount == snapshot.changeCount else { return }
      let fingerprint = ClipboardSyncPasteboard.contentFingerprint(snapshot, files: files)
      guard force || fingerprint != lastFingerprint else { return }
      let stored = UserDefaults.standard.string(forKey: ClipboardSyncStorage.deviceKey)
      guard let origin = stored.flatMap(UUID.init(uuidString:)) else { return }
      let payload = ClipboardSyncPayload(
        id: UUID(), origin: origin, createdAt: Date(), items: snapshot.items, files: files)
      try await service.send(payload)
      guard generation == token else { return }
      lastFingerprint = fingerprint
    } catch { updateStatus(error.localizedDescription, token: token) }
  }

  private func receive(_ payload: ClipboardSyncPayload, token: UUID) async {
    guard generation == token, enabled, !paused else { return }
    let bytes =
      payload.items.reduce(0) { sum, item in
        sum + item.representations.values.reduce(0) { $0 + $1.count }
      } + payload.files.reduce(0) { $0 + $1.data.count }
    guard bytes <= ClipboardSyncFiles.maximumBytes else {
      status = ClipboardSyncFiles.FileError.limit.localizedDescription
      return
    }
    let count = NSPasteboard.general.changeCount
    if count != lastCount { localChangedAt = Date() }
    guard incomingCount == count, payload.createdAt > localChangedAt, !ClipboardSyncPasteboard.isTemporary else {
      status = "Полученный буфер пропущен: на этом Mac есть более свежая копия."
      return
    }
    do {
      let writeID = UUID()
      let write = Task.detached { try ClipboardSyncFiles.materialize(payload.files) }
      fileWrites[writeID] = write
      defer { fileWrites.removeValue(forKey: writeID) }
      let urls = try await write.value
      guard generation == token, enabled, !paused, NSPasteboard.general.changeCount == count else { return }
      if ClipboardSyncPasteboard.apply(payload, urls: urls, expectedChangeCount: count) {
        lastCount = NSPasteboard.general.changeCount
        lastFingerprint = nil
        status = "Буфер получен. Вставьте его через ⌘V."
      }
    } catch { updateStatus(error.localizedDescription, token: token) }
  }
}
