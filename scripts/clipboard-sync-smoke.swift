import AppKit
import BlurtEngine
import Foundation

/// Compile with the app's pasteboard/files/storage adapters and built engine object.
/// All fixtures use a named pasteboard and a fresh temporary directory: no user clipboard or Keychain.
@main
struct ClipboardSyncSmoke {
  @MainActor static func main() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipboardSyncSmoke-\(UUID())"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-smoke-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      pasteboard.releaseGlobally()
      try? FileManager.default.removeItem(at: root)
    }
    try checkFormats(pasteboard)
    try checkImageAliases(pasteboard)
    try checkMarkers(pasteboard)
    try checkConflict(pasteboard)
    try checkFiles(root: root, pasteboard: pasteboard)
    print(
      "ok: clipboard sync shell smoke (formats, secret/temporary markers, echo, copy race, real file bytes, symlink refusal)"
    )
  }

  @MainActor static func checkFormats(_ pasteboard: NSPasteboard) throws {
    let text = Data("Привет, другой Mac 👋".utf8)
    let html = Data("<b>Привет</b>".utf8)
    guard
      let png = Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6UHYAAAAASUVORK5CYII=")
    else { throw SmokeError.failed("PNG fixture") }
    let representations = ["public.utf8-plain-text": text, "public.html": html, "public.png": png]
    let entry = NSPasteboardItem()
    for (type, data) in representations { entry.setData(data, forType: .init(type)) }
    pasteboard.clearContents()
    try require(pasteboard.writeObjects([entry]), "write fixture")
    let snapshot = try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard)
    try require(snapshot?.items.first?.representations == representations, "all rich text/image bytes preserved")
    let payload = ClipboardSyncPayload(origin: UUID(), items: [ClipboardSyncItem(representations: representations)])
    try require(ClipboardSyncPasteboard.apply(payload, urls: [], pasteboard: pasteboard), "apply formats")
    try require(pasteboard.data(forType: .html) == html, "HTML roundtrip")
    try require(pasteboard.data(forType: .png) == png, "image roundtrip")
    try require(try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard) == nil, "received marker stops echo")
  }

  @MainActor static func checkImageAliases(_ pasteboard: NSPasteboard) throws {
    guard
      let png = Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6UHYAAAAASUVORK5CYII=")
    else { throw SmokeError.failed("PNG alias fixture") }
    let jpeg = Data("compact JPEG fixture".utf8)
    let tiff = Data("small TIFF fixture".utf8)
    let html = Data("<b>image caption</b>".utf8)
    let largeTIFF = Data(repeating: 0, count: ClipboardSyncFiles.maximumBytes + 1)
    let entry = NSPasteboardItem()
    entry.setData(png, forType: .png)
    entry.setData(html, forType: .html)
    let tracker = ImageDataProvider(data: [.tiff: largeTIFF])
    entry.setDataProvider(tracker, forTypes: [.tiff])
    pasteboard.clearContents()
    pasteboard.writeObjects([entry])
    let compact = try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard)
    try require(
      compact?.items.first?.representations == ["public.png": png, "public.html": html],
      "PNG alias avoids oversized TIFF and preserves HTML")
    try require(tracker.requestedTypes.isEmpty, "TIFF alias was never materialized")

    let onlyTIFF = NSPasteboardItem()
    onlyTIFF.setData(tiff, forType: .tiff)
    pasteboard.clearContents()
    pasteboard.writeObjects([onlyTIFF])
    let tiffSnapshot = try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard)
    try require(tiffSnapshot?.items.first?.representations == ["public.tiff": tiff], "TIFF-only clipboard preserved")

    let fallback = NSPasteboardItem()
    fallback.setData(jpeg, forType: .init("public.jpeg"))
    fallback.setData(tiff, forType: .tiff)
    let unavailablePNG = ImageDataProvider(data: [:])
    fallback.setDataProvider(unavailablePNG, forTypes: [.png])
    pasteboard.clearContents()
    pasteboard.writeObjects([fallback])
    let jpegSnapshot = try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard)
    try require(
      jpegSnapshot?.items.first?.representations == ["public.jpeg": jpeg],
      "unreadable declared PNG falls back to JPEG before TIFF")
    try require(unavailablePNG.requestedTypes.contains(.png), "declared PNG read was attempted")
  }

  @MainActor static func checkMarkers(_ pasteboard: NSPasteboard) throws {
    for marker in ClipboardSyncPasteboard.excluded {
      let entry = NSPasteboardItem()
      entry.setString("secret/transient", forType: .string)
      entry.setData(Data(), forType: .init(marker))
      pasteboard.clearContents()
      pasteboard.writeObjects([entry])
      try require(try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard) == nil, "excluded marker \(marker)")
    }
    pasteboard.clearContents()
    pasteboard.setString("original clipboard", forType: .string)
    let original = try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard)?.fingerprint
    pasteboard.clearContents()
    pasteboard.setString("temporary transcript", forType: .string)
    pasteboard.setData(Data(), forType: .init("com.vibedictate.dictation-record-id"))
    try require(try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard) == nil, "dictation transient")
    pasteboard.clearContents()
    pasteboard.setString("original clipboard", forType: .string)
    try require(
      try ClipboardSyncPasteboard.snapshot(pasteboard: pasteboard)?.fingerprint == original, "restore fingerprint")
  }

  @MainActor static func checkConflict(_ pasteboard: NSPasteboard) throws {
    pasteboard.clearContents()
    pasteboard.setString("before transfer", forType: .string)
    let before = pasteboard.changeCount
    pasteboard.clearContents()
    pasteboard.setString("new user copy", forType: .string)
    let payload = ClipboardSyncPayload(
      origin: UUID(),
      items: [
        ClipboardSyncItem(
          representations: ["public.utf8-plain-text": Data("remote stale".utf8)])
      ])
    let applied = ClipboardSyncPasteboard.apply(payload, urls: [], pasteboard: pasteboard, expectedChangeCount: before)
    try require(!applied, "new local copy blocks incoming write")
    try require(pasteboard.string(forType: .string) == "new user copy", "new local copy survives")
  }

  @MainActor static func checkFiles(root: URL, pasteboard: NSPasteboard) throws {
    let source = root.appendingPathComponent("Отчёт.pdf")
    let data = Data((0..<65536).map { UInt8($0 % 251) })
    try data.write(to: source)
    let files = try ClipboardSyncFiles.read([source])
    try require(
      files.first?.data == data && files.first?.name == source.lastPathComponent, "read complete source bytes")
    let cache = root.appendingPathComponent("received")
    let received = try ClipboardSyncFiles.materialize(files, cacheRoot: cache)
    guard let url = received.first else { throw SmokeError.failed("received file missing") }
    try require(url.lastPathComponent == source.lastPathComponent, "received file keeps original name")
    try require(try Data(contentsOf: url) == data, "received file complete bytes")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private received file permissions")
    let payload = ClipboardSyncPayload(origin: UUID(), files: files)
    try require(
      ClipboardSyncPasteboard.apply(payload, urls: received, pasteboard: pasteboard), "Finder file URL pasteboard")
    try require(pasteboard.string(forType: .fileURL) == url.absoluteString, "local received URL, not source URL")
    let link = root.appendingPathComponent("symlink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    do {
      _ = try ClipboardSyncFiles.read([link])
      throw SmokeError.failed("symlink unexpectedly accepted")
    } catch is ClipboardSyncFiles.FileError {}
    do {
      _ = try ClipboardSyncFiles.read([root])
      throw SmokeError.failed("directory unexpectedly accepted")
    } catch is ClipboardSyncFiles.FileError {}
    try require(
      try ClipboardSyncFiles.materialize([], cacheRoot: root.appendingPathComponent("empty")).isEmpty, "empty file list"
    )
    try require(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path),
      "text doesn't create file directories")
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeError.failed(message) }
  }

  enum SmokeError: Error { case failed(String) }
}

/// Promised data allows testing that unused aliases are never requested and
/// a declared image format can legitimately decline materialization.
final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider {
  private let data: [NSPasteboard.PasteboardType: Data]
  private(set) var requestedTypes: [NSPasteboard.PasteboardType] = []

  init(data: [NSPasteboard.PasteboardType: Data]) { self.data = data }

  func pasteboard(
    _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
  ) {
    requestedTypes.append(type)
    if let value = data[type] { item.setData(value, forType: type) }
  }
}
