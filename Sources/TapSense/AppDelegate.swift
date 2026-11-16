import AVFoundation
import AppKit
import TapEngine
import WebKit
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {
  private let window: NSWindow
  private let webView: WKWebView
  private let engine: Engine
  private var capture: AudioCapture?
  private var camera: HandCamera?
  private var screenWatcher: ScreenWatcher?
  private var started = false
  private var clicksWanted = true
  private var askedForTrust = false
  private var trustPoll: Task<Void, Never>?
  private var scrollRemainder = CGPoint.zero
  private let log = Logger(subsystem: "local.tapsense", category: "app")
  private var calibrating = false
  private var enteredFullScreen = false
  private var beginAfterFullScreen = false

  private var builtInScreen: NSScreen? { NSScreen.screens.first(where: \.isBuiltIn) ?? NSScreen.main }

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }

  override init() {
    engine = Engine(directory: URL.applicationSupportDirectory.appending(path: "TapSense"))
    webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMenu()

    window.title = ""
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(white: 0.047, alpha: 1)
    window.collectionBehavior = [.fullScreenPrimary]
    window.minSize = NSSize(width: 720, height: 480)
    window.delegate = self
    window.contentView = webView
    window.center()

    webView.configuration.userContentController.add(self, name: "app")
    webView.underPageBackgroundColor = window.backgroundColor
    if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ui") {
      webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    } else {
      webView.loadHTMLString("<body style='background:#0c0c0c;color:#ccc;font:13px monospace'>ui resources missing; build with Scripts/build-app.sh</body>", baseURL: nil)
    }

    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    capture?.stop()
    camera?.stop()
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let command = body["cmd"] as? String else { return }
    switch command {
    case "ready": start()
    case "calibrate": enterCalibration()
    case "cancel": Task { await engine.cancelCalibration() }
    case "closed": leaveCalibration()
    case "clear": Task { await engine.clearCalibration() }
    case "clicks": toggleClicks()
    default: break
    }
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    guard beginAfterFullScreen else { return }
    beginAfterFullScreen = false
    beginCalibration()
  }

  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    enteredFullScreen = false
    windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    guard calibrating else { return }
    calibrating = false
    enteredFullScreen = false
    Task { await engine.cancelCalibration() }
  }

  private func start() {
    guard !started else {
      Task { await engine.sendStatus() }
      refreshClicks()
      return
    }
    started = true
    refreshClicks()
    Task {
      for await output in engine.outputs {
        switch output {
        case .message(let json): deliver(json)
        case .click(let x, let y): click(x: x, y: y)
        case .scroll(let x, let y, let dx, let dy, let began): scroll(x: x, y: y, dx: dx, dy: dy, began: began)
        case .startRecording(let directory): camera?.startRecording(to: directory)
        case .stopRecording: camera?.stopRecording()
        }
      }
    }
    Task {
      if let screen = builtInScreen, let id = screen.displayID {
        await engine.setScreen(
          aspect: Float(screen.frame.width / screen.frame.height), widthMM: Float(CGDisplayScreenSize(id).width))
      }
      let arguments = CommandLine.arguments
      if let flag = arguments.firstIndex(of: "--record"), flag + 1 < arguments.count {
        await engine.record(to: URL(filePath: arguments[flag + 1]))
      }
      if arguments.contains("--capture-scroll") {
        await engine.capture([
          ("get ready", 4),
          ("TWO fingers: scroll up, down, left, right, lifting between strokes", 22),
          ("ONE finger: point and tap around as normal", 18),
          ("rest your hands, then type on the keyboard", 8),
        ])
      }
      async let audio: Void = runAudio()
      async let camera: Void = runCamera()
      async let screen: Void = runScreenCheck()
      _ = await (audio, camera, screen)
    }
  }

  private func runAudio() async {
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      deliver(#"{"type":"status","mic":"denied"}"#)
      return
    }
    guard let device = AudioInput.preferredDevice() else {
      deliver(#"{"type":"status","mic":"missing"}"#)
      return
    }
    do {
      let capture = AudioCapture(device: device)
      let audio = try capture.start()
      self.capture = capture
      await engine.run(audio: audio, device: device.name, sampleRate: device.sampleRate)
    } catch {
      deliver(#"{"type":"status","mic":"failed"}"#)
    }
  }

  private func runCamera() async {
    guard await AVCaptureDevice.requestAccess(for: .video) else {
      await engine.setCamera(state: "denied")
      return
    }
    while !Task.isCancelled {
      if let device = HandCamera.device(), let camera = try? HandCamera(device: device) {
        self.camera = camera
        camera.start()
        await engine.run(camera: camera.frames, name: camera.name)
        camera.stop()
        self.camera = nil
      } else {
        await engine.setCamera(state: "missing")
      }
      try? await Task.sleep(for: .seconds(2))
    }
  }

  private func runScreenCheck() async {
    guard let id = builtInScreen?.displayID, CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    else { return }
    let watcher = ScreenWatcher()
    guard (try? await watcher.start(displayID: id)) != nil else { return }
    screenWatcher = watcher
    await engine.run(screen: watcher.frames)
  }

  private func deliver(_ json: String) {
    webView.evaluateJavaScript("recv(\(json))", completionHandler: nil)
  }

  private func refreshClicks() {
    let trusted = AXIsProcessTrusted()
    deliver(#"{"type":"clicks","state":"\#(!clicksWanted ? "off" : trusted ? "on" : "blocked")"}"#)
    guard clicksWanted, !trusted, trustPoll == nil else { return }
    if !askedForTrust {
      askedForTrust = true
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    trustPoll = Task {
      while !Task.isCancelled, clicksWanted, !AXIsProcessTrusted() {
        try? await Task.sleep(for: .seconds(1))
      }
      trustPoll = nil
      refreshClicks()
    }
  }

  private func toggleClicks() {
    if clicksWanted, !AXIsProcessTrusted(),
      let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(settings)
      return
    }
    clicksWanted.toggle()
    refreshClicks()
  }

  private func click(x: Float, y: Float) {
    guard clicksWanted, !calibrating, AXIsProcessTrusted(), let id = builtInScreen?.displayID else { return }
    let bounds = CGDisplayBounds(id)
    let point = CGPoint(x: bounds.minX + CGFloat(x) * bounds.width, y: bounds.minY + CGFloat(y) * bounds.height)
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ type: CGEventType) {
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
      event?.setIntegerValueField(.mouseEventClickState, value: 1)
      event?.post(tap: .cghidEventTap)
    }
    post(.mouseMoved)
    post(.leftMouseDown)
    Task {
      try? await Task.sleep(for: .milliseconds(40))
      post(.leftMouseUp)
    }
    log.notice("clicked at \(point.x, format: .fixed(precision: 0)), \(point.y, format: .fixed(precision: 0))")
  }

  private func scroll(x: Float, y: Float, dx: Float, dy: Float, began: Bool) {
    guard clicksWanted, !calibrating, AXIsProcessTrusted(), let id = builtInScreen?.displayID else { return }
    let bounds = CGDisplayBounds(id)
    let source = CGEventSource(stateID: .hidSystemState)
    if began {
      scrollRemainder = .zero
      let point = CGPoint(
        x: bounds.minX + CGFloat(min(max(x, 0), 1)) * bounds.width,
        y: bounds.minY + CGFloat(min(max(y, 0), 1)) * bounds.height)
      CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    }
    scrollRemainder.x += CGFloat(dx) * bounds.width
    scrollRemainder.y += CGFloat(dy) * bounds.height
    let whole = CGPoint(x: scrollRemainder.x.rounded(.towardZero), y: scrollRemainder.y.rounded(.towardZero))
    guard whole != .zero else { return }
    scrollRemainder.x -= whole.x
    scrollRemainder.y -= whole.y
    CGEvent(
      scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(whole.y), wheel2: Int32(whole.x),
      wheel3: 0)?.post(tap: .cghidEventTap)
  }

  private func enterCalibration() {
    guard !calibrating else { return }
    calibrating = true
    if let builtIn = builtInScreen, window.screen != builtIn, !window.styleMask.contains(.fullScreen) {
      window.setFrame(builtIn.visibleFrame.insetBy(dx: 120, dy: 80), display: true)
    }
    if window.styleMask.contains(.fullScreen) {
      beginCalibration()
    } else {
      enteredFullScreen = true
      beginAfterFullScreen = true
      window.toggleFullScreen(nil)
    }
  }

  private func beginCalibration() {
    guard let frame = window.screen?.frame else { return }
    let view = window.convertToScreen(webView.convert(webView.bounds, to: nil))
    let viewport = Viewport(
      x: Float((view.minX - frame.minX) / frame.width), y: Float((frame.maxY - view.maxY) / frame.height),
      width: Float(view.width / frame.width), height: Float(view.height / frame.height))
    Task { await engine.beginCalibration(viewport: viewport) }
  }

  private func leaveCalibration() {
    guard calibrating else { return }
    calibrating = false
    guard enteredFullScreen else { return }
    enteredFullScreen = false
    window.toggleFullScreen(nil)
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    applicationItem.submenu = applicationMenu
    menu.addItem(applicationItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let fullScreen = viewMenu.addItem(
      withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.control, .command]
    viewItem.submenu = viewMenu
    menu.addItem(viewItem)
    return menu
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  var isBuiltIn: Bool {
    displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
  }
}
