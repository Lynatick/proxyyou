import Cocoa
import FlutterMacOS
import LaunchAtLogin
import Network
import Security
import SystemConfiguration
import WebKit
import window_manager

class MainFlutterWindow: NSWindow {
  private var playbackProbe: YoutubePlaybackProbe?
  override func awakeFromNib() {
    // Authorize before starting Flutter, including recovery after an interrupted session.
    NSApp.activate(ignoringOtherApps: true)
    do {
      try MacSystemProxy.shared.prepareForLaunch()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Системный прокси недоступен"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    MacSystemProxy.shared.attach(messenger: flutterViewController.engine.binaryMessenger)
    playbackProbe = YoutubePlaybackProbe(messenger: flutterViewController.engine.binaryMessenger)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Add FlutterMethodChannel platform code
    FlutterMethodChannel(
      name: "launch_at_startup", binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    .setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "launchAtStartupIsEnabled":
        result(LaunchAtLogin.isEnabled)
      case "launchAtStartupSetEnabled":
        if let arguments = call.arguments as? [String: Any] {
          LaunchAtLogin.isEnabled = arguments["setEnabledValue"] as! Bool
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    //
    FlutterMethodChannel(name: "dev.proxyyou/applications", binaryMessenger: flutterViewController.engine.binaryMessenger)
      .setMethodCallHandler { call, result in
        guard call.method == "list" else { result(FlutterMethodNotImplemented); return }
        DispatchQueue.global(qos: .userInitiated).async {
          let apps = MacApplicationCatalog.list()
          DispatchQueue.main.async { result(apps) }
        }
      }
    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // window manager hidden at launch
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

// A separate nonpersistent WebKit store prevents cached video from proving connectivity.
final class YoutubePlaybackProbe: NSObject, WKNavigationDelegate, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var pending: FlutterResult?
  private var session: String?
  private var window: NSWindow?
  private var webView: WKWebView?
  private var poll: Timer?
  private var deadline: Timer?
  private var evaluating = false
  private var script = ""
  private var videoID = ""
  private var acceptedProof: [String: Any]?
  private var closingPlayer = false

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    channel = FlutterMethodChannel(name: "dev.proxyyou/playback", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "cancel" {
        if let args = call.arguments as? [String: Any], args["session"] as? String == self.session {
          self.finish(["status": "cancelled"])
        }
        result(nil)
      } else if call.method == "start" {
        self.start(call.arguments as? [String: Any], result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard #available(macOS 14.0, *) else {
      result(["status": "unsupported"])
      return
    }
    guard let args = args, let port = args["port"] as? Int, (1...65535).contains(port),
      let id = args["videoId"] as? String,
      id.range(of: "^[a-zA-Z0-9_-]{11}$", options: .regularExpression) != nil,
      let source = args["script"] as? String, let token = args["session"] as? String
    else {
      result(["status": "failed"])
      return
    }
    finish(["status": "cancelled"])
    pending = result
    session = token
    videoID = id
    let sessionJSON = String(data: (try? JSONSerialization.data(withJSONObject: [token])) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    script = "window.__proxyyouExpectedSession = \(sessionJSON)[0];\nwindow.__proxyyouExpectedId = '\(id)';\n" + source
    let store = WKWebsiteDataStore.nonPersistent()
    let endpoint = NWEndpoint.hostPort(
      host: .ipv4(IPv4Address("127.0.0.1")!), port: NWEndpoint.Port(rawValue: UInt16(port))!)
    var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
    proxy.allowFailover = false
    store.proxyConfigurations = [proxy]
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let browser = WKWebView(frame: .zero, configuration: configuration)
    browser.navigationDelegate = self
    browser.customUserAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
    webView = browser
    let playerWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    playerWindow.title = "ProxyYou — нажмите Play для проверки видео"
    playerWindow.isReleasedWhenClosed = false
    playerWindow.delegate = self
    playerWindow.contentView = browser
    playerWindow.center()
    playerWindow.makeKeyAndOrderFront(nil)
    window = playerWindow
    deadline = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
      self?.finish(["status": "failed"])
    }
    poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.sample()
    }
    if let timer = poll { RunLoop.main.add(timer, forMode: .common) }
    browser.load(
      URLRequest(
        url: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
        cachePolicy: .reloadIgnoringLocalCacheData))
  }

  private func sample() {
    guard !evaluating, pending != nil, let browser = webView else { return }
    evaluating = true
    let token = session
    browser.evaluateJavaScript(script) { [weak self] value, _ in
      guard let self = self, self.session == token else { return }
      self.evaluating = false
      guard let proof = value as? [String: Any] else { return }
      if proof["status"] as? String == "unsupported" {
        self.finish(["status": "unsupported"])
        return
      }
      self.accept(proof)
    }
  }

  private func accept(_ proof: [String: Any]) {
    guard proof["status"] as? String == "passed", proof["videoId"] as? String == videoID,
      proof["session"] as? String == session,
      let seconds = proof["seconds"] as? Double, seconds >= 12,
      let frames = proof["frames"] as? Int, frames >= 10
    else { return }
    acceptedProof = proof
    poll?.invalidate()
    poll = nil
    if !closingPlayer {
      deadline?.invalidate()
      deadline = nil
    }
    // Publish once, leaving the video open for the user to finish watching.
    let result = pending
    pending = nil
    result?(proof)
  }

  private func closePlayer() {
    guard !closingPlayer else { return }
    guard acceptedProof == nil, let browser = webView, let token = session else {
      finish(["status": "cancelled"])
      return
    }
    closingPlayer = true
    poll?.invalidate()
    poll = nil
    deadline?.invalidate()
    deadline = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
      guard self?.session == token else { return }
      self?.finish(["status": "cancelled"])
    }
    // Read the latched proof before destroying the page; a poll may still be in flight.
    browser.evaluateJavaScript(script) { [weak self] value, _ in
      guard let self = self, self.session == token else { return }
      if let proof = value as? [String: Any] { self.accept(proof) }
      self.finish(["status": "cancelled"])
    }
  }

  private func finish(_ response: [String: Any]) {
    let result = pending
    let finalResponse = acceptedProof ?? response
    acceptedProof = nil
    closingPlayer = false
    pending = nil
    session = nil
    poll?.invalidate()
    poll = nil
    deadline?.invalidate()
    deadline = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    window?.delegate = nil
    window?.close()
    window = nil
    evaluating = false
    result?(finalResponse)
  }

  func windowWillClose(_ notification: Notification) { closePlayer() }

  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url else {
      decisionHandler(.cancel)
      return
    }
    let host = url.host?.lowercased() ?? ""
    let allowed =
      url.scheme == "https"
      && (host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "consent.google.com")
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if (error as NSError).code != NSURLErrorCancelled { finish(["status": "failed"]) }
  }
}

// One privileged child per app process; its private pipe is the session capability.
final class MacSystemProxy {
  static let shared = MacSystemProxy()
  private var pipe: UnsafeMutablePointer<FILE>?
  private var attemptedAuthorization = false
  private let backupKey = "proxyyou.systemProxyBackup"
  private let portKey = "proxyyou.systemProxyPort"
  private var channel: FlutterMethodChannel?
  private let requests = DispatchQueue(label: "dev.proxyyou.system-proxy", qos: .userInitiated)

  private func failure(_ message: String) -> NSError {
    NSError(domain: "ProxyYou", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  func prepareForLaunch() throws {
    guard !attemptedAuthorization else { return }
    attemptedAuthorization = true
    guard let path = Bundle.main.path(forAuxiliaryExecutable: "ProxyYouProxyHelper") else {
      throw failure("В приложении отсутствует помощник системного прокси.")
    }
    var authorization: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
      let authorization = authorization
    else { throw failure("Не удалось подготовить запрос разрешения macOS.") }
    defer { AuthorizationFree(authorization, [.destroyRights]) }
    var communications: UnsafeMutablePointer<FILE>?
    // The local build uses Apple's legacy launch API; only this launch may show authorization UI.
    let status = path.withCString { executable in
      ProxyYouLaunchSessionHelper(authorization, executable, &communications)
    }
    guard status == errAuthorizationSuccess, let communications = communications else {
      throw failure(
        "Разрешение не получено. Для повторного запроса полностью закройте и снова откройте приложение. Можно использовать режим «Прокси»."
      )
    }
    pipe = communications
    let fd = fileno(communications)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let response = try readResponse()
    guard response["ready"] as? Bool == true else {
      closePipe()
      throw failure("Помощник системного прокси не запустился.")
    }
    // Recover interrupted sessions once, before Flutter starts. Reinitializing
    // the foreground core later must never restore a live connection's proxy.
    try restore()
  }

  func attach(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.proxyyou/system-proxy", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.requests.async {
        do {
          switch call.method {
          case "enable":
            guard let args = call.arguments as? [String: Any], let port = args["port"] as? Int,
              (1...65535).contains(port)
            else { throw self.failure("Неверный порт прокси.") }
            let response = try self.request(["command": "enable", "port": port])
            guard let backups = response["backups"] as? [String: Any] else {
              throw self.failure("Не удалось сохранить прежние сетевые настройки.")
            }
            UserDefaults.standard.set(backups, forKey: self.backupKey)
            UserDefaults.standard.set(port, forKey: self.portKey)
          case "restore": try self.restore()
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
            return
          }
          DispatchQueue.main.async { result(nil) }
        } catch {
          let message = error.localizedDescription
          DispatchQueue.main.async { result(FlutterError(code: "system_proxy", message: message, details: nil)) }
        }
      }
    }
  }

  private func closePipe() {
    if let pipe = pipe { fclose(pipe) }
    pipe = nil
  }

  private func readResponse() throws -> [String: Any] {
    guard let pipe = pipe else {
      throw failure(
        "Помощник системного прокси недоступен. Полностью закройте и снова откройте приложение.")
    }
    let fd = fileno(pipe)
    let deadline = Date().addingTimeInterval(15)
    var data = Data()
    var byte: UInt8 = 0
    while data.count <= 262144 {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
      guard remaining > 0 else {
        closePipe()
        throw failure("Помощник системного прокси не ответил вовремя. Повторите после перезапуска приложения.")
      }
      let polled = poll(&descriptor, 1, remaining)
      if polled < 0 && errno == EINTR { continue }
      let received = polled > 0 ? read(fd, &byte, 1) : -1
      if received < 0 && errno == EINTR { continue }
      guard polled > 0, received == 1 else {
        closePipe()
        throw failure(
          "Помощник системного прокси завершился или не ответил. Перезапустите приложение.")
      }
      if byte == 10 {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          closePipe()
          throw failure("Некорректный ответ помощника системного прокси.")
        }
        if response["ok"] as? Bool != true {
          // Preserve recovery data even when commit/apply only partially succeeds.
          if let backups = response["backups"] as? [String: Any], !backups.isEmpty,
            let port = response["port"] as? Int
          {
            UserDefaults.standard.set(backups, forKey: backupKey)
            UserDefaults.standard.set(port, forKey: portKey)
          }
          throw failure("Не удалось применить настройки системного прокси macOS.")
        }
        return response
      }
      data.append(byte)
    }
    closePipe()
    throw failure("Некорректный ответ помощника системного прокси.")
  }

  private func request(_ message: [String: Any]) throws -> [String: Any] {
    guard let pipe = pipe else {
      throw failure(
        "Разрешение на системный прокси отсутствует. Полностью закройте и снова откройте приложение."
      )
    }
    var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    data.append(10)
    let fd = fileno(pipe)
    let sent = data.withUnsafeBytes { buffer -> Bool in
      var offset = 0
      while offset < buffer.count {
        let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
    guard sent else {
      closePipe()
      throw failure("Соединение с помощником системного прокси прервано.")
    }
    return try readResponse()
  }

  func restore() throws {
    guard let backups = UserDefaults.standard.dictionary(forKey: backupKey), !backups.isEmpty else {
      return
    }
    let port = UserDefaults.standard.integer(forKey: portKey)
    _ = try request(["command": "restore", "backups": backups, "port": port])
    UserDefaults.standard.removeObject(forKey: backupKey)
    UserDefaults.standard.removeObject(forKey: portKey)
  }

  func finishSession() {
    requests.sync {
      if pipe != nil { _ = try? request(["command": "finish"]) }
      closePipe()
    }
  }
}


private enum MacApplicationCatalog {
  static func list() -> [[String: Any]] {
    let manager = FileManager.default
    let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    var apps: [[String: Any]] = []
    var seen = Set<String>()
    for root in roots {
      guard let enumerator = manager.enumerator(at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
      for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "app" else { continue }
        enumerator.skipDescendants()
        let path = url.resolvingSymlinksInPath().path
        guard seen.insert(path).inserted, let bundle = Bundle(url: url),
          bundle.bundleIdentifier != "dev.proxyyou.client", bundle.executableURL != nil else { continue }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
          ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
          ?? url.deletingPathExtension().lastPathComponent
        apps.append(["name": name, "path": path, "supported": bundle.bundleIdentifier != "com.apple.Safari"])
      }
    }
    return apps.sorted { ($0["name"] as! String).localizedStandardCompare($1["name"] as! String) == .orderedAscending }
  }
}
