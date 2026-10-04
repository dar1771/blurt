import AppKit
import XCTest

/// The "you're all set" ready screen (`ReadyView`) shown in the main window once
/// setup is complete. It's unreachable under the plain `-BlurtUITest` flag — the
/// test host can't grant the real TCC permissions readiness requires — so these
/// tests opt into `-BlurtUITestReady`, which forces the fully-configured state
/// (saved key + all permissions granted) so the main window renders `ReadyView`
/// instead of the setup wizard. The rest of the suite keeps exercising the
/// wizard under the plain flag.
final class ReadyViewUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] { [UITestIdentifiers.readyLaunchArgument] }

  func testReadyScreenShowsShortcutAndRecent() {
    mainWindow()

    // Both dictation routes are visible with their default keys.
    XCTAssertTrue(
      app.staticTexts["Быстро: правую Command (⌘). Точно: правую Option (⌥)."]
        .waitForExistence(timeout: 10),
      "Ready screen should state both dictation shortcuts")
    XCTAssertTrue(app.staticTexts["Ещё раз — стоп. Или удерживайте во время речи."].exists)

    // The style row is always present — with no custom styles yet its pop-up
    // holds just Default and the "Изменить стили…" item that leads to Settings,
    // where styles are made. The caption above the card and the row's own
    // "Output Styles:" label both name it.
    XCTAssertTrue(
      app.staticTexts["Как VibeDictate обрабатывает диктовку"].exists,
      "Ready screen should caption the style row")
    let main = app.windows[UITestIdentifiers.mainWindowTitle]
    let styles = main.popUpButtons[UITestIdentifiers.styleProfilePickerFromMain]
    XCTAssertTrue(styles.waitForExistence(timeout: 10), "Style pop-up not found")
    // The value is `StyleProfileStore.defaultStyleName`, spelled out because
    // this bundle can't import the engine.
    XCTAssertEqual(
      styles.value as? String, "По умолчанию",
      "The style pop-up should start on the Default style")

    // The Recent section, empty on a fresh launch, shows its header and the
    // placeholder that fills the reserved list area.
    XCTAssertTrue(app.staticTexts["Недавние записи"].exists, "Ready screen should have a Recent section")
    XCTAssertTrue(
      app.staticTexts["Здесь появятся ваши диктовки"].exists,
      "An empty Recent list should show its placeholder")

    // The Settings button at the window's foot — the main window's own route
    // to the Settings scene, alongside ⌘, and the menu-bar item.
    XCTAssertTrue(
      main.buttons["Настройки"].exists,
      "Ready screen should offer its Settings button")
  }

  /// The style pop-up's menu: the styles, then "Изменить стили…" past a divider.
  /// The separator itself isn't an accessibility element, so what's asserted is
  /// that both kinds of item share the one menu. The menu is dismissed rather
  /// than clicked through — choosing that item opens Settings, which is
  /// `SettingsUITests`' ground.
  func testStylePopUpOffersEditStyles() {
    let main = mainWindow()

    let styles = main.popUpButtons[UITestIdentifiers.styleProfilePickerFromMain]
    XCTAssertTrue(styles.waitForExistence(timeout: 10), "Style pop-up not found")
    styles.click()

    // Matched by prefix, not equality: the item's title carries trailing
    // non-breaking spaces, which is what sets the pop-up's width (see
    // `StyleRow.Bar`).
    let editPredicate = NSPredicate(format: "title BEGINSWITH %@", "Изменить стили…")
    XCTAssertTrue(
      app.menuItems.matching(editPredicate).firstMatch.waitForExistence(timeout: 5),
      "The style menu should offer the route to where styles are edited")
    XCTAssertTrue(app.menuItems["По умолчанию"].exists, "The style menu should list the Default style")

    app.typeKey(.escape, modifierFlags: [])
  }

  func testCompletedDictationPopulatesRecentList() {
    let (harness, main) = readyScreenWindows()

    // The Recent list starts empty.
    XCTAssertTrue(
      main.staticTexts["Здесь появятся ваши диктовки"].waitForExistence(timeout: 10),
      "Recent list should start empty")

    driveDictation(via: harness)

    // The completed dictation appears as a Recent row on the ready screen.
    let row = recentRow(in: main)
    XCTAssertTrue(
      row.waitForExistence(timeout: 10),
      "A completed dictation should appear in the ready screen's Recent list")
    XCTAssertFalse(
      main.staticTexts["Здесь появятся ваши диктовки"].exists,
      "The empty-list placeholder should be gone once a dictation is recorded")
  }

  func testRecentRowCopyShowsConfirmation() {
    // Record a dictation, then copy it from the Recent row's context menu — the
    // row's copy affordance (`copyTranscript`: pasteboard write + a transient
    // "Copied" confirmation) that only `ReadyView` exercises.
    let (harness, main) = readyScreenWindows()

    driveDictation(via: harness)

    let row = recentRow(in: main)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "Recent row not found")

    // Seed the pasteboard with a sentinel so the assertion can't pass on stale
    // contents — the copy must actually replace it.
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("sentinel-before-copy", forType: .string)

    // Right-click the row to reveal its "Копировать" contextual menu item and invoke
    // it. Scope to the popup menu (`app.menus`) so it doesn't collide with the
    // always-present Edit-menu "Копировать" in the main menu bar.
    row.rightClick()
    let copyItem = app.menus.menuItems["Копировать"].firstMatch
    XCTAssertTrue(copyItem.waitForExistence(timeout: 5), "Recent row should offer a Copy action")
    copyItem.click()

    // The row writes the transcript to the system pasteboard (its "Copied" badge
    // is accessibility-hidden, so verify the real effect the copy has). Poll,
    // since the cross-process write lands a beat after the click.
    var copied: String?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      copied = pasteboard.string(forType: .string)
      if copied == UITestIdentifiers.defaultCannedTranscript { break }
      usleep(100_000)
    }
    XCTAssertEqual(
      copied, UITestIdentifiers.defaultCannedTranscript,
      "Copying a recent transcript should put it on the pasteboard")
  }

  // MARK: - Shared choreography

  /// The two windows a ready-state launch presents. The harness sits in the
  /// top-leading corner (see `BlurtApp`) so it never overlaps the centered ready
  /// window: a test can drive a full dictation on the harness, then read the
  /// result on the still-open ready screen — no closing/reopening.
  private func readyScreenWindows() -> (harness: XCUIElement, main: XCUIElement) {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    XCTAssertTrue(harness.waitForExistence(timeout: 10), "Harness window not presented")
    let main = app.windows[UITestIdentifiers.mainWindowTitle]
    XCTAssertTrue(main.waitForExistence(timeout: 10), "Ready window not presented")
    harness.click()
    XCTAssertTrue(
      harness.buttons[UITestIdentifiers.startButton].isHittable,
      "The harness should be frontmost and its Start control hittable")
    return (harness, main)
  }

  /// Drives one dictation through the direct session controls, then waits for
  /// the harness echo (`recentDictations.entries.first?.text`) to show the canned
  /// transcript — at which point the entry the ready screen renders is in place.
  /// The key-tap simulation has its own end-to-end coverage in
  /// `DictationPipelineUITests`; these checks focus on the ready screen's Recent
  /// list and copy action.
  private func driveDictation(via harness: XCUIElement) {
    // The pipeline's press-time readiness check reads the in-memory key store.
    // Seed it through the same harness action as the other pipeline UI tests,
    // rather than depending on ReadyView's launch-time setup side effect.
    harness.buttons[UITestIdentifiers.setKeyButton].click()
    harness.buttons[UITestIdentifiers.startButton].click()
    let status = harness.staticTexts[UITestIdentifiers.statusLabel]
    waitForLabel(status, equals: UITestIdentifiers.statusRecording)
    harness.buttons[UITestIdentifiers.stopButton].click()
    let echo = harness.anyDescendant(identified: UITestIdentifiers.transcriptEchoLabel)
    waitForLabel(echo, equals: UITestIdentifiers.defaultCannedTranscript)
  }

  /// The Recent row for the canned transcript (the row's VoiceOver label is
  /// "<text>, <relative time>", hence CONTAINS).
  private func recentRow(in main: XCUIElement) -> XCUIElement {
    let rowPredicate = NSPredicate(
      format: "label CONTAINS %@", UITestIdentifiers.defaultCannedTranscript)
    return main.descendants(matching: .any).matching(rowPredicate).firstMatch
  }
}
