import Foundation

enum Live {
  struct Event: Sendable, Equatable, Codable {
    var stamp: Date
    var provider: String
    var session: Int
    var model: String?
    var speed: String
    var uncached: Double
    var cached: Double
    var created: Double
    /// Part of `created` written to Claude's one-hour cache.
    var createdLong: Double = 0
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
      for url in jsonlFiles(root: tree.root, since: since, fileManager: fileManager) {
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

  /// Every event after `since`, read from scratch. The app keeps a `Ledger` instead, so a refresh
  /// parses only what each log gained.
  static func events(
    since: Date, trees: [(provider: String, root: URL)] = liveTrees(),
    fileManager: FileManager = .default
  ) -> [Event] {
    var ledger = Ledger(since: since)
    _ = advance(&ledger, trees: trees, fileManager: fileManager)
    return ledger.events
  }

  /// How far one log was read, plus the context a later line needs.
  struct Tail: Codable, Sendable, Equatable {
    var offset: UInt64 = 0
    /// Codex names the model in `turn_context`, not on each usage line.
    var model: String?
    var session: Int?
    /// Claude repeats a request's usage on each content block; these were already counted.
    var recent: [String] = []
  }

  /// Events after `since` from every Claude and Codex log, with each log's read position. Logs only
  /// grow, so `advance` reads just the appended bytes.
  struct Ledger: Codable, Sendable {
    var since: Date
    var tails: [String: Tail] = [:]
    var events: [Event] = []
  }

  /// Reads what each log gained since the last pass. Returns false when a log shrank or was
  /// replaced; the caller then starts a new ledger.
  static func advance(
    _ ledger: inout Ledger, trees: [(provider: String, root: URL)] = liveTrees(),
    fileManager: FileManager = .default
  ) -> Bool {
    for tree in trees where tree.provider == "claude" || tree.provider == "codex" {
      // A Codex session keeps writing to the day folder it started in, so walk the whole tree
      // and let modification dates pick the files. Only appended bytes are read.
      for url in jsonlFiles(root: tree.root, since: ledger.since, fileManager: fileManager) {
        let size =
          ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
          .uint64Value ?? 0
        var tail =
          ledger.tails[url.path]
          ?? Tail(session: sessionNumber(url.deletingPathExtension().lastPathComponent))
        if size < tail.offset { return false }
        if size == tail.offset { continue }
        let since = ledger.since
        let provider = tree.provider
        var added: [Event] = []
        let reached = readLines(of: url, from: tail.offset) { line in
          switch provider {
          case "claude": return claudeLine(line, since: since, tail: &tail, into: &added)
          default: return codexLine(line, since: since, tail: &tail, into: &added)
          }
        }
        guard let reached else { continue }
        tail.offset = reached
        ledger.tails[url.path] = tail
        ledger.events.append(contentsOf: added)
      }
    }
    return true
  }

  private static let claudeNeedles = [Array(#""type":"assistant""#.utf8), Array(#""usage""#.utf8)]
  private static let codexUsage = Array(#""type":"token_usage_record""#.utf8)
  private static let codexTurn = Array(#""type":"turn_context""#.utf8)

  /// Handles one Claude line. Returns false only when the line is not valid JSON.
  private static func claudeLine(
    _ line: UnsafeRawBufferPointer, since: Date, tail: inout Tail, into events: inout [Event]
  ) -> Bool {
    guard claudeNeedles.allSatisfy({ contains(line, $0) }) else { return true }
    guard let object = object(line) else { return false }
    guard object["type"] as? String == "assistant" else { return true }
    let message = object["message"] as? [String: Any] ?? [:]
    guard let usage = message["usage"] as? [String: Any] else { return true }
    guard let stamp = date(object["timestamp"]) ?? date(object["timestampMs"]), stamp > since
    else { return true }
    if let request = (object["requestId"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
      if tail.recent.contains(request) { return true }
      tail.recent.append(request)
      if tail.recent.count > 64 { tail.recent.removeFirst(tail.recent.count - 64) }
    }
    let id = (object["sessionId"] as? String) ?? (object["session_id"] as? String)
    let speed = (usage["speed"] as? String)?.lowercased() ?? "standard"
    events.append(
      Event(
        stamp: stamp, provider: "claude", session: id.map(sessionNumber) ?? tail.session ?? 0,
        model: message["model"] as? String, speed: speed,
        uncached: number(usage["input_tokens"]) ?? 0,
        cached: number(usage["cache_read_input_tokens"]) ?? 0,
        created: number(usage["cache_creation_input_tokens"]) ?? 0,
        createdLong: number(
          (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]) ?? 0,
        output: number(usage["output_tokens"]) ?? 0, reported: nil))
    return true
  }

  /// Handles one Codex line. Returns false only when the line is not valid JSON.
  private static func codexLine(
    _ line: UnsafeRawBufferPointer, since: Date, tail: inout Tail, into events: inout [Event]
  ) -> Bool {
    // Both types sit right after the timestamp; looking only there skips tool output that
    // happens to mention them.
    let head = UnsafeRawBufferPointer(rebasing: line.prefix(160))
    let isUsage = contains(head, codexUsage)
    guard isUsage || contains(head, codexTurn) else { return true }
    guard let object = object(line) else { return false }
    let payload = object["payload"] as? [String: Any] ?? [:]
    let type = object["type"] as? String
    if type == "turn_context", let next = payload["model"] as? String, !next.isEmpty {
      tail.model = next
    }
    guard type == "token_usage_record", let usage = payload["usage"] as? [String: Any] else {
      return true
    }
    if let session = payload["session_id"] as? String, !session.isEmpty {
      tail.session = sessionNumber(session)
    }
    guard let stamp = date(object["timestamp"]) ?? date(payload["timestamp"]), stamp > since
    else { return true }
    let input = number(usage["input_tokens"]) ?? 0
    let cached = number(usage["cached_input_tokens"]) ?? 0
    events.append(
      Event(
        stamp: stamp, provider: "codex", session: tail.session ?? 0, model: tail.model,
        speed: "standard", uncached: max(0, input - cached), cached: cached,
        created: number(usage["cache_write_input_tokens"]) ?? 0,
        output: number(usage["output_tokens"]) ?? 0, reported: number(payload["cost_usd"])))
    return true
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

  /// Calls `body` for each complete line after `offset` and returns the offset after the last line
  /// handled, or nil when the file can't be opened. A last line without a newline counts only when
  /// `body` accepts it, so a line still being written is read again next time.
  private static func readLines(
    of url: URL, from offset: UInt64, body: (UnsafeRawBufferPointer) -> Bool
  ) -> UInt64? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
    var reached = offset
    var buffer: [UInt8] = []
    var searchFrom = 0
    while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
      buffer.append(contentsOf: chunk)
      var lineStart = 0
      buffer.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var cursor = searchFrom
        while cursor < bytes.count, let hit = memchr(base + cursor, 10, bytes.count - cursor) {
          let end = base.distance(to: UnsafeRawPointer(hit))
          _ = body(UnsafeRawBufferPointer(rebasing: bytes[lineStart..<end]))
          lineStart = end + 1
          cursor = lineStart
        }
      }
      reached += UInt64(lineStart)
      buffer.removeFirst(lineStart)
      searchFrom = buffer.count
    }
    if !buffer.isEmpty {
      let accepted = buffer.withUnsafeBytes { bytes in
        // An unfinished line fails to parse; an irrelevant one waits for the next newline.
        body(bytes) && object(bytes) != nil
      }
      if accepted { reached += UInt64(buffer.count) }
    }
    return reached
  }

  private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
    guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
    return needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress, needle.count) }
      != nil
  }

  private static func object(_ bytes: UnsafeRawBufferPointer) -> [String: Any]? {
    guard let base = bytes.baseAddress, bytes.count > 1 else { return nil }
    let data = Data(
      bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
