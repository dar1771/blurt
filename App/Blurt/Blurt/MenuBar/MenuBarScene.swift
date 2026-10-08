import AppKit
import BlurtEngine
import SwiftUI

/// The menu bar status item's icon. Reads the live dictation status off the
/// coordinator (created after launch, so nil early on — idle until then) and
/// re-renders as the pipeline moves, since `AppCoordinator` is `@Observable`.
/// The status enum, its phase mapping, and the glyph/VoiceOver strings all live
/// in BlurtEngine (`MenuBarStatus`), where `swift test` covers them — this view
/// just draws what the engine resolves, mirroring how `OverlayView` renders
/// `OverlayUIState`.
struct MenuBarLabel: View {
  @ObservedObject var appDelegate: AppDelegate

  var body: some View {
    let status = appDelegate.coordinator?.menuBarStatus ?? .idle
    Image(systemName: status.symbolName)
      .accessibilityLabel(status.accessibilityLabel)
  }
}

/// The menu shown when the status item is clicked. A *convenience* surface for
/// the Dock app — every item here is also reachable via the Dock icon, ⌘,, or
/// the app menu, so if the macOS notch hides the status item on a crowded menu
/// bar nothing is actually lost. Its main jobs are surfacing the (otherwise
/// invisible) dictation hotkey for discoverability and a one-click way back to
/// the window.
struct MenuBarContent: View {
  @ObservedObject var appDelegate: AppDelegate

  // Observed (as the ready screen does) so the reminder line updates live when
  // the dictation key is rebound in Settings — see `BoundTriggerKey`.
  @BoundTriggerKey private var triggerKey

  var body: some View {
    // Disabled informational row: the dictation trigger is an invisible lone
    // modifier, so spell it out here as the menu bar's discoverability anchor.
    Text(
      "Быстрый режим: \(triggerKey.label). Точный режим: \(triggerKey == .rightCommand ? TriggerKey.rightOption.label : TriggerKey.rightCommand.label)."
    )

    Divider()

    Button("Открыть VibeDictate") {
      // Reuse the shared path so this both surfaces the window and pulls the app
      // frontmost (the menu bar item can be clicked while another app is active).
      appDelegate.surfaceMainWindow()
    }
    Button("История и аудио") { appDelegate.openHistory() }
    if #available(macOS 14, *) {
      SettingsMenuButton(appDelegate: appDelegate)
    } else {
      Button("Настройки…") { appDelegate.openSettings() }
    }
    Button("Проверить обновления…") {
      appDelegate.activateApp()
      appDelegate.updateCheckModel.checkForUpdates()
    }

    Divider()

    Button("Завершить VibeDictate") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}

@available(macOS 14, *)
private struct SettingsMenuButton: View {
  @ObservedObject var appDelegate: AppDelegate
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Настройки…") {
      appDelegate.activateApp()
      openSettings()
    }
  }
}
