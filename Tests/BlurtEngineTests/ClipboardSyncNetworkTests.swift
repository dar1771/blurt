import Foundation
import Network
import Testing

@testable import BlurtEngine

private actor ClipboardSyncEvents {
  var payloads: [ClipboardSyncPayload] = []
  var statuses: [String] = []
  var starts = 0

  func receive(_ payload: ClipboardSyncPayload) { payloads.append(payload) }
  func status(_ status: String) { statuses.append(status) }
  func started() { starts += 1 }
}

@Suite("Clipboard sync real loopback TCP", .serialized)
struct ClipboardSyncNetworkTests {
  private let key = Data(repeating: 12, count: 32)

  // Sanitizers and concurrent suites need headroom; deadline-specific tests override this.
  private func service(
    deviceID: UUID = UUID(), key: Data? = nil, endpoints: [NWEndpoint] = [], deadline: TimeInterval = 10
  ) -> ClipboardSyncService {
    ClipboardSyncService(
      deviceID: deviceID, key: key ?? self.key,
      discovery: .direct(port: .any, endpoints: endpoints, deadline: deadline))
  }

  private func start(_ service: ClipboardSyncService, events: ClipboardSyncEvents) async throws {
    try await service.start(
      onReceiveStarted: { await events.started() },
      onReceive: { await events.receive($0) }, onStatus: { await events.status($0) })
  }

