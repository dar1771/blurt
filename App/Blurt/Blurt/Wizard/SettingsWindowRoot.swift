import AppKit
import BlurtEngine
import SwiftUI

/// Settings stay within the visible screen; long forms scroll rather than
/// placing their last controls below the window. The explicit selector keeps
/// every pane available without a TabView overflow menu.
struct SettingsWindowRoot: View {
  @ObservedObject var appDelegate: AppDelegate

  private enum Tab: Hashable { case general, textShortcuts, vibeDictate, clipboard, advanced }

  /// Always open on General, except for the main window's "+" deep-link.
  @State private var tab: Tab = .general

  var body: some View {
    if let coordinator = appDelegate.coordinator {
      VStack(spacing: 0) {
        HStack(spacing: 4) {
          tabButton(UITestIdentifiers.generalSettingsTab, .general)
          tabButton(UITestIdentifiers.textShortcutsTab, .textShortcuts)
          tabButton("VibeDictate", .vibeDictate)
          tabButton(UITestIdentifiers.clipboardSettingsTab, .clipboard)
          tabButton(UITestIdentifiers.advancedSettingsTab, .advanced)
        }
        .padding(12)
        Divider()
        Group {
          switch tab {
          case .general: GeneralSettingsTab(coordinator: coordinator)
          case .textShortcuts: TextShortcutsSection()
          case .vibeDictate: VibeDictateSettingsTab(history: appDelegate.historyModel)
          case .clipboard: ClipboardSyncSettingsView(model: appDelegate.clipboardSyncModel)
          case .advanced:
            AdvancedSettingsTab(
              coordinator: coordinator, updateModel: appDelegate.updateCheckModel,
              clipboardModel: appDelegate.clipboardSyncModel)
          }
        }
      }
      .frame(
        width: MainWindow.contentWidth,
        height: min(640, (NSScreen.main?.visibleFrame.height ?? 720) - 80), alignment: .top
      )
      // Consumes the "+" deep-link (`AppDelegate.settingsOpensOnAdvanced`):
      // switch to Advanced, then reset the flag so it's one-shot — every other
      // route into Settings (⌘,, the Settings buttons, the menu-bar item)
      // still opens on General. `initial: true` covers the window being
      // (re)created after the flag was set; the observed change covers an
      // already-open Settings window, which switches panes in place.
      .onAppear { consumeAdvancedDeepLink() }
      .onChange(of: appDelegate.settingsOpensOnAdvanced) { _ in
        consumeAdvancedDeepLink()
      }
    } else {
      Color.clear.frame(width: MainWindow.contentWidth, height: 240)
    }
  }

  private func tabButton(_ title: String, _ destination: Tab) -> some View {
    Button {
      tab = destination
    } label: {
      Text(title)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .padding(.vertical, 7)
    .background(tab == destination ? Color.accentColor.opacity(0.16) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 7))
  }

  private func consumeAdvancedDeepLink() {
    guard appDelegate.settingsOpensOnAdvanced else { return }
    tab = .advanced
    appDelegate.settingsOpensOnAdvanced = false
  }
}

/// Grouped forms share the bounded settings viewport and scroll when needed.
private struct SettingsPane<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)

  }
}

/// The everyday setup a user changes: the AssemblyAI key, the dictation
/// shortcut, the microphone, the cue sound, and the transcription key terms.
private struct GeneralSettingsTab: View {
  @ObservedObject var coordinator: AppCoordinator

  var body: some View {
    SettingsPane {
      APIKeyStepView(apiKey: coordinator.apiKey)
      HotkeyStepView(coordinator: coordinator)
      MicrophoneStepView()
      SoundStepView(coordinator: coordinator)
      KeyTermsStepView()
    }
  }
}

/// The occasional stuff: the enhanced-transcripts switch, the style profiles,
/// checking for an update, the developer-mode log toggle, and the
/// start-over button.
/// Kept out of General so the common pane stays short.
private struct AdvancedSettingsTab: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var updateModel: UpdateCheckModel
  @ObservedObject var clipboardModel: ClipboardSyncModel

  var body: some View {
    SettingsPane {
      TranscriptionSection()
      StyleProfilesSection()
      UpdateSection(model: updateModel)
      DeveloperSection()
      ResetSection(coordinator: coordinator, clipboardModel: clipboardModel)
    }
  }
}

