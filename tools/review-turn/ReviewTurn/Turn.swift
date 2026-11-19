import XCTest

/// Sets up the simulated iPad for the review pictures (simulator only, never the
/// app's tests; tools/review_turn.py runs it). iPadOS refuses an app's own
/// request to turn ("The current windowing mode does not allow for programmatic
/// changes to interface orientation", UISceneErrorDomain 101), so the device is
/// turned: TEST_RUNNER_TURN is the interface's way, left or right, or upright
/// (the interface's landscape left is the device's landscape right).
final class Turn: XCTestCase {
  @MainActor func testTurn() {
    let way = ProcessInfo.processInfo.environment["TURN"] ?? "upright"
    let wanted: UIDeviceOrientation =
      switch way {
      case "left": .landscapeRight
      case "right": .landscapeLeft
      default: .portrait
      }
    // through another way first: after Settings the device can keep reporting
    // the last way it was set without the screen being turned
    XCUIDevice.shared.orientation = wanted == .portrait ? .landscapeRight : .portrait
    Thread.sleep(forTimeInterval: 1)
    XCUIDevice.shared.orientation = wanted
    Thread.sleep(forTimeInterval: 1)
    XCTAssertEqual(XCUIDevice.shared.orientation, wanted)
  }

  /// Drags the running app's resize handle (the bottom right corner) to
  /// TEST_RUNNER_WINDOW, "w,h" in fractions of the screen: a window of that size.
  @MainActor func testWindow() throws {
    let spec = (ProcessInfo.processInfo.environment["WINDOW"] ?? "0.6,0.6").split(separator: ",")
    let app = XCUIApplication(bundleIdentifier: "com.throwingwood.app")
    let screen = app.coordinate(withNormalizedOffset: .zero)
    let frame = app.frame
    let corner = screen.withOffset(CGVector(dx: frame.maxX - 6, dy: frame.maxY - 6))
    let to = screen.withOffset(
      CGVector(dx: frame.width * Double(spec[0])!, dy: frame.height * Double(spec[1])!))
    corner.press(forDuration: 0.6, thenDragTo: to)
  }

  /// Sets the simulated iPad's multitasking (Settings, Multitasking & Gestures):
  /// TEST_RUNNER_MODE "Windowed Apps" for the window tests, else "Full Screen
  /// Apps", the review pictures' mode.
  @MainActor func testMode() throws {
    let mode = ProcessInfo.processInfo.environment["MODE"] ?? "Full Screen Apps"
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    let multitasking = settings.staticTexts["Multitasking & Gestures"]
    XCTAssert(multitasking.waitForExistence(timeout: 10))
    multitasking.tap()
    let choice = settings.staticTexts[mode]
    XCTAssert(choice.waitForExistence(timeout: 10))
    choice.tap()
    settings.terminate()
  }
}