  private func endpoint(_ service: ClipboardSyncService) async throws -> NWEndpoint {
    for _ in 0..<100 {
      if let port = await service.listeningPort { return .hostPort(host: "127.0.0.1", port: port) }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw ClipboardSyncError.timedOut
  }

  private func waitForDelivery(_ events: ClipboardSyncEvents) async throws {
    for _ in 0..<100 {
      if await !events.payloads.isEmpty { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw ClipboardSyncError.timedOut
  }

  @Test func authenticatedTransferDuplicateAndWrongKey() async throws {
    let receiver = service()
    let received = ClipboardSyncEvents()
    try await start(receiver, events: received)
    let target = try await endpoint(receiver)
    let origin = UUID()
    let sender = service(deviceID: origin, endpoints: [target])
    let sent = ClipboardSyncEvents()
    try await start(sender, events: sent)
    let payload = ClipboardSyncPayload(
      origin: origin,
      items: [
        ClipboardSyncItem(representations: ["public.png": Data(repeating: 43, count: 180_000)])
      ])
    try await sender.send(payload)
    try await waitForDelivery(received)
    #expect(await received.payloads == [payload])
    #expect(await received.starts == 1)
    #expect(await sent.statuses.contains { $0.contains("отправлен") })
    try await Task.sleep(for: .milliseconds(250))
    await #expect(throws: ClipboardSyncError.connectionFailed) { try await sender.send(payload) }
    #expect(await received.payloads.count == 1)
    var wrongOrigin = payload
    wrongOrigin.origin = UUID()
    await #expect(throws: ClipboardSyncError.invalidPayload) { try await sender.send(wrongOrigin) }
    try await Task.sleep(for: .milliseconds(250))
    let strangerID = UUID()
    let stranger = service(deviceID: strangerID, key: Data(repeating: 99, count: 32), endpoints: [target])
    try await start(stranger, events: ClipboardSyncEvents())
    let foreign = ClipboardSyncPayload(
      origin: strangerID, files: [ClipboardSyncFile(name: "test.txt", data: Data([1]))])
    await #expect(throws: ClipboardSyncError.connectionFailed) { try await stranger.send(foreign) }
    #expect(await received.payloads.count == 1)
    for _ in 0..<100 {
      if await received.statuses.contains(where: { $0.contains("Не удалось принять") }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await received.statuses.contains { $0.contains("Не удалось принять") })
    await stranger.stop()
    await receiver.stop()
    await sender.stop()
    await #expect(throws: ClipboardSyncError.notRunning) { try await sender.send(payload) }
  }

  @Test func restartInsideStatusCallbackNeverDeliversToNewGeneration() async throws {
    let receiver = service()
    let original = ClipboardSyncEvents()
    let restarted = ClipboardSyncEvents()
    try await receiver.start(
      onReceive: { await original.receive($0) },
      onStatus: { status in
        if status == "Буфер получен с другого Mac." {
          do {
            try await receiver.start(
              onReceive: { await restarted.receive($0) }, onStatus: { await restarted.status($0) })
            await restarted.started()
          } catch {
            Issue.record(error)
          }
        }
      })
    let target = try await endpoint(receiver)
    let origin = UUID()
    let sender = service(deviceID: origin, endpoints: [target])
    try await start(sender, events: ClipboardSyncEvents())
    let payload = ClipboardSyncPayload(
      origin: origin,
      items: [
        ClipboardSyncItem(representations: ["public.utf8-plain-text": Data("before restart".utf8)])
      ])
    // Restart cancels the old TCP connection; its acknowledgement may not reach
    // the sender. Requiring the callback below still proves this payload arrived.
    do {
      try await sender.send(payload)
    } catch ClipboardSyncError.connectionFailed {}
    for _ in 0..<100 {
      if await restarted.starts == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await restarted.starts == 1)
    // A fresh transfer proves the restarted service is usable and drains the previous actor turn.
    let newTarget = try await endpoint(receiver)
    let newOrigin = UUID()
    let newSender = service(deviceID: newOrigin, endpoints: [newTarget])
    try await start(newSender, events: ClipboardSyncEvents())
    let current = ClipboardSyncPayload(
      origin: newOrigin,
      items: [
        ClipboardSyncItem(representations: ["public.utf8-plain-text": Data("after restart".utf8)])
      ])
    try await Task.sleep(for: .milliseconds(250))
    try await newSender.send(current)
    try await waitForDelivery(restarted)
    #expect(await original.payloads.isEmpty)
    #expect(await restarted.payloads == [current])
    await newSender.stop()
    await sender.stop()
    await receiver.stop()
  }

  @Test func disabledNoPeersAndInvalidKey() async throws {
    let origin = UUID()
    let sender = service(deviceID: origin)
    let payload = ClipboardSyncPayload(
      origin: origin,
      items: [
        ClipboardSyncItem(representations: ["public.utf8-plain-text": Data("text".utf8)])
      ])
    await #expect(throws: ClipboardSyncError.notRunning) { try await sender.send(payload) }
    try await start(sender, events: ClipboardSyncEvents())
    _ = try await endpoint(sender)
    await #expect(throws: ClipboardSyncError.noPeers) { try await sender.send(payload) }
    await sender.stop()
    await sender.stop()
    let invalid = service(key: Data())
    await #expect(throws: ClipboardSyncError.invalidKey) { try await start(invalid, events: ClipboardSyncEvents()) }
  }

  @Test func incompleteHeaderDeadlineAndCancellationReleaseReceiveSlot() async throws {
    let receiver = service(deadline: 0.35)
    let received = ClipboardSyncEvents()
    try await start(receiver, events: received)
    let target = try await endpoint(receiver)
    let queue = DispatchQueue(label: "vibeclip-test-incomplete")
    let stalled = NWConnection(to: target, using: .tcp)
    let transport = ClipboardSyncConnection(connection: stalled, queue: queue)
    try await transport.start(timeout: 2)
    _ = try await transport.receiveFrame(maximumBodySize: 128)
    try await transport.send(Data("BL".utf8))
    try await Task.sleep(for: .milliseconds(500))
    #expect(await received.payloads.isEmpty)
    #expect(await received.statuses.contains { $0.contains("Не удалось принять") })
    stalled.cancel()
    let origin = UUID()
    let sender = service(deviceID: origin, endpoints: [target])
    try await start(sender, events: ClipboardSyncEvents())
    let payload = ClipboardSyncPayload(origin: origin, files: [ClipboardSyncFile(name: "empty.txt", data: Data())])
    try await sender.send(payload)
    try await waitForDelivery(received)
    #expect(await received.payloads == [payload])
    await sender.stop()
    await receiver.stop()
  }

  @Test func ownOriginDoesNotEchoAndMalformedLengthFails() async throws {
    let origin = UUID()
    let receiver = service(deviceID: origin)
    let received = ClipboardSyncEvents()
    try await start(receiver, events: received)
    let target = try await endpoint(receiver)
    let sender = service(deviceID: origin, endpoints: [target])
    try await start(sender, events: ClipboardSyncEvents())
    let payload = ClipboardSyncPayload(
      origin: origin,
      items: [
        ClipboardSyncItem(representations: ["public.rtf": Data("{\\rtf1 test}".utf8)])
      ])
    await #expect(throws: ClipboardSyncError.connectionFailed) { try await sender.send(payload) }
    #expect(await received.payloads.isEmpty)
    try await Task.sleep(for: .milliseconds(250))
    let hostile = NWConnection(to: target, using: .tcp)
    let transport = ClipboardSyncConnection(connection: hostile, queue: DispatchQueue(label: "vibeclip-hostile"))
    try await transport.start(timeout: 2)
    _ = try await transport.receiveFrame(maximumBodySize: 128)
    try await transport.send(ClipboardSyncCodec.magic + Data([255, 255, 255, 255]))
    await #expect(throws: ClipboardSyncError.invalidFrame) { try await transport.receiveFrame() }
    #expect(await received.payloads.isEmpty)
    hostile.cancel()
    await sender.stop()
    await receiver.stop()
  }
}
