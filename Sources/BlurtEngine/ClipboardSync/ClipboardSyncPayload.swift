import Foundation

/// Only self-contained pasteboard formats are exchanged. URLs, promises, and private app formats stay local.
public struct ClipboardSyncItem: Codable, Sendable, Equatable {
  public var representations: [String: Data]

  public init(representations: [String: Data]) {
    self.representations = representations
  }
}

public struct ClipboardSyncFile: Codable, Sendable, Equatable {
  public var name: String
  public var data: Data

  public init(name: String, data: Data) {
    self.name = name
    self.data = data
  }
}

public enum ClipboardSyncLimits {
  public static let maximumEnvelopeBytes = 64 * 1024 * 1024
  public static let maximumItems = 32
  public static let maximumFiles = 32
  public static let maximumAge: TimeInterval = 120
  public static let allowedTypes: Set<String> = [
    "public.utf8-plain-text", "public.utf16-external-plain-text", "public.rtf", "public.html",
    "public.png", "public.tiff", "public.jpeg", "com.adobe.pdf",
  ]
}

enum ClipboardSyncError: Error, Sendable, Equatable, LocalizedError {
  case invalidKey
  case invalidPayload
  case unsafeFileName
  case tooLarge
  case invalidFrame
  case authenticationFailed
  case notRunning
  case noPeers
  case connectionFailed
  case timedOut

  var errorDescription: String? {
    switch self {
    case .invalidKey: "Неверный код группы. Скопируйте код целиком с другого Mac."
    case .invalidPayload: "Содержимое буфера не поддерживается или устарело."
    case .unsafeFileName: "Небезопасное имя передаваемого файла."
    case .tooLarge: "Буфер превышает лимит передачи 64 МБ."
    case .invalidFrame: "Неподдерживаемый формат передачи буфера."
    case .authenticationFailed: "Не удалось подтвердить код соединения другого Mac."
    case .notRunning: "Синхронизация буфера выключена."
    case .noPeers: "В локальной сети пока нет других Mac."
    case .connectionFailed: "Соединение с другим Mac прервано."
    case .timedOut: "Истекло время передачи буфера."
    }
  }
}

public struct ClipboardSyncPayload: Codable, Sendable, Equatable {
  public var id: UUID
  public var origin: UUID
  public var createdAt: Date
  public var items: [ClipboardSyncItem]
  public var files: [ClipboardSyncFile]

  public init(
    id: UUID = UUID(), origin: UUID, createdAt: Date = Date(),
    items: [ClipboardSyncItem] = [], files: [ClipboardSyncFile] = []
  ) {
    self.id = id
    self.origin = origin
    self.createdAt = createdAt
    self.items = items
    self.files = files
  }

  public func validate(now: Date = Date()) throws {
    let age = now.timeIntervalSince(createdAt)
    guard age.isFinite, age >= -30, age <= ClipboardSyncLimits.maximumAge,
      items.count <= ClipboardSyncLimits.maximumItems, files.count <= ClipboardSyncLimits.maximumFiles,
      !items.isEmpty || !files.isEmpty, items.isEmpty || files.isEmpty
    else { throw ClipboardSyncError.invalidPayload }
    var bytes = 0
    for item in items {
      guard !item.representations.isEmpty,
        item.representations.keys.allSatisfy(ClipboardSyncLimits.allowedTypes.contains)
      else { throw ClipboardSyncError.invalidPayload }
      for data in item.representations.values {
        guard data.count <= ClipboardSyncLimits.maximumEnvelopeBytes - bytes else {
          throw ClipboardSyncError.tooLarge
        }
        bytes += data.count
      }
    }
    var names: Set<String> = []
    for file in files {
      guard Self.isSafeFileName(file.name), names.insert(file.name.lowercased()).inserted else {
        throw ClipboardSyncError.unsafeFileName
      }
      guard file.data.count <= ClipboardSyncLimits.maximumEnvelopeBytes - bytes else {
        throw ClipboardSyncError.tooLarge
      }
      bytes += file.data.count
    }
  }

  public static func isSafeFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
      && name.utf8.count <= 240
      && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
      && !name.contains("/") && !name.contains("\\") && !name.contains(":")
  }
}
