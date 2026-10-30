import AppKit
import Combine
import SwiftUI

@main
enum Entry {
  static func main() {
    if CommandLine.arguments.contains("--print") {
      if let estimate = Scan.load() {
        print(
          "today \(Money(dollars: estimate.today.cost).label) · 7d \(Money(dollars: estimate.week.cost).label) · 30d \(Money(dollars: estimate.month.cost).label) · all \(Money(dollars: estimate.allTime.cost).label)"
        )
        print(
          "\(estimate.today.sessions) sessions today · \(estimate.allTime.sessions) all time")
        for source in estimate.today.sources {
          print("\(source.name) today \(Money(dollars: source.cost).label)")
        }
      } else {
        print("No local agent logs on this Mac.")
      }
      return
    }
    let application = NSApplication.shared
    let delegate = GaisanDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
  }
}

@MainActor
final class GaisanDelegate: NSObject, NSApplicationDelegate {
  private let board = Board()
  private var statusItem: NSStatusItem?
  private var panel: NSPanel?
  private var host: NSHostingView<AnyView>?
  private var cancellables: Set<AnyCancellable> = []
  private var mouseMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installStatusItem()
    applyTitle()
    board.$estimate.receive(on: RunLoop.main).sink { [weak self] _ in
      self?.applyTitle()
      self?.layoutPanel()
    }.store(in: &cancellables)
    board.start()
    if snapshotPath() != nil || CommandLine.arguments.contains("--panel") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self else { return }
        self.togglePanel()
        if let path = self.snapshotPath() {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.writePanelImage(to: path)
            NSApp.terminate(nil)
          }
        }
      }
    }
  }

  private func snapshotPath() -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return arguments[index + 1]
  }

  private func writePanelImage(to path: String) {
    guard let host else {
      fputs("gaisan: couldn't capture the panel\n", stderr)
      return
    }
    host.layoutSubtreeIfNeeded()
    let bounds = host.bounds
    guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else {
      fputs("gaisan: couldn't capture the panel\n", stderr)
      return
    }
    host.cacheDisplay(in: bounds, to: rep)
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "GaisanEstimate"
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    statusItem = item
  }

  private func applyTitle() {
    let visible = board.estimate?.hasLogs == true || Scan.hasLogs() || board.loading
    statusItem?.isVisible = visible
    guard visible else { return }
    let amount = Money(dollars: board.estimate?.today.cost ?? 0).ticker
    let title = board.estimate == nil && board.loading ? "today …" : "today \(amount)"
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    statusItem?.button?.attributedTitle = NSAttributedString(
      string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
  }

  @objc private func togglePanel() {
    if panel?.isVisible == true {
      hidePanel()
      return
    }
    board.refresh(force: false)
    let window = panel ?? makePanel()
    panel = window
    layoutPanel()
    placeUnderStatusItem(window)
    window.orderFront(nil)
    listenForOutsideClicks()
  }

  private func hidePanel() {
    panel?.orderOut(nil)
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
  }

  private func makePanel() -> NSPanel {
    let root = AnyView(PanelView().environmentObject(board))
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 420)
    self.host = host
    let window = NSPanel(
      contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = host
    return window
  }

  private func layoutPanel() {
    guard let host, let panel else { return }
    host.invalidateIntrinsicContentSize()
    let size = host.fittingSize
    let height = min(max(size.height, 180), 560)
    panel.setContentSize(NSSize(width: 400, height: height))
    placeUnderStatusItem(panel)
  }

  private func placeUnderStatusItem(_ window: NSWindow) {
    guard let anchor = statusItem?.button?.window?.frame else {
      window.center()
      return
    }
    var origin = NSPoint(x: anchor.midX - 200, y: anchor.minY - window.frame.height - 6)
    if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
      let bounds = screen.visibleFrame
      origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - 400 - 8)
      origin.y = max(origin.y, bounds.minY + 8)
    }
    window.setFrameOrigin(origin)
  }

  private func listenForOutsideClicks() {
    if mouseMonitor != nil { return }
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      guard let self, let panel = self.panel, panel.isVisible else { return }
      let point = NSEvent.mouseLocation
      if panel.frame.contains(point) { return }
      if let button = self.statusItem?.button, let frame = button.window?.frame,
        frame.contains(point)
      {
        return
      }
      DispatchQueue.main.async { self.hidePanel() }
    }
  }
}
