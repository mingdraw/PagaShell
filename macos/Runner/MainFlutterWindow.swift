import CFNetwork
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
  private var trayChannel: FlutterMethodChannel?
  private var rdpTextures: MacRdpTextureRegistry?
  private let systemProxy = MacSystemProxy()
  private var systemTray: MacSystemTray?
  private var headerMouseDownEvent: NSEvent?
  private(set) var isHiddenInTray = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    rdpTextures = MacRdpTextureRegistry(controller: flutterViewController)

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
      if call.method == "showWindow" {
        self?.showWindowFromTray()
        result(nil)
        return
      }
      if call.method == "hideWindow" {
        self?.hideWindowToTray()
        result(nil)
        return
      }
      if call.method == "destroyWindow" {
        self?.destroyWindowForExit()
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

    let tray = FlutterMethodChannel(
      name: "pagashell/tray",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    trayChannel = tray
    let trayManager = MacSystemTray(channel: tray)
    systemTray = trayManager
    tray.setMethodCallHandler { [weak trayManager] call, result in
      trayManager?.handle(call, result: result)
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

  func showWindowFromTray() {
    isHiddenInTray = false
    if isMiniaturized {
      deminiaturize(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    orderFrontRegardless()
  }

  func hideWindowToTray() {
    isHiddenInTray = true
    orderOut(nil)
  }

  func destroyWindowForExit() {
    isHiddenInTray = false
    cleanupTray()
    DispatchQueue.main.async {
      NSApp.terminate(nil)
    }
  }

  func reopenFromDock() {
    showWindowFromTray()
    windowChannel?.invokeMethod("windowReopened", arguments: nil)
  }

  func cleanupTray() {
    isHiddenInTray = false
    systemTray?.dispose()
  }

  func cleanupRdpTextures() {
    rdpTextures?.close()
    rdpTextures = nil
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
  private enum Failure: Error { case conflict, pacUnsupported, chainLoop, permission, unavailable }
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
    if call.method == "resolve" {
      guard let args = call.arguments as? [String: Any],
            let rawUrl = args["url"] as? String,
            let url = URL(string: rawUrl) else {
        result(FlutterError(code: "proxy_failed", message: "Invalid proxy lookup request", details: nil))
        return
      }
      queue.async {
        let resolved = self.resolve(url: url)
        DispatchQueue.main.async { result(resolved) }
      }
      return
    }
    if call.method == "inspectUpstream" {
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "proxy_failed", message: "Invalid proxy request", details: nil))
        return
      }
      queue.async {
        do {
          let ports = ["HTTP": args["httpPort"] as? Int ?? 0,
                       "HTTPS": args["httpsPort"] as? Int ?? 0,
                       "SOCKS": args["socksPort"] as? Int ?? 0]
          guard ports.values.allSatisfy({ (0...65535).contains($0) }), ports.values.contains(where: { $0 > 0 }) else {
            throw Failure.unavailable
          }
          let chainExisting = args["chainExisting"] as? Bool ?? false
          let upstream = try self.inspectUpstream(ports: ports, chainExisting: chainExisting)
          DispatchQueue.main.async { result(upstream) }
        } catch {
          DispatchQueue.main.async { result(self.flutterError(for: error)) }
        }
      }
      return
    }
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
          let chainExisting = args["chainExisting"] as? Bool ?? false
          let upstream = try self.enable(id, ports: ports, chainExisting: chainExisting)
          DispatchQueue.main.async { result(upstream) }
        } else {
          try self.restore(id)
          DispatchQueue.main.async { result(nil) }
        }
      } catch {
        DispatchQueue.main.async { result(self.flutterError(for: error)) }
      }
    }
  }

  private func flutterError(for error: Error) -> FlutterError {
    let code: String
    switch error {
    case Failure.conflict: code = "proxy_conflict"
    case Failure.pacUnsupported: code = "proxy_chain_pac_unsupported"
    case Failure.chainLoop: code = "proxy_chain_loop"
    case Failure.permission: code = "proxy_permission"
    default: code = "proxy_failed"
    }
    // Never return PAC URLs, credentials or the contents of a proxy snapshot.
    return FlutterError(code: code, message: "System proxy operation failed", details: nil)
  }

  private func isEnabled(_ values: [String: Any], _ key: String) -> Bool {
    (values[key] as? NSNumber)?.boolValue == true
  }

  private func hasProxy(_ values: [String: Any]) -> Bool {
    if Self.enableKeys.contains(where: { isEnabled(values, $0) }) { return true }
    if let scoped = values["__SCOPED__"] as? [String: [String: Any]], scoped.values.contains(where: hasProxy) { return true }
    if let supplemental = values["__SUPPLEMENTAL__"] as? [[String: Any]], supplemental.contains(where: hasProxy) { return true }
    return false
  }

  private func isLoopbackHost(_ rawHost: String) -> Bool {
    var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    while host.hasSuffix(".") { host.removeLast() }
    if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4, parts.first == "127",
       parts.allSatisfy({ part in
         guard let value = Int(part), (0...255).contains(value) else { return false }
         return true
       }) {
      return true
    }
    return false
  }

  private func extractUpstream(from values: [String: Any], localPorts: Set<Int>, chainExisting: Bool) throws -> [String: Any]? {
    if !chainExisting {
      if hasProxy(values) { throw Failure.conflict }
      return nil
    }
    if isEnabled(values, "ProxyAutoConfigEnable") { throw Failure.pacUnsupported }
    for unsupported in ["FTPEnable", "GopherEnable", "RTSPEnable"] {
      if isEnabled(values, unsupported) { throw Failure.conflict }
    }
    var result: [String: Any] = [:]
    func capture(enableKey: String, hostKey: String, portKey: String, outputKey: String, protocolName: String) throws {
      guard isEnabled(values, enableKey) else { return }
      guard let rawHost = values[hostKey] as? String,
            let port = (values[portKey] as? NSNumber)?.intValue,
            (1...65535).contains(port) else {
        throw Failure.conflict
      }
      let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !host.isEmpty, !host.contains("@") else { throw Failure.conflict }
      if isLoopbackHost(host) && localPorts.contains(port) {
        throw Failure.chainLoop
      }
      result[outputKey] = ["protocol": protocolName, "host": host, "port": port]
    }
    try capture(enableKey: "HTTPEnable", hostKey: "HTTPProxy", portKey: "HTTPPort", outputKey: "http", protocolName: "http")
    try capture(enableKey: "HTTPSEnable", hostKey: "HTTPSProxy", portKey: "HTTPSPort", outputKey: "https", protocolName: "http")
    try capture(enableKey: "SOCKSEnable", hostKey: "SOCKSProxy", portKey: "SOCKSPort", outputKey: "socks5", protocolName: "socks5")
    if result.isEmpty { return nil }
    let exceptions = (values["ExceptionsList"] as? [String] ?? [])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    result["bypass"] = exceptions
    result["excludeSimpleHostnames"] = isEnabled(values, "ExcludeSimpleHostnames")
    return result
  }

  private func activeServices(_ prefs: SCPreferences, chainExisting: Bool) throws -> [SCNetworkService] {
    guard let store = SCDynamicStoreCreate(nil, "PagaShell" as CFString, nil, nil),
          let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw Failure.unavailable }
    var primary = Set<String>()
    var primaryInterfaces = Set<String>()
    for family in ["IPv4", "IPv6"] {
      if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any] {
        if let id = state["PrimaryService"] as? String { primary.insert(id) }
        if let iface = state["PrimaryInterface"] as? String { primaryInterfaces.insert(iface) }
      }
    }
    let services = all.filter { service in
      guard SCNetworkServiceGetEnabled(service), let id = SCNetworkServiceGetServiceID(service) else { return false }
      return primary.contains(id as String)
    }
    guard !services.isEmpty else { throw Failure.unavailable }
    if let effective = SCDynamicStoreCopyProxies(store) as? [String: Any] {
      if !chainExisting {
        if hasProxy(effective) { throw Failure.conflict }
      } else {
        if isEnabled(effective, "ProxyAutoConfigEnable") { throw Failure.pacUnsupported }
        if let supplemental = effective["__SUPPLEMENTAL__"] as? [[String: Any]],
           supplemental.contains(where: hasProxy) {
          throw Failure.conflict
        }
        if let scoped = effective["__SCOPED__"] as? [String: [String: Any]] {
          for (iface, dict) in scoped {
            if isEnabled(dict, "ProxyAutoConfigEnable") { throw Failure.pacUnsupported }
            if !primaryInterfaces.contains(iface) && hasProxy(dict) {
              throw Failure.conflict
            }
          }
        }
      }
    }
    return services
  }

  private func inspectUpstream(ports: [String: Int], chainExisting: Bool) throws -> [String: Any]? {
    guard owner == nil else { throw Failure.conflict }
    guard let readOnly = SCPreferencesCreate(nil, "PagaShell" as CFString, nil) else { throw Failure.unavailable }
    let localPorts = Set(ports.values.filter { $0 > 0 })
    let services = try activeServices(readOnly, chainExisting: chainExisting)
    var captured: [String: Any]?
    for service in services {
      if let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
         let values = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] {
        if let upstream = try extractUpstream(from: values, localPorts: localPorts, chainExisting: chainExisting),
           captured == nil {
          captured = upstream
        }
      }
    }
    return captured
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

  private func enable(_ id: String, ports: [String: Int], chainExisting: Bool) throws -> [String: Any]? {
    guard owner == nil else { throw Failure.conflict }
    let localPorts = Set(ports.values.filter { $0 > 0 })
    // Avoid prompting for authorization when an unsupported conflict exists.
    _ = try inspectUpstream(ports: ports, chainExisting: chainExisting)
    let prefs = try authorizedPreferences()
    preferences = prefs
    SCPreferencesSynchronize(prefs)
    guard SCPreferencesLock(prefs, false) else { clear(); throw Failure.unavailable }
    defer { SCPreferencesUnlock(prefs) }
    SCPreferencesSynchronize(prefs)
    let services: [SCNetworkService]
    do { services = try activeServices(prefs, chainExisting: chainExisting) } catch { clear(); throw error }
    var changes: [(SCNetworkProtocol, Snapshot)] = []
    var captured: [String: Any]?
    for service in services {
      guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
            let serviceID = SCNetworkServiceGetServiceID(service) else { clear(); throw Failure.unavailable }
      let before = SCNetworkProtocolGetConfiguration(proto) as? [String: Any]
      if let before = before {
        do {
          if let upstream = try extractUpstream(from: before, localPorts: localPorts, chainExisting: chainExisting),
             captured == nil {
            captured = upstream
          }
        } catch {
          clear()
          throw error
        }
      }
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
    return captured
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

  private func resolve(url: URL) -> [String: Any]? {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
          let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] else {
      return nil
    }
    for proxy in proxies {
      guard let type = proxy[kCFProxyTypeKey as String] as? String else { continue }
      if type == (kCFProxyTypeNone as String) { return nil }
      if type == (kCFProxyTypeAutoConfigurationURL as String),
         let pacURL = proxy[kCFProxyAutoConfigurationURLKey as String] as? URL,
         let pacProxy = resolvePAC(url: url, pacURL: pacURL) {
        return pacProxy
      }
      if let mapped = mapProxyEntry(proxy, type: type) { return mapped }
    }
    return nil
  }

  private func mapProxyEntry(_ proxy: [String: Any], type: String) -> [String: Any]? {
    let protocolName: String
    if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) {
      // macOS Secure Web Proxy (HTTPS) is an HTTP CONNECT proxy for https:// targets.
      protocolName = "http"
    } else if type == (kCFProxyTypeSOCKS as String) {
      protocolName = "socks5"
    } else {
      return nil
    }
    guard let host = proxy[kCFProxyHostNameKey as String] as? String,
          !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let port = proxy[kCFProxyPortNumberKey as String] as? Int,
          (1...65535).contains(port) else {
      return nil
    }
    return ["protocol": protocolName, "host": host, "port": port]
  }

  private final class PacBox {
    var proxies: [[String: Any]]?
    let runLoop: CFRunLoop
    init(runLoop: CFRunLoop) { self.runLoop = runLoop }
  }

  private func resolvePAC(url: URL, pacURL: URL) -> [String: Any]? {
    let runLoop = CFRunLoopGetCurrent()!
    let box = PacBox(runLoop: runLoop)
    let boxPtr = Unmanaged.passRetained(box).toOpaque()
    var context = CFStreamClientContext(
      version: 0,
      info: boxPtr,
      retain: { info in
        guard let info = info else { return nil }
        _ = Unmanaged<PacBox>.fromOpaque(info).retain()
        return info
      },
      release: { info in
        guard let info = info else { return }
        Unmanaged<PacBox>.fromOpaque(info).release()
      },
      copyDescription: nil
    )
    let callback: CFProxyAutoConfigurationResultCallback = { client, proxyList, _ in
      let box = Unmanaged<PacBox>.fromOpaque(client).takeUnretainedValue()
      if let list = proxyList as? [[String: Any]] {
        box.proxies = list
      }
      CFRunLoopStop(box.runLoop)
    }
    let source = CFNetworkExecuteProxyAutoConfigurationURL(
      pacURL as CFURL,
      url as CFURL,
      callback,
      &context
    )
    Unmanaged<PacBox>.fromOpaque(boxPtr).release()
    let mode = CFRunLoopMode("pagashell.pac" as CFString)
    CFRunLoopAddSource(runLoop, source, mode)
    CFRunLoopRunInMode(mode, 2.0, false)
    CFRunLoopRemoveSource(runLoop, source, mode)
    CFRunLoopSourceInvalidate(source)
    guard let proxies = box.proxies else { return nil }
    for proxy in proxies {
      guard let type = proxy[kCFProxyTypeKey as String] as? String else { continue }
      if type == (kCFProxyTypeNone as String) { return nil }
      if let mapped = mapProxyEntry(proxy, type: type) { return mapped }
    }
    return nil
  }
}

