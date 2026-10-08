import SwiftUI

/// App-menu commands.
struct BlurtCommands: Commands {
  var appDelegate: AppDelegate

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Настройки…") { appDelegate.openSettings() }
        .keyboardShortcut(",", modifiers: .command)
    }
    // "Check for Updates…" sits just below "About Blurt" in the app menu — the
    // conventional macOS spot, and the placement Sparkle's own SwiftUI guidance
    // uses (`CommandGroup(after: .appInfo)`). It runs the same check as the
    // Settings button and reports the result in a modal (see `UpdateCheckModel`).
    // The ellipsis marks that it goes off and does work (and may present a
    // dialog).
    CommandGroup(after: .appInfo) {
      Button("Проверить обновления…") { appDelegate.updateCheckModel.checkForUpdates() }
    }
    CommandMenu("Диктовка") {
      Button("Вставить последнюю запись") { appDelegate.historyModel.insertLast() }
        .keyboardShortcut("v", modifiers: [.option, .command])
      Button("Открыть историю") { appDelegate.openHistory() }
        .keyboardShortcut("h", modifiers: [.option, .command])
    }
    // Blurt ships no help book, so SwiftUI's default Help menu would show a
    // dead "Blurt Help" item that opens nothing. Remove it rather than leave
    // a control that does nothing.
    CommandGroup(replacing: .help) {}
  }
}
