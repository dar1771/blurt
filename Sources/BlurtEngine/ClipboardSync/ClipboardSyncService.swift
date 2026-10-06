import CryptoKit
import Foundation
import Network

/// Optional LAN-only clipboard exchange. Receiving content never pastes or applies it automatically here.
public actor ClipboardSyncService {
  public static let serviceType = "_vibeclip._tcp"
  private let deviceID: UUID
  private let key: Data
  private let discovery: ClipboardSyncDiscovery
  private let queue = DispatchQueue(label: "dev.vibedictate.clipboard-sync", qos: .utility)
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var peers: Set<NWEndpoint> = []
  private var connections: [UUID: NWConnection] = [:]
  private var localEpoch = 0
  private var receiveStartedCallback: (@Sendable () async -> Void)?
  private var receiveCallback: (@Sendable (ClipboardSyncPayload) async -> Void)?
  private var statusCallback: (@Sendable (String) async -> Void)?
  private var replay = ClipboardSyncReplayGuard()
  private var generation = UUID()
  private var sending = false
  private var lastAdmission = Date.distantPast
  private var inboundCount = 0

  public init(deviceID: UUID, key: Data) {
    self.deviceID = deviceID
    self.key = key
    self.discovery = .bonjour
  }

  // The app's Periphery scheme excludes package tests; this seam runs genuine TCP fixtures without LAN discovery.
  // periphery:ignore
  init(deviceID: UUID, key: Data, discovery: ClipboardSyncDiscovery) {
    self.deviceID = deviceID
    self.key = key
    self.discovery = discovery
  }

  public func start(
    onReceiveStarted: @escaping @Sendable () async -> Void = {},
    onReceive: @escaping @Sendable (ClipboardSyncPayload) async -> Void,
    onStatus: @escaping @Sendable (String) async -> Void
  ) async throws {
    await stop()
    _ = try ClipboardSyncCodec(key: key)
    let run = UUID()
    generation = run
    receiveStartedCallback = onReceiveStarted
    receiveCallback = onReceive
    statusCallback = onStatus
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = false
    let listener = try NWListener(using: parameters, on: discovery.port)
    let name = serviceName
    if discovery.advertises { listener.service = NWListener.Service(name: name, type: Self.serviceType) }
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection, run: run) }
    }
    listener.stateUpdateHandler = { [weak self] state in
      Task { await self?.listenerState(state, run: run) }
    }
    self.listener = listener
    listener.start(queue: queue)
    peers = Set(discovery.endpoints)
    guard discovery.advertises else { return }
    let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: parameters)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let endpoints = Set(results.map(\.endpoint))
      Task { await self?.updatePeers(endpoints, ownName: name, run: run) }
    }
    browser.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed:
        Task { await self?.report("Не удалось найти Mac в локальной сети. Проверьте разрешение macOS.", run: run) }
      case .waiting:
        Task { await self?.report("Ожидание доступа к локальной сети. Проверьте разрешение macOS.", run: run) }
      default: break
      }
    }
    self.browser = browser
    browser.start(queue: queue)
    await onStatus("Поиск Mac в локальной сети…")
  }

  // Isolated loopback fixtures need the actual ephemeral port after readiness; never exposed in the app UI.
  // periphery:ignore
  var listeningPort: NWEndpoint.Port? {
    guard let port = listener?.port, port.rawValue != 0 else { return nil }
    return port
  }

  public func stop() async {
    generation = UUID()
    listener?.cancel()
    browser?.cancel()
    listener = nil
    browser = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    peers.removeAll()
    receiveStartedCallback = nil
    receiveCallback = nil
    statusCallback = nil
    inboundCount = 0
    sending = false
    replay = ClipboardSyncReplayGuard()
  }

  public func send(_ payload: ClipboardSyncPayload) async throws {
    localEpoch += 1
    let plaintext = try outgoingData(payload)
    let run = generation
    sending = true
    let endpoints = Array(peers.prefix(8))
    let successful = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      var iterator = endpoints.makeIterator()
      for _ in 0..<4 {
        if let endpoint = iterator.next() {
          group.addTask { await self.transmit(plaintext, identifier: payload.id, endpoint: endpoint, run: run) }
        }
      }
      var count = 0
      for await success in group {
        if success { count += 1 }
        if let endpoint = iterator.next() {
          group.addTask { await self.transmit(plaintext, identifier: payload.id, endpoint: endpoint, run: run) }
        }
      }
      return count
    }
    guard run == generation else { throw ClipboardSyncError.notRunning }
    sending = false
    guard successful > 0 else { throw ClipboardSyncError.connectionFailed }
    await report("Буфер отправлен на Mac: \(successful).", run: run)
  }

  private func outgoingData(_ payload: ClipboardSyncPayload) throws -> Data {
    guard listener != nil else { throw ClipboardSyncError.notRunning }
    guard payload.origin == deviceID else { throw ClipboardSyncError.invalidPayload }
    guard !peers.isEmpty else { throw ClipboardSyncError.noPeers }
    guard !sending else { throw ClipboardSyncError.connectionFailed }
    return try ClipboardSyncCodec(key: key).plaintext(payload)
  }

  private func transmit(_ plaintext: Data, identifier: UUID, endpoint: NWEndpoint, run: UUID) async -> Bool {
    guard run == generation else { return false }
    let connection = NWConnection(to: endpoint, using: .tcp)
    let token = register(connection)
    defer { finish(token, run: run) }
    let transport = ClipboardSyncConnection(
      connection: connection, queue: queue, operationTimeout: discovery.deadline, deadline: .now() + discovery.deadline)
    do {
      try await transport.start(timeout: discovery.deadline)
      let codec = try ClipboardSyncCodec(key: key)
      let challenge = try codec.decodeChallenge(await transport.receiveFrame(maximumBodySize: 128))
      try await transport.send(codec.encodeAcknowledgement(challenge))
      try await transport.send(codec.sealPayload(plaintext, challenge: challenge))
      let acknowledgement = try await transport.receiveFrame(maximumBodySize: 128)
      try ClipboardSyncCodec(key: key).verifyAcknowledgement(
        acknowledgement, identifier: identifier, challenge: challenge)
      return run == generation
    } catch {
      return false
    }
  }

  private var serviceName: String {
    let fingerprint = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    // Keep machine names and the pairing code out of public Bonjour records.
    return "\(fingerprint)-\(deviceID.uuidString)"
  }

  private func updatePeers(_ endpoints: Set<NWEndpoint>, ownName: String, run: UUID) async {
    guard run == generation else { return }
    let group = String(ownName.prefix(16))
    peers = Set(
      endpoints.filter { endpoint in
        guard case .service(let name, _, let domain, _) = endpoint else { return false }
        return name != ownName && name.hasPrefix(group + "-") && domain == "local."
      }.prefix(8))
    await report(peers.isEmpty ? "Поиск Mac в локальной сети…" : "Найдено Mac в группе: \(peers.count).", run: run)
  }

  private func listenerState(_ state: NWListener.State, run: UUID) async {
    guard run == generation else { return }
    if case .failed = state {
      await report("Синхронизация недоступна. Проверьте доступ к локальной сети в настройках macOS.", run: run)
      guard run == generation else { return }
      await stop()
    }
  }

  private func accept(_ connection: NWConnection, run: UUID) async {
    guard run == generation, inboundCount < 1, Date().timeIntervalSince(lastAdmission) >= 0.2 else {
      connection.cancel()
      return
    }
    lastAdmission = Date()
    inboundCount += 1
    let identifier = register(connection)
    defer { finishInbound(identifier, run: run) }
    let epoch = localEpoch
    let transport = ClipboardSyncConnection(
      connection: connection, queue: queue, operationTimeout: discovery.deadline, deadline: .now() + discovery.deadline)
    do {
      try await transport.start(timeout: discovery.deadline)
      let codec = try ClipboardSyncCodec(key: key)
      let challenge = UUID()
      try await transport.send(codec.encodeChallenge(challenge))
      let proof = try await transport.receiveFrame(maximumBodySize: 128)
      try codec.verifyAcknowledgement(proof, identifier: challenge)
      guard run == generation else { return }
      await receiveStartedCallback?()
      let frame = try await transport.receiveFrame()
      let payload = try codec.decode(frame, challenge: challenge)
      guard run == generation, epoch == localEpoch, replay.accept(payload, deviceID: deviceID) else {
        return
      }
      let acknowledgement = try ClipboardSyncCodec(key: key).encodeAcknowledgement(payload.id, challenge: challenge)
      try await transport.send(acknowledgement)
      guard run == generation else { return }
      await report("Буфер получен с другого Mac.", run: run)
      guard run == generation else { return }
      await receiveCallback?(payload)
    } catch {
      await report("Не удалось принять буфер: неверный код, повреждённые данные или разрыв связи.", run: run)
    }
  }

  private func register(_ connection: NWConnection) -> UUID {
    let identifier = UUID()
    connections[identifier] = connection
    queue.asyncAfter(deadline: .now() + discovery.deadline) { [weak connection] in connection?.cancel() }
    return identifier
  }

  private func finish(_ identifier: UUID, run: UUID) {
    guard run == generation else { return }
    connections.removeValue(forKey: identifier)?.cancel()
  }

  private func finishInbound(_ identifier: UUID, run: UUID) {
    guard run == generation else { return }
    finish(identifier, run: run)
    inboundCount -= 1
  }

  private func report(_ status: String, run: UUID) async {
    guard run == generation else { return }
    await statusCallback?(status)
  }
}

/// Direct loopback fixtures exercise the real framing and TCP path without broadcasting test clipboards on Bonjour.
enum ClipboardSyncDiscovery: Sendable {
  case bonjour
  case direct(port: NWEndpoint.Port, endpoints: [NWEndpoint], deadline: TimeInterval)

  var port: NWEndpoint.Port {
    if case .direct(let port, _, _) = self { return port }
    return .any
  }

  var endpoints: [NWEndpoint] {
    if case .direct(_, let endpoints, _) = self { return endpoints }
    return []
  }

  var deadline: TimeInterval {
    if case .direct(_, _, let deadline) = self { return deadline }
    return 20
  }

  var advertises: Bool {
    if case .bonjour = self { return true }
    return false
  }
}
