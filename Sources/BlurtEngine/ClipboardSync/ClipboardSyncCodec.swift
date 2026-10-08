import CryptoKit
import Foundation
import Security

public enum ClipboardSyncKey {
  public static func generate() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ClipboardSyncError.invalidKey
    }
    return Data(bytes)
  }

  public static func decodeCode(_ code: String) throws -> Data {
    guard let key = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else {
      throw ClipboardSyncError.invalidKey
    }
    return key
  }

  public static func encodeCode(_ key: Data) throws -> String {
    guard key.count == 32 else { throw ClipboardSyncError.invalidKey }
    return key.base64EncodedString()
  }
}

/// A length-prefixed, versioned frame. The header is also authenticated by AES-GCM.
struct ClipboardSyncCodec: Sendable {
  static let magic = Data("BLURTCS1".utf8)
  static let headerBytes = 12
  private let key: SymmetricKey

  init(key: Data) throws {
    guard key.count == 32 else { throw ClipboardSyncError.invalidKey }
    self.key = SymmetricKey(data: key)
  }

  func plaintext(_ payload: ClipboardSyncPayload, now: Date = Date()) throws -> Data {
    try payload.validate(now: now)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let plaintext = try encoder.encode(payload)
    guard plaintext.count + 28 <= ClipboardSyncLimits.maximumEnvelopeBytes else {
      throw ClipboardSyncError.tooLarge
    }
    return plaintext
  }

  func sealPayload(_ plaintext: Data, challenge: UUID) throws -> Data {
    try seal(plaintext, challenge: challenge)
  }

  func encodeChallenge(_ identifier: UUID) throws -> Data {
    try seal(Data(("CHALLENGE1:" + identifier.uuidString).utf8))
  }

  func decodeChallenge(_ frame: Data) throws -> UUID {
    let plaintext = try open(frame)
    guard let text = String(data: plaintext, encoding: .utf8), text.hasPrefix("CHALLENGE1:"),
      let identifier = UUID(uuidString: String(text.dropFirst(11)))
    else { throw ClipboardSyncError.authenticationFailed }
    return identifier
  }

  func encodeAcknowledgement(_ identifier: UUID, challenge: UUID? = nil) throws -> Data {
    try seal(Data(("ACK1:" + identifier.uuidString).utf8), challenge: challenge)
  }

  func verifyAcknowledgement(_ frame: Data, identifier: UUID, challenge: UUID? = nil) throws {
    guard try open(frame, challenge: challenge) == Data(("ACK1:" + identifier.uuidString).utf8) else {
      throw ClipboardSyncError.authenticationFailed
    }
  }

  private func seal(_ plaintext: Data, challenge: UUID? = nil) throws -> Data {
    let bodySize = plaintext.count + 28
    guard bodySize <= ClipboardSyncLimits.maximumEnvelopeBytes else { throw ClipboardSyncError.tooLarge }
    let header = Self.header(bodySize: bodySize)
    let sealed = try AES.GCM.seal(
      plaintext, using: key, authenticating: Self.authenticatedData(header, challenge: challenge))
    guard let body = sealed.combined else { throw ClipboardSyncError.authenticationFailed }
    return header + body
  }

  func decode(_ frame: Data, now: Date = Date(), challenge: UUID? = nil) throws -> ClipboardSyncPayload {
    let plaintext = try open(frame, challenge: challenge)
    let payload = try PropertyListDecoder().decode(ClipboardSyncPayload.self, from: plaintext)
    try payload.validate(now: now)
    return payload
  }

  private func open(_ frame: Data, challenge: UUID? = nil) throws -> Data {
    guard frame.count >= Self.headerBytes else { throw ClipboardSyncError.invalidFrame }
    let header = Data(frame.prefix(Self.headerBytes))
    let bodySize = try Self.bodySize(header: header)
    guard frame.count == Self.headerBytes + bodySize else { throw ClipboardSyncError.invalidFrame }
    let plaintext: Data
    do {
      let box = try AES.GCM.SealedBox(combined: frame.dropFirst(Self.headerBytes))
      plaintext = try AES.GCM.open(
        box, using: key, authenticating: Self.authenticatedData(header, challenge: challenge))
    } catch { throw ClipboardSyncError.authenticationFailed }
    return plaintext
  }

  private static func authenticatedData(_ header: Data, challenge: UUID?) -> Data {
    guard let challenge else { return header }
    return header + Data(challenge.uuidString.utf8)
  }

  static func bodySize(header: Data) throws -> Int {
    guard header.count == headerBytes, header.prefix(8) == magic else {
      throw ClipboardSyncError.invalidFrame
    }
    let value = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard value >= 28, value <= ClipboardSyncLimits.maximumEnvelopeBytes else {
      throw ClipboardSyncError.tooLarge
    }
    return Int(value)
  }

  private static func header(bodySize: Int) -> Data {
    let size = UInt32(bodySize)
    return magic + Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
  }
}

/// Unexpired replay IDs are never evicted to admit new ones: saturation fails closed.
struct ClipboardSyncReplayGuard: Sendable {
  private var received: [UUID: Date] = [:]
  private var latest: Date = .distantPast
  private let capacity: Int

  init(capacity: Int = 2048) {
    self.capacity = capacity
  }

  mutating func accept(_ payload: ClipboardSyncPayload, deviceID: UUID, now: Date = Date()) -> Bool {
    guard payload.origin != deviceID, (try? payload.validate(now: now)) != nil else { return false }
    received = received.filter { now.timeIntervalSince($0.value) <= ClipboardSyncLimits.maximumAge + 30 }
    guard received[payload.id] == nil, received.count < capacity, payload.createdAt >= latest else { return false }
    received[payload.id] = now
    latest = payload.createdAt
    return true
  }
}
