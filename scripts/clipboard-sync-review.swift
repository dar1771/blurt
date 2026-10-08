import AppKit
import BlurtEngine
import Foundation

/// Independent file/clipboard boundary checks. Named pasteboard and temporary files only.
@main
struct ClipboardSyncReview {
  @MainActor static func main() throws {
    let board = NSPasteboard(name: .init("ClipboardSyncReview-\(UUID())"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-review-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      board.releaseGlobally()
      try? FileManager.default.removeItem(at: root)
    }
    try clipboardStructure(board)
    try filenamesAndDirectories(root)
    try fileLimits(root)
    try cacheBoundaries(root)
    print(
      "ok: independent clipboard review (item boundaries, Unicode/long names, symlink cache, limits, private files)")
  }

  @MainActor static func clipboardStructure(_ board: NSPasteboard) throws {
    func set(_ texts: [String]) throws -> Data {
      board.clearContents()
      let objects = texts.map { text in
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
      }
      try require(board.writeObjects(objects), "fixture write")
      guard let hash = try ClipboardSyncPasteboard.snapshot(pasteboard: board)?.fingerprint else {
        throw Failure.expected("supported text snapshot")
      }
      return hash
    }
    let single = try set(["apublic.utf8-plain-textb"])
    let multiple = try set(["a", "b"])
    try require(single != multiple, "one text and two texts have distinct fingerprints")
    let tooMany = (0..<33).map { index in
      let item = NSPasteboardItem()
      item.setString("\(index)", forType: .string)
      return item
    }
    board.clearContents()
    try require(board.writeObjects(tooMany), "many items fixture")
    try refused("too many clipboard items") { _ = try ClipboardSyncPasteboard.snapshot(pasteboard: board) }
    board.clearContents()
    board.setData(Data(repeating: 65, count: ClipboardSyncFiles.maximumBytes + 1), forType: .string)
    try refused("oversized existing clipboard") { _ = try ClipboardSyncPasteboard.snapshot(pasteboard: board) }
    board.clearContents()
    board.setString("file:///tmp/same-file.txt", forType: .fileURL)
    guard let fileSnapshot = try ClipboardSyncPasteboard.snapshot(pasteboard: board) else {
      throw Failure.expected("file URL snapshot")
    }
    let oldFile = ClipboardSyncPasteboard.contentFingerprint(
      fileSnapshot, files: [.init(name: "same-file.txt", data: Data([1]))])
    let updatedFile = ClipboardSyncPasteboard.contentFingerprint(
      fileSnapshot, files: [.init(name: "same-file.txt", data: Data([2]))])
    try require(oldFile != updatedFile, "same path with changed bytes gets a new fingerprint")
  }

  static func filenamesAndDirectories(_ root: URL) throws {
    let prefix = String(repeating: "a", count: 151)
    let files = [
      ClipboardSyncFile(name: prefix + "1.txt", data: Data([1, 2, 3])),
      ClipboardSyncFile(name: prefix + "2.txt", data: Data([4, 5, 6])),
      ClipboardSyncFile(name: "Документ 🧾.txt", data: Data("слова".utf8)),
    ]
    let cache = root.appendingPathComponent("names")
    let urls = try ClipboardSyncFiles.materialize(files, cacheRoot: cache)
    try require(urls.map(\.lastPathComponent) == files.map(\.name), "exact long and Unicode filenames preserved")
    for (url, file) in zip(urls, files) {
      try require(try Data(contentsOf: url) == file.data, "distinct files retain complete bytes")
      let info = try FileManager.default.attributesOfItem(atPath: url.path)
      try require((info[.posixPermissions] as? NSNumber)?.intValue == 0o600, "file mode is private and nonexecutable")
    }
    let directory = try FileManager.default.attributesOfItem(atPath: cache.path)
    try require((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700, "cache mode private")
    for name in ["../escape", ".hidden", "a/b", "a:b", "a\\b", "a\n.txt"] {
      try refused("unsafe filename \(name)") {
        _ = try ClipboardSyncFiles.materialize([.init(name: name, data: Data())], cacheRoot: cache)
      }
    }
    try refused("case-insensitive duplicate files") {
      _ = try ClipboardSyncFiles.materialize(
        [.init(name: "FILE.txt", data: Data([1])), .init(name: "file.txt", data: Data([2]))], cacheRoot: cache)
    }
    let linkedCache = root.appendingPathComponent("linked-cache")
    try FileManager.default.createSymbolicLink(at: linkedCache, withDestinationURL: cache)
    try refused("symlink destination root") {
      _ = try ClipboardSyncFiles.materialize(files, cacheRoot: linkedCache)
    }
  }

  static func fileLimits(_ root: URL) throws {
    let manager = FileManager.default
    let oversize = root.appendingPathComponent("oversize.bin")
    try Data().write(to: oversize)
    let handle = try FileHandle(forWritingTo: oversize)
    try handle.truncate(atOffset: UInt64(ClipboardSyncFiles.maximumBytes + 1))
    try handle.close()
    try refused("source aggregate size limit") { _ = try ClipboardSyncFiles.read([oversize]) }
    let empty = root.appendingPathComponent("empty.txt")
    try Data().write(to: empty)
    try refused("source file count limit") { _ = try ClipboardSyncFiles.read(Array(repeating: empty, count: 17)) }
    try refused("received file count limit") {
      _ = try ClipboardSyncFiles.materialize(
        (0..<17).map { .init(name: "file\($0)", data: Data()) }, cacheRoot: root.appendingPathComponent("many"))
    }
    try refused("special device source") { _ = try ClipboardSyncFiles.read([URL(fileURLWithPath: "/dev/null")]) }
    let real = try ClipboardSyncFiles.read([empty])
    try require(real.count == 1 && real[0].data.isEmpty, "empty regular file supported")
    let emptyCache = root.appendingPathComponent("no-text-cache")
    _ = try ClipboardSyncFiles.materialize([], cacheRoot: emptyCache)
    try require(!manager.fileExists(atPath: emptyCache.path), "empty list creates no disk cache")
  }

  static func cacheBoundaries(_ root: URL) throws {
    let manager = FileManager.default
    let cache = root.appendingPathComponent("full-cache")
    let old = cache.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: old, withIntermediateDirectories: true)
    let sparse = old.appendingPathComponent("existing.bin")
    try Data().write(to: sparse)
    let handle = try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 200 * 1024 * 1024)
    try handle.close()
    try refused("disk cache aggregate limit") {
      _ = try ClipboardSyncFiles.materialize([.init(name: "new.bin", data: Data([1]))], cacheRoot: cache)
    }
    try require(manager.fileExists(atPath: sparse.path), "full cache refusal preserves existing file")
    try manager.setAttributes([.creationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
    let received = try ClipboardSyncFiles.materialize([.init(name: "new.bin", data: Data([1]))], cacheRoot: cache)
    try require(!manager.fileExists(atPath: old.path), "expired cache removed at next file receipt")
    try require(received.count == 1, "expired cache permits next incoming file")
  }

  static func refused(_ message: String, operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure.expected(message)
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.expected(message) }
  }

  enum Failure: Error { case expected(String) }
}
