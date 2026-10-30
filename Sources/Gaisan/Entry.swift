import AppKit
import SwiftUI

@main
enum Entry {
  static func main() {
    if CommandLine.arguments.contains("--print") {
      if let estimate = Scan.load() {
        print(
          "today \(Money(dollars: estimate.today).label) · 7d \(Money(dollars: estimate.week).label) · all \(Money(dollars: estimate.allTime).label)"
        )
        for source in estimate.sources {
          let value = source.today.map { Money(dollars: $0).label } ?? "—"
          print("\(source.name) today \(value)")
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
  private var statusItem: NSStatusItem?
  private var panel: NSWindow?
  private var estimate: Estimate?
  private var timer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    reload()
    if estimate?.hasLogs != true, !Scan.hasLogs() {
      // Stay installed but keep the item off until logs appear.
    }
    installStatusItem()
    applyTitle()
    timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reloadAndApply() }
    }
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "GaisanEstimate"
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    statusItem = item
  }

  private func reload() {
    estimate = Scan.load()
  }

  private func reloadAndApply() {
    reload()
    applyTitle()
    if panel?.isVisible == true, let content = panel?.contentView as? NSHostingView<PanelView> {
      content.rootView = PanelView(estimate: estimate)
    }
  }

  private func applyTitle() {
    let visible = estimate?.hasLogs == true || Scan.hasLogs()
    statusItem?.isVisible = visible
    guard visible else { return }
    let title = Money(dollars: estimate?.today ?? 0).ticker
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    statusItem?.button?.attributedTitle = NSAttributedString(
      string: title,
      attributes: [.font: font, .foregroundColor: NSColor.labelColor]
    )
  }

  @objc private func togglePanel() {
    if panel?.isVisible == true {
      panel?.orderOut(nil)
      return
    }
    reloadAndApply()
    let window = panel ?? makePanel()
    panel = window
    placeUnderStatusItem(window)
    window.makeKeyAndOrderFront(nil)
  }

  private func makePanel() -> NSWindow {
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = NSHostingView(rootView: PanelView(estimate: estimate))
    return window
  }

  private func placeUnderStatusItem(_ window: NSWindow) {
    guard let anchor = statusItem?.button?.window?.frame else {
      window.center()
      return
    }
    var origin = NSPoint(x: anchor.midX - 150, y: anchor.minY - window.frame.height - 6)
    if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
      let bounds = screen.visibleFrame
      origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - 300 - 8)
    }
    window.setFrameOrigin(origin)
  }
}
