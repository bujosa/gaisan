import Foundation

enum Live {
  struct Event: Sendable, Equatable {
    var stamp: Date
    var provider: String
    var session: Int
    var model: String?
    var speed: String
    var uncached: Double
    var cached: Double
    var created: Double
    var output: Double
    var reported: Double?
  }

  struct Mark: Sendable, Equatable {
    var count: Int = 0
    var bytes: Int = 0
    var newest: Int = 0
  }

  static func trees(home: URL = Scan.home) -> [(provider: String, root: URL)] {
    [
      ("claude", home.appendingPathComponent(".claude/projects")),
      ("codex", home.appendingPathComponent(".codex/sessions")),
      ("grok", home.appendingPathComponent(".grok/sessions")),
      ("pi", home.appendingPathComponent(".pi/agent/sessions")),
    ]
  }

  static func liveTrees(home: URL = Scan.home) -> [(provider: String, root: URL)] {
    trees(home: home).filter { $0.provider == "claude" || $0.provider == "codex" }
  }

  static func mark(
    trees: [(provider: String, root: URL)] = liveTrees(), since: Date,
    fileManager: FileManager = .default
  ) -> Mark {
    var mark = Mark()
    var newest = Date(timeIntervalSince1970: 0)
    for tree in trees {
      for url in files(tree, since: since, fileManager: fileManager) {
        let values = try? fileManager.attributesOfItem(atPath: url.path)
        let modified = values?[.modificationDate] as? Date ?? since
        let size = (values?[.size] as? NSNumber)?.intValue ?? 0
        mark.count += 1
        mark.bytes += size
        if modified > newest { newest = modified }
      }
    }
    mark.newest = Int(newest.timeIntervalSince1970)
    return mark
  }

  static func events(
    since: Date, trees: [(provider: String, root: URL)] = liveTrees(),
    fileManager: FileManager = .default
  ) -> [Event] {
    var events: [Event] = []
    for tree in trees {
      for url in files(tree, since: since, fileManager: fileManager) {
        switch tree.provider {
        case "claude": events.append(contentsOf: claudeEvents(from: url, since: since))
        case "codex": events.append(contentsOf: codexEvents(from: url, since: since))
        default: continue
        }
      }
    }
    return events
  }

  private static func files(
    _ tree: (provider: String, root: URL), since: Date, fileManager: FileManager
  ) -> [URL] {
    switch tree.provider {
    case "codex": return codexFiles(root: tree.root, since: since, fileManager: fileManager)
    default: return jsonlFiles(root: tree.root, since: since, fileManager: fileManager)
    }
  }

