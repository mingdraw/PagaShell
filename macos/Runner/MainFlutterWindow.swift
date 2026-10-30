import Cocoa
import FlutterMacOS
import Darwin
import Security
import SystemConfiguration

class MainFlutterWindow: NSWindow {
  private var customTitleBarHeight: CGFloat?
  private var windowChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?
  private var clipboardChannel: FlutterMethodChannel?
  private var systemProxyChannel: FlutterMethodChannel?
  private let systemProxy = MacSystemProxy()
  private var headerMouseDownEvent: NSEvent?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    let proxy = FlutterMethodChannel(
      name: "pagashell/system_proxy",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    systemProxyChannel = proxy
    proxy.setMethodCallHandler { [weak self] call, result in
      self?.systemProxy.handle(call, result: result)
    }

    let clipboard = FlutterMethodChannel(
      name: "pagashell/clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    clipboardChannel = clipboard
    clipboard.setMethodCallHandler { call, result in
      let pasteboard = NSPasteboard.general
      let args = call.arguments as? [String: Any] ?? [:]
      if call.method == "read" {
        let change = String(pasteboard.changeCount)
        if args["afterChangeId"] as? String == change {
          result(nil)
          return
        }
        let urls = pasteboard.readObjects(
          forClasses: [NSURL.self],
          options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let paths = urls.filter { $0.isFileURL }.map { $0.path }
        guard paths.count <= 4096 else {
          result(FlutterError(code: "clipboard_limit", message: "Too many clipboard files", details: nil))
          return
        }
        let text = paths.isEmpty ? pasteboard.string(forType: .string) : nil
        guard (text?.utf8.count ?? 0) <= 16 * 1024 * 1024 else {
          result(FlutterError(code: "clipboard_limit", message: "Clipboard text too large", details: nil))
          return
        }
        result(["changeId": change, "text": text as Any? ?? NSNull(), "files": paths])
        return
      }
      if call.method == "write" {
        guard args["expectedChangeId"] as? String == String(pasteboard.changeCount) else {
          result(nil)
          return
        }
        let paths = args["files"] as? [String] ?? []
        let text = args["text"] as? String
        guard paths.count <= 4096, (text?.utf8.count ?? 0) <= 16 * 1024 * 1024,
              paths.allSatisfy({ ($0 as NSString).isAbsolutePath }) else {
          result(FlutterError(code: "clipboard_invalid", message: "Invalid clipboard content", details: nil))
          return
        }
        pasteboard.clearContents()
        var ok = true
        if !paths.isEmpty {
          ok = pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        } else if let text = text {
          ok = pasteboard.setString(text, forType: .string)
        }
        if ok {
          result(String(pasteboard.changeCount))
        } else {
          result(FlutterError(code: "clipboard_write", message: "Clipboard write failed", details: nil))
        }
        return
      }
      result(FlutterMethodNotImplemented)
    }

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

/// SystemConfiguration serializes commits with other network preference writers.
/// Snapshots remain in memory and are restored only while our values still match.
private final class MacSystemProxy {
  private enum Failure: Error { case conflict, permission, unavailable }
  private struct Snapshot {
    let serviceID: String
    let before: [String: Any]?
    let installed: [String: Any]
  }
  private let queue = DispatchQueue(label: "pagashell.system-proxy")
  private var owner: String?
  private var snapshots: [Snapshot] = []
  private var authorization: AuthorizationRef?
  private var preferences: SCPreferences?
  private static let enableKeys = [
    "HTTPEnable", "HTTPSEnable", "SOCKSEnable", "FTPEnable", "GopherEnable", "RTSPEnable",
    "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable",
  ]
  private static let managedGroups = [
    ["HTTPEnable", "HTTPProxy", "HTTPPort"],
    ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"],
    ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"],
    ["FTPEnable"], ["GopherEnable"], ["RTSPEnable"],
    ["ProxyAutoConfigEnable"], ["ProxyAutoDiscoveryEnable"],
    ["ExceptionsList"], ["ExcludeSimpleHostnames"],
  ]

  private func same(_ first: Any?, _ second: Any?) -> Bool {
    NSDictionary(dictionary: ["value": first ?? NSNull()]).isEqual(to: ["value": second ?? NSNull()])
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let id = args["owner"] as? String,
          call.method == "enable" || call.method == "restore" else {
      result(FlutterMethodNotImplemented)
      return
    }
    queue.async {
      do {
        if call.method == "enable" {
          let ports = ["HTTP": args["httpPort"] as? Int ?? 0,
                       "HTTPS": args["httpsPort"] as? Int ?? 0,
                       "SOCKS": args["socksPort"] as? Int ?? 0]
          guard ports.values.allSatisfy({ (0...65535).contains($0) }), ports.values.contains(where: { $0 > 0 }) else {
            throw Failure.unavailable
          }
          try self.enable(id, ports: ports)
        } else {
          try self.restore(id)
        }
        DispatchQueue.main.async { result(nil) }
      } catch {
        let code: String
        switch error {
        case Failure.conflict: code = "proxy_conflict"
        case Failure.permission: code = "proxy_permission"
        default: code = "proxy_failed"
        }
        // Never return PAC URLs, credentials or the contents of a proxy snapshot.
        DispatchQueue.main.async { result(FlutterError(code: code, message: "System proxy operation failed", details: nil)) }
      }
    }
  }

  private func hasProxy(_ values: [String: Any]) -> Bool {
    if Self.enableKeys.contains(where: { (values[$0] as? NSNumber)?.boolValue == true }) { return true }
    if let scoped = values["__SCOPED__"] as? [String: [String: Any]], scoped.values.contains(where: hasProxy) { return true }
    if let supplemental = values["__SUPPLEMENTAL__"] as? [[String: Any]], supplemental.contains(where: hasProxy) { return true }
    return false
  }

  private func activeServices(_ prefs: SCPreferences) throws -> [SCNetworkService] {
    guard let store = SCDynamicStoreCreate(nil, "PagaShell" as CFString, nil, nil),
          let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw Failure.unavailable }
    var primary = Set<String>()
    for family in ["IPv4", "IPv6"] {
      if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
         let id = state["PrimaryService"] as? String { primary.insert(id) }
    }
    let services = all.filter { service in
      guard SCNetworkServiceGetEnabled(service), let id = SCNetworkServiceGetServiceID(service) else { return false }
      return primary.contains(id as String)
    }
    guard !services.isEmpty else { throw Failure.unavailable }
    if let effective = SCDynamicStoreCopyProxies(store) as? [String: Any], hasProxy(effective) { throw Failure.conflict }
    return services
  }

  private func authorizedPreferences() throws -> SCPreferences {
    var auth: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth = auth else { throw Failure.permission }
    var status: OSStatus = errAuthorizationDenied
    "system.preferences.network".withCString { name in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      status = withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        return AuthorizationCopyRights(auth, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
      }
    }
    guard status == errAuthorizationSuccess,
          let prefs = SCPreferencesCreateWithAuthorization(nil, "PagaShell" as CFString, nil, auth) else {
      AuthorizationFree(auth, [])
      throw Failure.permission
    }
    authorization = auth
    return prefs
  }

  private func enable(_ id: String, ports: [String: Int]) throws {
    guard owner == nil else { throw Failure.conflict }
    guard let readOnly = SCPreferencesCreate(nil, "PagaShell" as CFString, nil) else { throw Failure.unavailable }
    // Avoid prompting for authorization when another proxy is already active.
    let initialServices = try activeServices(readOnly)
    for service in initialServices {
      if let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
         let values = SCNetworkProtocolGetConfiguration(proto) as? [String: Any], hasProxy(values) { throw Failure.conflict }
    }
    let prefs = try authorizedPreferences()
    preferences = prefs
    SCPreferencesSynchronize(prefs)
    guard SCPreferencesLock(prefs, false) else { clear(); throw Failure.unavailable }
    defer { SCPreferencesUnlock(prefs) }
    SCPreferencesSynchronize(prefs)
    let services: [SCNetworkService]
    do { services = try activeServices(prefs) } catch { clear(); throw error }
    var changes: [(SCNetworkProtocol, Snapshot)] = []
    for service in services {
      guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
            let serviceID = SCNetworkServiceGetServiceID(service) else { clear(); throw Failure.unavailable }
      let before = SCNetworkProtocolGetConfiguration(proto) as? [String: Any]
      if let before = before, hasProxy(before) { clear(); throw Failure.conflict }
      var installed = before ?? [:]
      for key in Self.enableKeys { installed[key] = 0 }
      installed["ExceptionsList"] = [String]()
      installed["ExcludeSimpleHostnames"] = 0
      for (scheme, port) in ports where port > 0 {
        installed["\(scheme)Enable"] = 1
        installed["\(scheme)Proxy"] = "127.0.0.1"
        installed["\(scheme)Port"] = port
      }
      changes.append((proto, Snapshot(serviceID: serviceID as String, before: before, installed: installed)))
    }
    owner = id
    snapshots = changes.map { $0.1 }
    for (proto, snapshot) in changes {
      guard SCNetworkProtocolSetConfiguration(proto, snapshot.installed as CFDictionary) else { throw Failure.unavailable }
    }
    guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw Failure.unavailable }
  }

  private func restore(_ id: String) throws {
    guard owner == id, let prefs = preferences else { return }
    SCPreferencesSynchronize(prefs)
    guard SCPreferencesLock(prefs, false) else { throw Failure.unavailable }
    defer { SCPreferencesUnlock(prefs) }
    SCPreferencesSynchronize(prefs)
    var apply = false
    for snapshot in snapshots {
      // Deleted services need no restoration; switched networks retain their own settings.
      guard let service = SCNetworkServiceCopy(prefs, snapshot.serviceID as CFString),
            let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
      let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any]
      var restored = current ?? [:]
      for group in Self.managedGroups {
        if group.allSatisfy({ same(current?[$0], snapshot.installed[$0]) }) {
          for key in group where !same(snapshot.before?[key], snapshot.installed[key]) {
            restored[key] = snapshot.before?[key]
            apply = true
          }
        } else if group.allSatisfy({ same(current?[$0], snapshot.before?[$0]) }) {
          // Retry ApplyChanges after a previously failed restoration.
          apply = true
        }
      }
      if !NSDictionary(dictionary: restored).isEqual(to: current ?? [:]) {
        let configuration: CFDictionary? = restored.isEmpty && snapshot.before == nil ? nil : restored as CFDictionary
        guard SCNetworkProtocolSetConfiguration(proto, configuration) else { throw Failure.unavailable }
      }
      // A changed protocol belongs to the other app. Preserve it, along with
      // unrelated keys, while disabling only protocols that are still ours.
    }
    if apply && (!SCPreferencesCommitChanges(prefs) || !SCPreferencesApplyChanges(prefs)) { throw Failure.unavailable }
    clear()
  }

  private func clear() {
    owner = nil
    snapshots = []
    preferences = nil
    if let authorization = authorization { AuthorizationFree(authorization, []) }
    authorization = nil
  }
}
