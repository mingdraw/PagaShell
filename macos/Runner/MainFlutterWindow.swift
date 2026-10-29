import Cocoa
import FlutterMacOS
import Darwin

class MainFlutterWindow: NSWindow {
  private var customTitleBarHeight: CGFloat?
  private var windowChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?
  private var headerMouseDownEvent: NSEvent?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    let files = FlutterMethodChannel(
      name: "pagashell/files",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    filesChannel = files
    files.setMethodCallHandler { call, result in
      guard call.method == "getUserHomeDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // NSHomeDirectory/HOME 在 App Sandbox 中指向容器。账号记录保留真实主目录。
      guard let account = getpwuid(getuid()), let home = account.pointee.pw_dir else {
        result(FlutterError(code: "home_unavailable", message: "User home directory unavailable", details: nil))
        return
      }
      result(String(cString: home))
    }

    let channel = FlutterMethodChannel(
      name: "pagashell/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "getWindowButtonCenters" {
        result(self?.windowButtonCentersFromTop() ?? [])
        return
      }
      if call.method == "startWindowDrag" {
        self?.startWindowDrag()
        result(nil)
        return
      }
      guard call.method == "setTitleBarHeight" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let height = arguments["height"] as? Double,
            height.isFinite, height > 0 else {
        result(FlutterError(code: "invalid_height", message: "Invalid title bar height", details: nil))
        return
      }
      self?.setTitleBarHeight(CGFloat(height))
      result(nil)
    }
  }

  override func update() {
    // AppKit 在缩放、窗口激活及退出全屏时会重新布局原生标题栏。
    centerWindowButtons()
    super.update()
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      headerMouseDownEvent = nil
      if isCustomHeaderContent(event.locationInWindow) {
        headerMouseDownEvent = event
      }
    }
    defer {
      if event.type == .leftMouseUp {
        headerMouseDownEvent = nil
      }
    }
    super.sendEvent(event)
  }

  override func resignKey() {
    headerMouseDownEvent = nil
    super.resignKey()
  }

  @IBAction func showSettings(_ sender: Any?) {
    invokeWindowCommand("showSettings")
  }

  @IBAction func showQuickConnect(_ sender: Any?) {
    invokeWindowCommand("showQuickConnect")
  }

  @IBAction func newService(_ sender: Any?) {
    invokeWindowCommand("newService")
  }

  @IBAction func closeActiveTab(_ sender: Any?) {
    invokeWindowCommand("closeActiveTab")
  }

  private func invokeWindowCommand(_ method: String) {
    if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
    windowChannel?.invokeMethod(method, arguments: nil)
  }

  func startWindowDrag() {
    guard let event = headerMouseDownEvent else { return }
    // performDrag 是应用显式拖窗，不需要重新打开标题栏的自动拖窗。
    headerMouseDownEvent = nil
    performDrag(with: event)
  }

  private func isCustomHeaderContent(_ point: NSPoint) -> Bool {
    guard let height = customTitleBarHeight,
          styleMask.contains(.fullSizeContentView),
          !styleMask.contains(.fullScreen),
          let contentView = contentView else { return false }
    let contentPoint = contentView.convert(point, from: nil)
    let distanceFromTop = contentView.isFlipped
      ? contentPoint.y - contentView.bounds.minY
      : contentView.bounds.maxY - contentPoint.y
    guard contentView.bounds.contains(contentPoint),
          distanceFromTop >= 0, distanceFromTop < height else { return false }
    return ![NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { type in
      guard let button = standardWindowButton(type) else { return false }
      return button.bounds.contains(button.convert(point, from: nil))
    }
  }

  func setTitleBarHeight(_ height: CGFloat) {
    customTitleBarHeight = height
    // 保留原生窗口按钮，将隐藏标题栏的拖动交给 Flutter 的空白区域。
    isMovable = false
    centerWindowButtons()
  }

  private func windowButtonCentersFromTop() -> [Double] {
    guard let contentView = contentView else { return [] }
    return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
      guard let button = standardWindowButton(type) else { return nil }
      let center = contentView.convert(
        NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button
      )
      return Double(contentView.isFlipped ? center.y : contentView.bounds.maxY - center.y)
    }
  }

  private func centerWindowButtons() {
    guard let height = customTitleBarHeight,
          styleMask.contains(.fullSizeContentView),
          !styleMask.contains(.fullScreen),
          let closeButton = standardWindowButton(.closeButton),
          let buttonContainer = closeButton.superview,
          let titleBarContainer = buttonContainer.superview,
          let frameView = titleBarContainer.superview else {
      return
    }

    // 扩展原生按钮的布局；窗口拖动由 Flutter 空白区域显式发起。
    var titleBarFrame = titleBarContainer.frame
    titleBarFrame.size.height = height
    titleBarFrame.origin.y = frameView.isFlipped
      ? frameView.bounds.minY
      : frameView.bounds.maxY - height
    if titleBarContainer.frame != titleBarFrame {
      titleBarContainer.frame = titleBarFrame
    }

    var buttonContainerFrame = buttonContainer.frame
    buttonContainerFrame.origin.y = 0
    buttonContainerFrame.size.height = height
    if buttonContainer.frame != buttonContainerFrame {
      buttonContainer.frame = buttonContainerFrame
    }

    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = standardWindowButton(type) else { continue }
      var buttonFrame = button.frame
      buttonFrame.origin.y = (height - buttonFrame.height) / 2
      if button.frame != buttonFrame {
        button.frame = buttonFrame
      }
    }
  }
}