/// macOS 菜单栏系统托盘与后台 App Nap 抑制管理。
private final class MacSystemTray: NSObject, NSMenuDelegate {
  private static let iconSize = NSSize(width: 22, height: 18)

  private final class ServiceBadgeView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  private weak var channel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private weak var serviceBadge: NSImageView?
  private var menu = NSMenu()
  private var menuOpen = false
  private var pendingItems: [[String: Any]]?
  private var backgroundActivity: NSObjectProtocol?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
  }

  deinit {
    dispose()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      initialize()
      result(nil)
    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "tray_invalid", message: "Invalid tray payload", details: nil))
        return
      }
      let tooltip = args["tooltip"] as? String ?? "PagaShell"
      let items = args["items"] as? [[String: Any]] ?? []
      let hasActiveServices = args["hasActiveServices"] as? Bool ?? false
      update(tooltip: tooltip, items: items, hasActiveServices: hasActiveServices)
      result(nil)
    case "setBackgroundMode":
      let args = call.arguments as? [String: Any] ?? [:]
      let active = args["active"] as? Bool ?? false
      setBackgroundMode(active)
      result(nil)
    case "dispose":
      dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initialize() {
    if statusItem != nil { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = makeTrayIcon()
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.toolTip = "PagaShell"
      installServiceBadge(on: button)
    }
    item.menu = menu
    statusItem = item
  }

  private func makeTrayIcon() -> NSImage? {
    if let template = NSImage(named: NSImage.Name("TrayIcon"))?.copy() as? NSImage {
      template.size = Self.iconSize
      template.isTemplate = true
      return template
    }
    guard let source = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage,
          let icon = source.copy() as? NSImage else {
      return nil
    }
    icon.size = NSSize(width: 18, height: 18)
    icon.isTemplate = false
    return icon
  }

  private func installServiceBadge(on button: NSStatusBarButton) {
    guard let image = NSImage(named: NSImage.Name("TrayServiceBadge")) else { return }
    // Keep the mark as a system-tinted template and draw the green dot above it.
    let badge = ServiceBadgeView(frame: .zero)
    badge.image = image
    badge.imageScaling = .scaleNone
    badge.isHidden = true
    badge.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(badge)
    NSLayoutConstraint.activate([
      badge.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      badge.widthAnchor.constraint(equalToConstant: Self.iconSize.width),
      badge.heightAnchor.constraint(equalToConstant: Self.iconSize.height),
    ])
    serviceBadge = badge
  }

  private func update(tooltip: String, items: [[String: Any]], hasActiveServices: Bool) {
    initialize()
    statusItem?.button?.toolTip = tooltip
    serviceBadge?.isHidden = !hasActiveServices
    if menuOpen {
      pendingItems = items
      return
    }
    pendingItems = nil
    rebuildMenu(menu, from: items)
  }

  private func rebuildMenu(_ target: NSMenu, from items: [[String: Any]]) {
    target.removeAllItems()
    for raw in items {
      target.addItem(buildMenuItem(raw))
    }
  }

  private func buildMenuItem(_ raw: [String: Any]) -> NSMenuItem {
    let kind = raw["kind"] as? String ?? "normal"
    if kind == "separator" {
      return NSMenuItem.separator()
    }
    let label = raw["label"] as? String ?? ""
    let enabled = raw["enabled"] as? Bool ?? true
    let checked = raw["checked"] as? Bool ?? false
    let id = raw["id"] as? String

    if kind == "submenu" {
      let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
      item.isEnabled = enabled
      let submenu = NSMenu(title: label)
      submenu.autoenablesItems = false
      let children = raw["children"] as? [[String: Any]] ?? []
      rebuildMenu(submenu, from: children)
      item.submenu = submenu
      return item
    }

    let clickable = enabled && id != nil
    let item = NSMenuItem(
      title: label,
      action: clickable ? #selector(onMenuItemClicked(_:)) : nil,
      keyEquivalent: ""
    )
    item.isEnabled = enabled
    if kind == "checkbox" {
      item.state = checked ? .on : .off
    }
    if clickable {
      item.target = self
      item.representedObject = id
    }
    return item
  }

  @objc private func onMenuItemClicked(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, !id.isEmpty else { return }
    channel?.invokeMethod("onMenuItemSelected", arguments: ["id": id])
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu === self.menu {
      menuOpen = true
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    if menu === self.menu {
      menuOpen = false
      if let items = pendingItems {
        pendingItems = nil
        rebuildMenu(self.menu, from: items)
      }
    }
  }

  private func setBackgroundMode(_ active: Bool) {
    if active {
      if backgroundActivity == nil {
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
          options: .userInitiatedAllowingIdleSystemSleep,
          reason: "Keep PagaShell background services active"
        )
      }
    } else if let activity = backgroundActivity {
      ProcessInfo.processInfo.endActivity(activity)
      backgroundActivity = nil
    }
  }

  func dispose() {
    setBackgroundMode(false)
    pendingItems = nil
    menuOpen = false
    serviceBadge = nil
    if let item = statusItem {
      item.menu = nil
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
    menu.removeAllItems()
  }
}
