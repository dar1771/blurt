import Foundation
import Testing

@testable import BlurtEngine

@Suite("Clipboard sync validation and authenticated frames")
struct ClipboardSyncTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let key = Data(repeating: 7, count: 32)
  private let challenge = UUID()

  private func encodedFrame(
    _ payload: ClipboardSyncPayload, codec: ClipboardSyncCodec, challenge: UUID? = nil
  ) throws -> Data {
    try codec.sealPayload(codec.plaintext(payload, now: now), challenge: challenge ?? self.challenge)
  }

  private func payload(date: Date? = nil) -> ClipboardSyncPayload {
    ClipboardSyncPayload(
      origin: UUID(), createdAt: date ?? now,
      items: [ClipboardSyncItem(representations: ["public.utf8-plain-text": Data("Привет, Mac!".utf8)])])
  }

  @Test func secureRandomCodesRoundTrip() throws {
    let first = try ClipboardSyncKey.generate()
    let second = try ClipboardSyncKey.generate()
    #expect(first.count == 32)
    #expect(first != second)
    let code = try ClipboardSyncKey.encodeCode(first)
    #expect(try ClipboardSyncKey.decodeCode("  \(code)\n") == first)
  }

  @Test(arguments: ["", "not a key", Data(repeating: 1, count: 31).base64EncodedString()])
  func invalidCodeRejected(_ code: String) {
    #expect(throws: ClipboardSyncError.invalidKey) { try ClipboardSyncKey.decodeCode(code) }
  }

  @Test func shortKeyRejected() {
    #expect(throws: ClipboardSyncError.invalidKey) { try ClipboardSyncKey.encodeCode(Data()) }
    #expect(throws: ClipboardSyncError.invalidKey) { try ClipboardSyncCodec(key: Data()) }
  }

  @Test func supportedRepresentationsRoundTrip() throws {
    let source = ClipboardSyncPayload(
      origin: UUID(), createdAt: now,
      items: ClipboardSyncLimits.allowedTypes.sorted().map {
        ClipboardSyncItem(representations: [
          $0: $0 == "public.utf8-plain-text" ? Data("Привет".utf8) : Data([0, 1, 255])
        ])
      })
    let codec = try ClipboardSyncCodec(key: key)
    let frame = try encodedFrame(source, codec: codec)
    #expect(try codec.decode(frame, now: now, challenge: challenge) == source)
    #expect(!frame.contains(Data("Привет".utf8)))
    #expect(try encodedFrame(source, codec: codec) != frame)
  }

  @Test func realFilesRoundTrip() throws {
    let source = ClipboardSyncPayload(
      origin: UUID(), createdAt: now,
      files: [
        ClipboardSyncFile(name: "Документ.txt", data: Data("текст".utf8)),
        ClipboardSyncFile(name: "empty.bin", data: Data()),
      ])
    let codec = try ClipboardSyncCodec(key: key)
    #expect(try codec.decode(encodedFrame(source, codec: codec), now: now, challenge: challenge) == source)
  }

  @Test(arguments: ["", ".", "..", "../file", "/file", "folder/file", "a\\b", "a:b", ".hidden", "a\n.txt"])
  func unsafeFileNamesRejected(_ name: String) {
    #expect(!ClipboardSyncPayload.isSafeFileName(name))
    let source = ClipboardSyncPayload(
      origin: UUID(), createdAt: now, files: [ClipboardSyncFile(name: name, data: Data())])
    #expect(throws: ClipboardSyncError.unsafeFileName) { try source.validate(now: now) }
  }

  @Test func nulFileNameRejected() {
    let name = "a" + String(UnicodeScalar(0)) + "b"
    #expect(!ClipboardSyncPayload.isSafeFileName(name))
  }

  @Test func duplicateAndOverlongFileNamesRejected() {
    #expect(!ClipboardSyncPayload.isSafeFileName(String(repeating: "ы", count: 121)))
    let source = ClipboardSyncPayload(
      origin: UUID(), createdAt: now,
      files: [
        ClipboardSyncFile(name: "FILE.txt", data: Data()), ClipboardSyncFile(name: "file.txt", data: Data()),
      ])
    #expect(throws: ClipboardSyncError.unsafeFileName) { try source.validate(now: now) }
  }

  @Test func emptyMixedAndPrivateFormatsRejected() {
    let empty = ClipboardSyncPayload(origin: UUID(), createdAt: now)
    #expect(throws: ClipboardSyncError.invalidPayload) { try empty.validate(now: now) }
    var source = payload()
    source.files = [ClipboardSyncFile(name: "file.txt", data: Data())]
    #expect(throws: ClipboardSyncError.invalidPayload) { try source.validate(now: now) }
    source.files = []
    source.items = [ClipboardSyncItem(representations: [:])]
    #expect(throws: ClipboardSyncError.invalidPayload) { try source.validate(now: now) }
    source.items = [ClipboardSyncItem(representations: ["public.file-url": Data("file:///private/data".utf8)])]
    #expect(throws: ClipboardSyncError.invalidPayload) { try source.validate(now: now) }
  }

  @Test func tooManyObjectsRejected() {
    let item = ClipboardSyncItem(representations: ["public.png": Data([1])])
    let source = ClipboardSyncPayload(origin: UUID(), createdAt: now, items: Array(repeating: item, count: 33))
    #expect(throws: ClipboardSyncError.invalidPayload) { try source.validate(now: now) }
    let files = ClipboardSyncPayload(
      origin: UUID(), createdAt: now,
      files: (0..<33).map {
        ClipboardSyncFile(name: "file\($0)", data: Data())
      })
    #expect(throws: ClipboardSyncError.invalidPayload) { try files.validate(now: now) }
  }

  @Test(arguments: [-121.0, 31.0, .infinity, -.infinity])
  func invalidDatesRejected(_ offset: Double) {
    #expect(throws: ClipboardSyncError.invalidPayload) {
      try payload(date: now.addingTimeInterval(offset)).validate(now: now)
    }
  }

  @Test func aggregateAndEncodedSizeLimits() throws {
    let data = Data(repeating: 0, count: ClipboardSyncLimits.maximumEnvelopeBytes)
    let source = ClipboardSyncPayload(
      origin: UUID(), createdAt: now, files: [ClipboardSyncFile(name: "large", data: data)])
    try source.validate(now: now)
    #expect(throws: ClipboardSyncError.tooLarge) { try ClipboardSyncCodec(key: key).plaintext(source, now: now) }
    var overflow = source
    overflow.files.append(ClipboardSyncFile(name: "extra", data: Data([0])))
    #expect(throws: ClipboardSyncError.tooLarge) { try overflow.validate(now: now) }
    let images = ClipboardSyncPayload(
      origin: UUID(), createdAt: now,
      items: [
        ClipboardSyncItem(representations: ["public.png": data, "public.tiff": Data([0])])
      ])
    #expect(throws: ClipboardSyncError.tooLarge) { try images.validate(now: now) }
  }

  @Test func tamperingWrongKeyAndTruncationFailClosed() throws {
    let codec = try ClipboardSyncCodec(key: key)
    let frame = try encodedFrame(payload(), codec: codec)
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try ClipboardSyncCodec(key: Data(repeating: 8, count: 32)).decode(frame, now: now, challenge: challenge)
    }
    var altered = frame
    altered[20] ^= 1
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try codec.decode(altered, now: now, challenge: challenge)
    }
    #expect(throws: ClipboardSyncError.invalidFrame) {
      try codec.decode(frame.dropLast(), now: now, challenge: challenge)
    }
    #expect(throws: ClipboardSyncError.invalidFrame) { try codec.decode(Data(), now: now, challenge: challenge) }
    #expect(throws: ClipboardSyncError.invalidFrame) {
      try codec.decode(frame + Data([0]), now: now, challenge: challenge)
    }
    var version = frame
    version[7] = 50
    #expect(throws: ClipboardSyncError.invalidFrame) { try codec.decode(version, now: now, challenge: challenge) }
  }

  @Test func hostileLengthHeadersRejectedBeforeBodyAllocation() {
    #expect(throws: ClipboardSyncError.tooLarge) {
      try ClipboardSyncCodec.bodySize(header: ClipboardSyncCodec.magic + Data([255, 255, 255, 255]))
    }
    #expect(throws: ClipboardSyncError.tooLarge) {
      try ClipboardSyncCodec.bodySize(header: ClipboardSyncCodec.magic + Data([0, 0, 0, 1]))
    }
    #expect(throws: ClipboardSyncError.invalidFrame) { try ClipboardSyncCodec.bodySize(header: Data([0])) }
  }

  @Test func recipientChallengeCannotBeReplayedAcrossConnections() throws {
    let codec = try ClipboardSyncCodec(key: key)
    let first = UUID()
    let second = UUID()
    let challenge = try codec.encodeChallenge(first)
    #expect(try codec.decodeChallenge(challenge) == first)
    let proof = try codec.encodeAcknowledgement(first)
    try codec.verifyAcknowledgement(proof, identifier: first)
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try codec.verifyAcknowledgement(proof, identifier: second)
    }
    #expect(throws: ClipboardSyncError.authenticationFailed) { try codec.decodeChallenge(proof) }
    let source = payload()
    let captured = try encodedFrame(source, codec: codec, challenge: first)
    #expect(try codec.decode(captured, now: now, challenge: first) == source)
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try codec.decode(captured, now: now, challenge: second)
    }
    let ack = try codec.encodeAcknowledgement(first, challenge: first)
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try codec.verifyAcknowledgement(ack, identifier: first, challenge: second)
    }
  }

  @Test func acknowledgementAuthenticatesPeerAndPayload() throws {
    let codec = try ClipboardSyncCodec(key: key)
    let identifier = UUID()
    let acknowledgement = try codec.encodeAcknowledgement(identifier)
    try codec.verifyAcknowledgement(acknowledgement, identifier: identifier)
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try codec.verifyAcknowledgement(acknowledgement, identifier: UUID())
    }
    #expect(throws: ClipboardSyncError.authenticationFailed) {
      try ClipboardSyncCodec(key: Data(repeating: 9, count: 32)).verifyAcknowledgement(
        acknowledgement, identifier: identifier)
    }
  }

  @Test func replayOriginOrderingCapacityAndExpiry() {
    var guardrail = ClipboardSyncReplayGuard(capacity: 2)
    let first = payload()
    let local = UUID()
    let accepted = guardrail.accept(first, deviceID: local, now: now)
    #expect(accepted)
    let replay = guardrail.accept(first, deviceID: local, now: now)
    #expect(!replay)
    let own = guardrail.accept(payload(), deviceID: first.origin, now: now)
    // A payload with its own origin must never be relayed back to the shell.
    var sameOrigin = first
    sameOrigin.id = UUID()
    let rejectedOrigin = guardrail.accept(sameOrigin, deviceID: first.origin, now: now)
    #expect(!rejectedOrigin)
    #expect(own)
    let saturated = guardrail.accept(payload(date: now.addingTimeInterval(1)), deviceID: local, now: now)
    #expect(!saturated)
    let later = now.addingTimeInterval(151)
    let expired = guardrail.accept(payload(date: later), deviceID: local, now: later)
    #expect(expired)
    let stale = guardrail.accept(payload(date: later.addingTimeInterval(-1)), deviceID: local, now: later)
    #expect(!stale)
    let invalid = guardrail.accept(ClipboardSyncPayload(origin: UUID(), createdAt: later), deviceID: local, now: later)
    #expect(!invalid)
  }
}