/// The Transcription section of the Settings window: the enhanced-transcripts
/// switch. Every dictation request asks AssemblyAI's dictation API for its
/// server-side cleanup rewrite, so the response always holds both versions;
/// while this is on (the default) the polished one is pasted, and turned off
/// the verbatim transcript is pasted exactly as spoken. The transcriber reads
/// the same default this toggle writes at every request, so a change applies to
/// the next dictation — see `AssemblyAITranscriber.transcript(from:)`.
/// Settings-only — not a wizard step, since it never gates setup.
private struct TranscriptionSection: View {
  // The unset default comes from the store, not a literal here: the transcriber
  // reads the same slot per request, and two spellings of "unset means on" would let
  // the toggle and the request disagree about an untouched install.
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  var body: some View {
    Section {
      Toggle(isOn: $enhancedTranscripts) {
        Label("Улучшать текст", systemImage: "wand.and.stars")
      }
      .accessibilityIdentifier(UITestIdentifiers.enhancedTranscriptsToggle)
    } header: {
      Text("Распознавание")
    } footer: {
      Text(
        "Убирает слова-паразиты и исправляет пунктуацию перед вставкой. "
          + "Выключите, чтобы вставлять текст без обработки.")
    }
  }
}

/// The Styles section of the Settings window: up to
/// `StyleProfileStore.profileLimit` named sets of style instructions, the active
/// one of which is appended to the cleanup instruction on every dictation
/// request (see `CleanupInstruction.sendable(appending:)` / `StyleProfileStore`),
/// so the enhanced-transcript polish also applies the user's formatting
/// preferences. Optional — with none defined the request is exactly what ships
/// today. Disabled while enhanced transcripts are off, since the instruction
/// they extend is not sent at all then.
///
/// Each row is a name and a way in: all editing happens in the sheet below, for
/// the reasons on `APIKeyStepView`'s. Which style is *active* is deliberately
/// not set here — the main window's switcher owns that (see `ReadyView`), so
/// switching is one click instead of a trip through Settings, and a second
/// control here would be two writers on the same slot.
private struct StyleProfilesSection: View {
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  /// Bound to observe, not to write: the store owns the JSON encoding, so it
  /// decodes this slot and the sheet writes through it, while `@AppStorage` is
  /// what re-renders these rows when a write lands.
  @AppStorage(StyleProfileStore.defaultsKey) private var rawProfiles = ""

  /// The profile the sheet is editing, or nil while it's closed. Carries the
  /// value rather than an index, so a list that changes underneath can't leave
  /// the sheet pointed at a different profile.
  @State private var editing: StyleProfile?

  private var profiles: [StyleProfile] { StyleProfileStore().profiles(decoding: rawProfiles) }

  var body: some View {
    Section {
      // Enumerated for the accessibility identifier only — identity is the
      // profile's own stable id, so a rename doesn't rebuild the row.
      ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
        SettingRow(title: profile.name, systemImage: "textformat") {
          Button("Изменить…") { editing = profile }
            .accessibilityIdentifier(UITestIdentifiers.styleProfileEdit(index))
        }
      }
      // Ellipsis for the same reason as the API-key row's "Connect…": the
      // action needs more input before it completes.
      Button("Добавить стиль…") { editing = StyleProfile(name: "", instructions: "") }
        .disabled(profiles.count >= StyleProfileStore.profileLimit)
        .accessibilityIdentifier(UITestIdentifiers.styleProfileAdd)
    } header: {
      Text("Стили текста")
    } footer: {
      // The caveat *replaces* the help sentence rather than joining it: with
      // enhanced transcripts off the rewrite a style shapes is discarded
      // unread, so describing the limit is the less useful half.
      Text(
        enhancedTranscripts
          ? "Можно добавить до \(StyleProfileStore.profileLimit) стилей."
          : "Для стилей включите улучшение текста.")
    }
    .disabled(!enhancedTranscripts)
    .sheet(item: $editing) { profile in
      StyleProfileEditorSheet(profile: profile, isExisting: profiles.contains(profile))
    }
  }
}

/// The style-editing task itself, presented as a sheet from the settings row.
///
/// A sheet for the reasons spelled out on `APIKeyEditorSheet`, whose shape this
/// follows: a headline that names the task, full-width fields under their own
/// labels, and that button layout — the destructive action at the leading edge,
/// clear of the Cancel / default-action pair at the trailing edge, with Return
/// and Escape scoped to the sheet. Unlike that one there is nothing to validate
/// against a server, so Save is a plain write; the caps are enforced as you type
/// so text is never silently lost at the boundary.
private struct StyleProfileEditorSheet: View {
  /// The profile being edited — a freshly minted one on the "Add Style…" path.
  let profile: StyleProfile
  /// Whether `profile` is already in the stored list. Drives the Delete button:
  /// a profile that was never saved has nothing to remove, and offering Delete
  /// beside Cancel would be two words for the same outcome.
  let isExisting: Bool

  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var instructions: String
  @FocusState private var nameFocused: Bool

  init(profile: StyleProfile, isExisting: Bool) {
    self.profile = profile
    self.isExisting = isExisting
    _name = State(initialValue: profile.name)
    _instructions = State(initialValue: profile.instructions)
  }

