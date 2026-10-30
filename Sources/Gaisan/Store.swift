import Combine
import Foundation

@MainActor
final class Board: ObservableObject {
  @Published var estimate: Estimate?
  @Published var loading = false
  @Published var window: Window = .today

  private var debounce: DispatchWorkItem?
  private var watcher: DispatchSourceFileSystemObject?
  private var directoryHandle: Int32 = -1
  private var timer: Timer?
  private var inFlight = false
  private var lastFingerprint: String = ""

  func start() {
    if let snapshot = Scan.loadSnapshot(matching: Scan.fingerprint()) {
      estimate = snapshot
      lastFingerprint = snapshot.fingerprint
    }
    watch()
    timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh(force: false) }
    }
    refresh(force: estimate == nil)
  }

  func refresh(force: Bool) {
    let mark = Scan.fingerprint()
    if !force, mark == lastFingerprint, estimate != nil { return }
    if inFlight { return }
    inFlight = true
    loading = estimate == nil
    Task.detached(priority: .utility) {
      let next = Scan.load()
      await MainActor.run {
        self.inFlight = false
        self.loading = false
        if let next {
          self.estimate = next
          self.lastFingerprint = next.fingerprint
        } else if !Scan.hasLogs() {
          self.estimate = nil
          self.lastFingerprint = ""
        }
      }
    }
  }

  private func watch() {
    let folder = Scan.cacheURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    directoryHandle = open(folder.path, O_EVTONLY)
    guard directoryHandle >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: directoryHandle, eventMask: [.write, .extend, .rename, .delete, .attrib],
      queue: DispatchQueue.global(qos: .utility))
    source.setEventHandler { [weak self] in
      DispatchQueue.main.async { self?.scheduleRefresh() }
    }
    source.setCancelHandler { [weak self] in
      if let handle = self?.directoryHandle, handle >= 0 { close(handle) }
    }
    watcher = source
    source.resume()
  }

  private func scheduleRefresh() {
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.refresh(force: false)
    }
    debounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }
}
