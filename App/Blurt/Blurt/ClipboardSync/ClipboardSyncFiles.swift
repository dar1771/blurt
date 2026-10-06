import BlurtEngine
import Darwin
import Foundation

/// File IO is detached from AppKit. O_NOFOLLOW plus fstat rejects symlinks,
/// directories and special files even if the source changes after copying.
enum ClipboardSyncFiles {
  nonisolated static let maximumBytes = 20 * 1024 * 1024
  nonisolated static let maximumFiles = 16

  nonisolated static func read(_ urls: [URL]) throws -> [ClipboardSyncFile] {
    guard urls.count <= maximumFiles else { throw FileError.limit }
    var total = 0
    return try urls.map { url in
      let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw FileError.unsupported }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        throw FileError.unsupported
      }
      guard info.st_size >= 0, info.st_size <= maximumBytes - total else { throw FileError.limit }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      var data = Data()
      while let chunk = try handle.read(upToCount: min(256 * 1024, maximumBytes - total - data.count + 1)),
        !chunk.isEmpty
      {
        data.append(chunk)
        guard total + data.count <= maximumBytes else { throw FileError.limit }
      }
      var after = stat()
      guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
        after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
        after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
        data.count == info.st_size
      else { throw FileError.unsupported }
      total += data.count
      guard total <= maximumBytes else { throw FileError.limit }
      return ClipboardSyncFile(name: url.lastPathComponent, data: data)
    }
  }

  nonisolated static func materialize(_ files: [ClipboardSyncFile], cacheRoot: URL = ClipboardSyncStorage.cacheURL)
    throws -> [URL]
  {
    guard !files.isEmpty else { return [] }
    guard files.allSatisfy({ ClipboardSyncPayload.isSafeFileName($0.name) }),
      Set(files.map { $0.name.lowercased() }).count == files.count
    else { throw FileError.unsupported }
    guard files.count <= maximumFiles else { throw FileError.limit }
    let manager = FileManager.default
    let root = cacheRoot
    if manager.fileExists(atPath: root.path) {
      let attributes = try manager.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw FileError.unsupported }
    }
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try pruneCache(root, incomingBytes: files.reduce(0) { $0 + $1.data.count })
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      var total = 0
      let urls = try files.map { file in
        total += file.data.count
        guard total <= maximumBytes else { throw FileError.limit }
        let url = folder.appendingPathComponent(file.name)
        try file.data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
      }
      return urls
    } catch {
      try? manager.removeItem(at: folder)
      throw error
    }
  }

  nonisolated private static func pruneCache(_ root: URL, incomingBytes: Int) throws {
    let manager = FileManager.default
    let folders = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    var bytes = incomingBytes
    for folder in folders {
      guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
      let info = try manager.attributesOfItem(atPath: folder.path)
      guard info[.type] as? FileAttributeType == .typeDirectory else { continue }
      if let created = info[.creationDate] as? Date, Date().timeIntervalSince(created) > 7 * 86400 {
        try manager.removeItem(at: folder)
        continue
      }
      let entries = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      for entry in entries {
        let attributes = try manager.attributesOfItem(atPath: entry.path)
        bytes += (attributes[.size] as? NSNumber)?.intValue ?? 0
      }
    }
    guard bytes <= 200 * 1024 * 1024 else { throw FileError.cacheFull }
  }

  nonisolated enum FileError: LocalizedError {
    case unsupported
    case limit
    case cacheFull
    var errorDescription: String? {
      switch self {
      case .unsupported: "Передаются только обычные файлы; папки, ссылки и специальные файлы пропущены."
      case .cacheFull:
        "Хранилище общего буфера заполнено (200 МБ). Сохраните нужные файлы и сбросьте буфер в настройках."
      case .limit: "Буфер превышает лимит: 20 МБ суммарно или 16 файлов."
      }
    }
  }
}