  private static func codexFiles(root: URL, since: Date, fileManager: FileManager) -> [URL] {
    if let names = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      let jsonl = names.filter { $0.pathExtension == "jsonl" }
      if !jsonl.isEmpty { return jsonl }
    }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    // Only day folders from the cache cutoff forward — never walk multi-gigabyte older months.
    var day = calendar.startOfDay(for: since)
    var files: [URL] = []
    while day <= today {
      let year = calendar.component(.year, from: day)
      let month = calendar.component(.month, from: day)
      let dayNumber = calendar.component(.day, from: day)
      let folder = root.appendingPathComponent(
        String(format: "%04d/%02d/%02d", year, month, dayNumber))
      if let names = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil)
      {
        files.append(contentsOf: names.filter { $0.pathExtension == "jsonl" })
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
      day = next
    }
    return files
  }

  private static func jsonlFiles(root: URL, since: Date, fileManager: FileManager) -> [URL] {
    var files: [URL] = []
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "jsonl" else { continue }
      let values = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .isRegularFileKey,
      ])
      guard values?.isRegularFile == true else { continue }
      if let modified = values?.contentModificationDate, modified < since { continue }
      files.append(url)
    }
    return files
  }

  private static func claudeEvents(from url: URL, since: Date) -> [Event] {
    var events: [Event] = []
    var seen: Set<String> = []
    forEachLine(in: url) { line in
      guard line.contains("\"usage\"") else { return }
      guard let object = object(line) else { return }
      guard object["type"] as? String == "assistant" else { return }
      let message = object["message"] as? [String: Any] ?? [:]
      guard let usage = message["usage"] as? [String: Any] else { return }
      guard let stamp = date(object["timestamp"]) ?? date(object["timestampMs"]), stamp > since
      else { return }
      let request = (object["requestId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      if let request, !seen.insert(request).inserted { return }
      let session = sessionNumber(
        (object["sessionId"] as? String) ?? (object["session_id"] as? String)
          ?? url.deletingPathExtension()
          .lastPathComponent)
      let speed = (usage["speed"] as? String)?.lowercased() ?? "standard"
      events.append(
        Event(
          stamp: stamp, provider: "claude", session: session, model: message["model"] as? String,
          speed: speed, uncached: number(usage["input_tokens"]) ?? 0,
          cached: number(usage["cache_read_input_tokens"]) ?? 0,
          created: number(usage["cache_creation_input_tokens"]) ?? 0,
          output: number(usage["output_tokens"]) ?? 0, reported: nil))
    }
    return events
  }

  private static func codexEvents(from url: URL, since: Date) -> [Event] {
    var events: [Event] = []
    var model: String?
    var fallbackSession = sessionNumber(url.deletingPathExtension().lastPathComponent)
    forEachLine(in: url) { line in
      guard line.contains("token_usage_record") || line.contains("turn_context") else { return }
      guard let object = object(line) else { return }
      let payload = object["payload"] as? [String: Any] ?? [:]
      let type = object["type"] as? String
      if type == "turn_context", let next = payload["model"] as? String, !next.isEmpty {
        model = next
      }
      guard type == "token_usage_record" else { return }
      guard let usage = payload["usage"] as? [String: Any] else { return }
      guard let stamp = date(object["timestamp"]) ?? date(payload["timestamp"]), stamp > since
      else { return }
      if let session = payload["session_id"] as? String, !session.isEmpty {
        fallbackSession = sessionNumber(session)
      }
      let input = number(usage["input_tokens"]) ?? 0
      let cached = number(usage["cached_input_tokens"]) ?? 0
      events.append(
        Event(
          stamp: stamp, provider: "codex", session: fallbackSession, model: model,
          speed: "standard", uncached: max(0, input - cached), cached: cached,
          created: number(usage["cache_write_input_tokens"]) ?? 0,
          output: number(usage["output_tokens"]) ?? 0, reported: number(payload["cost_usd"])))
    }
    return events
  }

  private static func forEachLine(in url: URL, body: (String) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    var buffer = Data()
    while true {
      let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
      if chunk.isEmpty {
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { body(line) }
        break
      }
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 10) {
        let lineData = buffer.subdata(in: 0..<newline)
        buffer.removeSubrange(0...newline)
        if let line = String(data: lineData, encoding: .utf8) { body(line) }
      }
    }
  }

  private static func object(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
  }

  private static func date(_ any: Any?) -> Date? {
    if let value = any as? TimeInterval {
      return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }
    if let value = any as? Int {
      let stamp = TimeInterval(value)
      return Date(timeIntervalSince1970: stamp > 1_000_000_000_000 ? stamp / 1000 : stamp)
    }
    guard let text = any as? String, !text.isEmpty else { return nil }
    if let date = try? Date(
      text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    {
      return date
    }
    return try? Date(text, strategy: .iso8601)
  }

  private static func sessionNumber(_ id: String) -> Int {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x1000_0000_01b3
    }
    return Int(hash & 0x7fff_ffff)
  }

  private static func number(_ any: Any?) -> Double? {
    if any is NSNull { return nil }
    if let number = any as? NSNumber { return number.doubleValue }
    if let text = any as? String { return Double(text) }
    return nil
  }

}