  /// Both fields must say something. A nameless profile would render a blank
  /// segment in the main window's switcher, and one with no instructions would
  /// be a segment that changes nothing about the dictation it selects.
  private var canSave: Bool {
    name.trimmedNonEmpty() != nil && instructions.trimmedNonEmpty() != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Стиль текста")
          .font(.headline)
        Text("Задайте регистр, тон и использование эмодзи при обработке текста.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      nameField
      instructionsField
      buttonRow
    }
    .padding(20)
    .frame(width: 420)
    // Naming the style is the first thing to do, and on the Add path the only
    // empty field — so open with the caret already in it.
    .defaultFocus($nameFocused, true)
  }

  /// A real, visible label rather than a placeholder: the prompt disappears the
  /// moment text lands, and this field sits beside a second one, so "which box
  /// is which" has to survive being filled in.
  private var nameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Название")
        .font(.subheadline.weight(.semibold))
      TextField("", text: $name, prompt: Text("Например: Неформальный"))
        .lineLimit(1)
        .disableAutocorrection(true)
        .focused($nameFocused)
        .accessibilityLabel("Название стиля")
        .accessibilityIdentifier(UITestIdentifiers.styleProfileName)
        // Capped because the name labels a segment of the main window's
        // switcher; counted in characters, which is what that width bounds.
        .onChange(of: name) { _ in
          if name.count > StyleProfileStore.nameLimit {
            name = String(name.prefix(StyleProfileStore.nameLimit))
          }
        }
    }
  }

  /// The multi-line instruction field, with the byte counter directly beneath
  /// the field it measures.
  private var instructionsField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Инструкции")
        .font(.subheadline.weight(.semibold))
      // A vertical-axis TextField grows with its content up to `lineLimit`, so
      // there's no faked placeholder over a TextEditor.
      TextField(
        text: $instructions,
        prompt: Text("Например: иногда добавляй подходящие эмодзи"),
        axis: .vertical
      ) {
        Text("Инструкции")
      }
      .labelsHidden()
      .lineLimit(2...6)
      .font(.body)
      .disableAutocorrection(true)
      .accessibilityIdentifier(UITestIdentifiers.styleProfileInstructions)
      .onChange(of: instructions) { _ in
        // The dictation API rejects the whole request over its instruction
        // limit, so text past the cap must never be storable.
        if instructions.utf8.count > StyleProfileStore.characterLimit {
          instructions = instructions.prefix(maxUTF8Bytes: StyleProfileStore.characterLimit)
        }
      }
      // The API caps the instruction, so the room left is finite — show it
      // rather than truncating silently at the limit. Counted in UTF-8 bytes,
      // the unit the limit is enforced in.
      Text("\(instructions.utf8.count)/\(StyleProfileStore.characterLimit)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(
          "Использовано \(instructions.utf8.count) из \(StyleProfileStore.characterLimit) символов")
    }
  }

  private var buttonRow: some View {
    HStack(spacing: 12) {
      if isExisting {
        Button("Удалить", role: .destructive, action: delete)
          .accessibilityIdentifier(UITestIdentifiers.styleProfileDelete)
      }
      Spacer(minLength: 12)
      Button("Отмена") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(UITestIdentifiers.styleProfileCancel)
      Button("Сохранить", action: save)
        .glassButtonStyleCompat(prominent: true)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
        .accessibilityIdentifier(UITestIdentifiers.styleProfileSave)
    }
  }

  /// Writes the edit through the store, which owns the encoding and the caps.
  /// Merged against the *stored* list rather than the observed copy, so a change
  /// made in another settings window while this sheet was open isn't clobbered.
  private func save() {
    guard canSave else { return }
    var edited = profile
    edited.name = name
    edited.instructions = instructions
    let store = StyleProfileStore()
    var updated = store.profiles
    if let index = updated.firstIndex(where: { $0.id == edited.id }) {
      updated[index] = edited
    } else {
      updated.append(edited)
    }
    store.profiles = updated
    dismiss()
  }

  /// No confirmation alert: a style is a couple of sentences the user typed, the
  /// button is `.destructive` and out of the way of Save, and nothing else
  /// depends on it — deleting the active one just falls back to the first
  /// remaining profile (see `StyleProfileStore.active`).
  private func delete() {
    let store = StyleProfileStore()
    store.profiles = store.profiles.filter { $0.id != profile.id }
    dismiss()
  }
}

/// The Updates section of the Settings window: the running version and a
/// "Check for Updates" button that runs the check and reports the result in a
/// modal (see `UpdateCheckModel`). The same check is reachable from the
/// "Check for Updates…" app-menu command and the menu-bar item; all three share
/// the one `UpdateCheckModel` owned by `AppDelegate`, so a check from any place
/// runs through the same controller.
