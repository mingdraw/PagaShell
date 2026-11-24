import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    if let window = mainFlutterWindow as? MainFlutterWindow, window.isHiddenInTray {
      return false
    }
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow as? MainFlutterWindow {
      window.reopenFromDock()
    }
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    (mainFlutterWindow as? MainFlutterWindow)?.cleanupTray()
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
