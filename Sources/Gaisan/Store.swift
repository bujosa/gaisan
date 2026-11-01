import Combine
import CoreServices
import Foundation

@MainActor
final class Board: ObservableObject {
  @Published var estimate: Estimate?
  @Published var loading = false
  @Published var window: Window = .today

  private var debounce: DispatchWorkItem?
  private var watcher: DispatchSourceFileSystemObject?
  private var treeWatch: TreeWatch?
  private var directoryHandle: Int32 = -1
  private var timer: Timer?
  private var inFlight = false
  private var lastFingerprint: String = ""

  func start() {
    watch()
    timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh(force: false) }
    }
    refresh(force: true)
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
    if directoryHandle >= 0 {
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
    let roots = Scan.sessionRoots.filter { FileManager.default.fileExists(atPath: $0.path) }.map(
      \.path)
    treeWatch = TreeWatch(paths: roots) { [weak self] in
      DispatchQueue.main.async { self?.scheduleRefresh() }
    }
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

final class TreeWatch: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  private let onChange: @Sendable () -> Void

  init(paths: [String], onChange: @escaping @Sendable () -> Void) {
    self.onChange = onChange
    let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
    guard !existing.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      Unmanaged<TreeWatch>.fromOpaque(info).takeUnretainedValue().onChange()
    }
    stream = FSEventStreamCreate(
      nil, callback, &context, existing as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.8,
      UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
      FSEventStreamStart(stream)
    }
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
