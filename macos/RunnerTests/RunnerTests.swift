import Cocoa
import FlutterMacOS
import XCTest

#if canImport(pagashell)
@testable import pagashell
#endif

@MainActor
class RunnerTests: XCTestCase {

  func testTitleBarLeavesContentInteractiveAndButtonsCenteredAfterResize() throws {
    _ = NSApplication.shared
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    let content = NSView()
    window.contentView = content
    window.setTitleBarHeight(40)

    for size in [NSSize(width: 1200, height: 760), NSSize(width: 1000, height: 640)] {
      window.setContentSize(size)
      window.update()
      window.layoutIfNeeded()
      let frameView = try XCTUnwrap(content.superview)

      for x in [120, content.bounds.midX, content.bounds.maxX - 20] {
        for top in [4.0, 20.0, 36.0] {
          let contentPoint = NSPoint(x: x, y: content.bounds.maxY - top)
          let point = content.convert(
            contentPoint, to: frameView
          )
          let hit = frameView.hitTest(point)
          XCTAssertTrue(
            hit === content || hit?.isDescendant(of: content) == true,
            "Header at (\(x), \(top)) must reach content, got \(String(describing: hit))"
          )
        }
      }

      for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try XCTUnwrap(window.standardWindowButton(type))
        let center = button.convert(
          NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView
        )
        let hit = frameView.hitTest(center)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
        let contentCenter = content.convert(center, from: frameView)
        XCTAssertEqual(content.bounds.maxY - contentCenter.y, 20, accuracy: 0.5)
      }
    }
  }

  func testCustomHeaderDisablesAutomaticMovementBeforeMouseDown() throws {
    _ = NSApplication.shared
    let window = DragProbeWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    let content = NSView()
    window.contentView = content
    window.setTitleBarHeight(40)
    XCTAssertFalse(window.isMovable, "Disable automatic titlebar dragging before the first mouse-down")

    func event(_ type: NSEvent.EventType, number: Int) throws -> NSEvent {
      let point = content.convert(
        NSPoint(x: 300, y: content.bounds.maxY - 20), to: nil
      )
      return try XCTUnwrap(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: number,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
      ))
    }

    window.sendEvent(try event(.leftMouseDown, number: 1))
    XCTAssertFalse(window.isMovable)
    window.sendEvent(try event(.leftMouseDragged, number: 2))
    XCTAssertFalse(window.isMovable)
    XCTAssertNil(window.dragEvent)
    window.sendEvent(try event(.leftMouseUp, number: 3))
    XCTAssertFalse(window.isMovable)

    let down = try event(.leftMouseDown, number: 4)
    window.sendEvent(down)
    window.startWindowDrag()
    XCTAssertTrue(window.dragEvent === down, "Explicit dragging must use the original mouse-down event")
    XCTAssertFalse(window.movableDuringDrag)
    XCTAssertFalse(window.isMovable, "Explicit dragging must not re-enable automatic titlebar dragging")

    window.sendEvent(try event(.leftMouseDown, number: 5))
    window.resignKey()
    XCTAssertFalse(window.isMovable, "Losing focus must preserve the custom header's drag policy")

    window.isMovable = false
    window.sendEvent(try event(.leftMouseDown, number: 6))
    window.sendEvent(try event(.leftMouseUp, number: 7))
    XCTAssertFalse(window.isMovable)
  }

}

@MainActor
private class DragProbeWindow: MainFlutterWindow {
  var dragEvent: NSEvent?
  var movableDuringDrag = false

  override func performDrag(with event: NSEvent) {
    dragEvent = event
    movableDuringDrag = isMovable
  }
}
