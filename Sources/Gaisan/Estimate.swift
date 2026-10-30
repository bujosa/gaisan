import Foundation

struct Money: Sendable, Equatable {
  var dollars: Double

  var ticker: String { "≈\(Self.format(dollars))" }
  var label: String { "≈\(Self.format(dollars))" }

  static func format(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = Locale(identifier: "en_US")
    if abs(value) >= 100 {
      formatter.maximumFractionDigits = 0
      formatter.minimumFractionDigits = 0
    } else {
      formatter.maximumFractionDigits = 2
      formatter.minimumFractionDigits = 2
    }
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
  }
}

enum Window: String, Sendable, CaseIterable, Identifiable {
  case today, week, month, all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today: return "Today"
    case .week: return "7d"
    case .month: return "30d"
    case .all: return "All"
    }
  }
}

struct SourceLine: Sendable, Equatable, Identifiable, Codable {
  var id: String
  var name: String
  var cost: Double
  var sessions: Int
}

struct ModelLine: Sendable, Equatable, Identifiable, Codable {
  var id: String
  var name: String
  var cost: Double
}

struct Slice: Sendable, Equatable, Codable {
  var cost: Double = 0
  var sessions: Int = 0
  var records: Int = 0
  var unpriced: Int = 0
  var input: Double = 0
  var cacheRead: Double = 0
  var cacheWrite: Double = 0
  var output: Double = 0
  var cacheSavings: Double = 0
  var sources: [SourceLine] = []
  var models: [ModelLine] = []

  var unpricedShare: Double {
    records == 0 ? 0 : Double(unpriced) / Double(records)
  }
}

struct StackBucket: Sendable, Equatable, Identifiable, Codable {
  var id: String
  var claude: Double = 0
  var codex: Double = 0
  var grok: Double = 0
  var pi: Double = 0
  var other: Double = 0

  var total: Double { claude + codex + grok + pi + other }

  var layers: [SourceLine] {
    [
      SourceLine(id: "claude", name: "Claude", cost: claude, sessions: 0),
      SourceLine(id: "codex", name: "Codex", cost: codex, sessions: 0),
      SourceLine(id: "grok", name: "Grok", cost: grok, sessions: 0),
      SourceLine(id: "pi", name: "Pi", cost: pi, sessions: 0),
    ].filter { $0.cost > 0 }
  }

  static func from(_ costs: [String: Double], id: String) -> StackBucket {
    StackBucket(
      id: id, claude: costs["claude"] ?? 0, codex: costs["codex"] ?? 0, grok: costs["grok"] ?? 0,
      pi: costs["pi"] ?? 0,
      other: costs.filter { !["claude", "codex", "grok", "pi"].contains($0.key) }.values.reduce(
        0, +)
    )
  }
}

struct Estimate: Sendable, Equatable, Codable {
  var today: Slice
  var week: Slice
  var month: Slice
  var allTime: Slice
  var hours: [StackBucket] = []
  var days: [StackBucket] = []
  var hasLogs: Bool
  var fingerprint: String

  func slice(_ window: Window) -> Slice {
    switch window {
    case .today: return today
    case .week: return week
    case .month: return month
    case .all: return allTime
    }
  }

  func chart(_ window: Window) -> [StackBucket] {
    switch window {
    case .today: return hours
    case .week: return Array(days.suffix(7))
    case .month: return Array(days.suffix(30))
    case .all: return days
    }
  }

  static let empty = Estimate(
    today: Slice(), week: Slice(), month: Slice(), allTime: Slice(), hasLogs: true, fingerprint: "")
}

struct TokenRates: Sendable, Equatable {
  var input: Double
  var output: Double
  var cacheRead: Double
  var cacheWrite: Double
}

struct ModelRate: Sendable, Equatable {
  var standard: TokenRates
  var fast: TokenRates?
  var ultrafast: TokenRates?
}

struct Pricing: Sendable, Equatable {
  var cost: Double
  var input: Double
  var cacheRead: Double
  var cacheWrite: Double
  var output: Double
  var cacheSavings: Double
  var unpriced: Bool
}

enum Scan {
  private static let speeds = ["standard", "fast", "ultrafast"]
  private static let unpriceable: Set<String> = [
    "<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable",
  ]
  private static let sourceNames = [
    "claude": "Claude", "codex": "Codex", "grok": "Grok", "pi": "Pi",
  ]
  private static let sourceOrder = ["claude", "codex", "grok", "pi"]

  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  static var cacheURL: URL {
    home.appendingPathComponent(".t3/userdata/usage-scan-cache-v5.json")
  }

  static var ratesURL: URL {
    home.appendingPathComponent(".t3/userdata/usage-model-rates.json")
  }

  static var snapshotURL: URL {
    let root =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return root.appendingPathComponent("Gaisan/snapshot.json")
  }

  static var sessionRoots: [URL] {
    [
      home.appendingPathComponent(".claude/projects"),
      home.appendingPathComponent(".codex/sessions"),
      home.appendingPathComponent(".grok/sessions"),
      home.appendingPathComponent(".pi/agent/sessions"),
    ]
  }

  static func hasLogs(
    cache: URL = cacheURL, sessions: [URL] = sessionRoots, fileManager: FileManager = .default
  ) -> Bool {
    if fileManager.fileExists(atPath: cache.path) { return true }
    return sessions.contains { fileManager.fileExists(atPath: $0.path) }
  }

  static func fingerprint(
    cache: URL = cacheURL, now: Date = Date(), fileManager: FileManager = .default
  ) -> String {
    let values = try? fileManager.attributesOfItem(atPath: cache.path)
    let modified = (values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (values?[.size] as? NSNumber)?.intValue ?? 0
    let day = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
    return "v2-\(size)-\(modified)-\(day)"
  }

  static func loadSnapshot(matching fingerprint: String, from url: URL = snapshotURL) -> Estimate? {
    guard let data = try? Data(contentsOf: url),
      let estimate = try? JSONDecoder().decode(Estimate.self, from: data),
      estimate.fingerprint == fingerprint
    else { return nil }
    return estimate
  }

  static func saveSnapshot(_ estimate: Estimate, to url: URL = snapshotURL) {
    let folder = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(estimate) else { return }
    try? data.write(to: url, options: .atomic)
  }

  static func load(
    cache: URL = cacheURL, rates: URL = ratesURL, sessions: [URL] = sessionRoots,
    now: Date = Date(), fileManager: FileManager = .default
  ) -> Estimate? {
    guard hasLogs(cache: cache, sessions: sessions, fileManager: fileManager) else { return nil }
    let mark = fingerprint(cache: cache, now: now, fileManager: fileManager)
    if let cached = loadSnapshot(matching: mark) { return cached }
    guard let cacheData = try? Data(contentsOf: cache),
      let cacheJSON = try? JSONSerialization.jsonObject(with: cacheData) as? [String: Any],
      let ratesData = try? Data(contentsOf: rates),
      let ratesJSON = try? JSONSerialization.jsonObject(with: ratesData) as? [String: Any]
    else {
      return Estimate.empty
    }
    var estimate = fold(cache: cacheJSON, rates: ratesJSON, now: now)
    estimate.fingerprint = mark
    saveSnapshot(estimate)
    return estimate
  }

  static func fold(cache: [String: Any], rates: [String: Any], now: Date) -> Estimate {
    let models = cache["models"] as? [String] ?? []
    let document = rates["document"] as? [String: Any] ?? rates
    let table = parseRateTable(document)
    let files = cache["files"] as? [String: Any] ?? [:]
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: now)
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
    let chartStart = calendar.date(byAdding: .day, value: -89, to: startOfToday) ?? startOfToday
    var today = Bucket()
    var week = Bucket()
    var month = Bucket()
    var allTime = Bucket()
    var hours = Array(repeating: [String: Double](), count: 24)
    var days: [Int: [String: Double]] = [:]

    for (_, value) in files {
      guard let rec = value as? [String: Any] else { continue }
      let provider = rec["p"] as? String ?? "other"
      let rows = (rec["r"] as? [Any] ?? []) + (rec["t"] as? [Any] ?? [])
      for row in rows {
        guard let cells = row as? [Any], cells.count >= 11,
          let ts = number(cells[0]),
          let uncached = number(cells[3]), let cached = number(cells[4]),
          let created = number(cells[5]), let output = number(cells[6]),
          let speedIndex = int(cells[10]), speeds.indices.contains(speedIndex)
        else { continue }
        let model = name(cells[1], in: models)
        let rateModel = cells.count > 11 ? name(cells[11], in: models) : nil
        let session = int(cells[2]) ?? -1
        let speed = speeds[speedIndex]
        let reported = number(cells[9])
        let priced = pricing(
          model: rateModel ?? model, speed: speed, uncached: uncached, cached: cached,
          created: created, output: output, reported: reported, table: table)
        allTime.add(provider: provider, session: session, model: model, priced: priced)
        let stamp = Date(timeIntervalSince1970: ts > 1_000_000_000_000 ? ts / 1000 : ts)
        if stamp >= monthAgo {
          month.add(provider: provider, session: session, model: model, priced: priced)
        }
        if stamp >= weekAgo {
          week.add(provider: provider, session: session, model: model, priced: priced)
        }
        if stamp >= startOfToday {
          today.add(provider: provider, session: session, model: model, priced: priced)
          hours[calendar.component(.hour, from: stamp)][provider, default: 0] += priced.cost
        }
        if stamp >= chartStart {
          let day = Int(calendar.startOfDay(for: stamp).timeIntervalSince1970.rounded())
          days[day, default: [:]][provider, default: 0] += priced.cost
        }
      }
    }

    let known = allTime.slice().sources
    return Estimate(
      today: today.slice(carrying: known), week: week.slice(carrying: known),
      month: month.slice(carrying: known), allTime: allTime.slice(),
      hours: (0..<24).map { StackBucket.from(hours[$0], id: "h\($0)") },
      days: paddedDays(days, from: chartStart, through: startOfToday, calendar: calendar),
      hasLogs: true, fingerprint: "")
  }

  private static func paddedDays(
    _ days: [Int: [String: Double]], from start: Date, through end: Date, calendar: Calendar
  ) -> [StackBucket] {
    var cursor = start
    var buckets: [StackBucket] = []
    while cursor <= end {
      let key = Int(cursor.timeIntervalSince1970.rounded())
      buckets.append(StackBucket.from(days[key] ?? [:], id: "d\(key)"))
      cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
    }
    return buckets
  }

  /// Same layout T3 writes: uncached, cached, cache-create, output. Reasoning is already inside output.
  /// `reportedCostUsd` wins when the provider already priced the row.
  static func price(
    model: String?, speed: String, uncached: Double, cached: Double, created: Double,
    output: Double, reported: Double?, table: [String: ModelRate]
  ) -> Double {
    pricing(
      model: model, speed: speed, uncached: uncached, cached: cached, created: created,
      output: output, reported: reported, table: table
    ).cost
  }

  static func pricing(
    model: String?, speed: String, uncached: Double, cached: Double, created: Double,
    output: Double, reported: Double?, table: [String: ModelRate]
  ) -> Pricing {
    let reportedCost = reported.flatMap { $0.isFinite ? $0 : nil }
    guard let rate = lookup(model, in: table) else {
      if let reportedCost {
        return Pricing(
          cost: reportedCost, input: 0, cacheRead: 0, cacheWrite: 0, output: 0, cacheSavings: 0,
          unpriced: false)
      }
      return Pricing(
        cost: 0, input: 0, cacheRead: 0, cacheWrite: 0, output: 0, cacheSavings: 0, unpriced: true)
    }
    let used = ratesAt(rate, speed)
    let input = uncached * used.input
    let cacheRead = cached * used.cacheRead
    let cacheWrite = created * used.cacheWrite
    let outputCost = output * used.output
    let list = input + cacheRead + cacheWrite + outputCost
    let savings = cached * (used.input - used.cacheRead)
    let scale: Double
    let cost: Double
    if let reportedCost, list <= 0 {
      return Pricing(
        cost: reportedCost, input: 0, cacheRead: 0, cacheWrite: 0, output: 0, cacheSavings: 0,
        unpriced: false)
    }
    if let reportedCost, list > 0 {
      cost = reportedCost
      scale = reportedCost / list
    } else {
      cost = list
      scale = 1
    }
    return Pricing(
      cost: cost, input: input * scale, cacheRead: cacheRead * scale,
      cacheWrite: cacheWrite * scale,
      output: outputCost * scale, cacheSavings: savings * scale, unpriced: false)
  }

  static func parseRateTable(_ document: [String: Any]) -> [String: ModelRate] {
    var table: [String: ModelRate] = [:]
    for (name, raw) in document {
      guard let entry = raw as? [String: Any], let standard = tokenRates(entry, suffix: "") else {
        continue
      }
      let key = normalize(name)
      guard !key.isEmpty else { continue }
      var rate = ModelRate(standard: standard, fast: nil, ultrafast: nil)
      if let multiple = fastMultiplier(entry) {
        rate.fast = scale(standard, by: multiple)
      } else {
        rate.fast = tokenRates(entry, suffix: "_priority", standard: standard)
      }
      rate.ultrafast = tokenRates(entry, suffix: "_ultrafast", standard: standard)
      table[key] = rate
    }
    var aliases: [String: ModelRate?] = [:]
    for (key, rate) in table {
      let alias = bare(key)
      guard !alias.isEmpty, alias != key, table[alias] == nil else { continue }
      if let held = aliases[alias] {
        if let held, held != rate {
          aliases[alias] = Optional<ModelRate>.none
        } else if held == nil {
          continue
        }
      } else {
        aliases[alias] = rate
      }
    }
    for (alias, rate) in aliases {
      if let rate { table[alias] = rate }
    }
    return table
  }

  private struct Bucket {
    var cost = 0.0
    var input = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    var output = 0.0
    var cacheSavings = 0.0
    var records = 0
    var unpriced = 0
    var sessions: Set<Int> = []
    var sourceCost: [String: Double] = [:]
    var sourceSessions: [String: Set<Int>] = [:]
    var modelCost: [String: Double] = [:]

    mutating func add(provider: String, session: Int, model: String?, priced: Pricing) {
      records += 1
      cost += priced.cost
      input += priced.input
      cacheRead += priced.cacheRead
      cacheWrite += priced.cacheWrite
      output += priced.output
      cacheSavings += priced.cacheSavings
      if priced.unpriced { unpriced += 1 }
      if session >= 0 { sessions.insert(session) }
      sourceCost[provider, default: 0] += priced.cost
      if session >= 0 { sourceSessions[provider, default: []].insert(session) }
      if let model, model != "<synthetic>" {
        modelCost[model, default: 0] += priced.cost
      }
    }

    func slice(carrying known: [SourceLine] = []) -> Slice {
      var sources: [SourceLine] = []
      var seen: Set<String> = []
      for id in sourceOrder where sourceCost[id] != nil || sourceSessions[id] != nil {
        seen.insert(id)
        sources.append(
          SourceLine(
            id: id, name: sourceNames[id] ?? id, cost: sourceCost[id] ?? 0,
            sessions: sourceSessions[id]?.count ?? 0))
      }
      for source in known where !seen.contains(source.id) {
        seen.insert(source.id)
        sources.append(SourceLine(id: source.id, name: source.name, cost: 0, sessions: 0))
      }
      for (id, cost) in sourceCost where !seen.contains(id) {
        sources.append(
          SourceLine(id: id, name: id, cost: cost, sessions: sourceSessions[id]?.count ?? 0))
      }
      sources.sort {
        (sourceOrder.firstIndex(of: $0.id) ?? 99) < (sourceOrder.firstIndex(of: $1.id) ?? 99)
      }
      let models =
        modelCost
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
        .prefix(6)
        .map { ModelLine(id: $0.key, name: $0.key, cost: $0.value) }
      return Slice(
        cost: cost, sessions: sessions.count, records: records, unpriced: unpriced, input: input,
        cacheRead: cacheRead, cacheWrite: cacheWrite, output: output, cacheSavings: cacheSavings,
        sources: sources, models: Array(models))
    }
  }

  private static func lookup(_ model: String?, in table: [String: ModelRate]) -> ModelRate? {
    guard let model else { return nil }
    let key = stripVariant(normalize(model))
    let name = bare(key)
    if name.isEmpty || unpriceable.contains(name) { return nil }
    return table[key]
  }

  private static func ratesAt(_ rate: ModelRate, _ speed: String) -> TokenRates {
    switch speed {
    case "fast": return rate.fast ?? rate.standard
    case "ultrafast": return rate.ultrafast ?? rate.standard
    default: return rate.standard
    }
  }

  private static func tokenRates(
    _ entry: [String: Any], suffix: String, standard: TokenRates? = nil
  )
    -> TokenRates?
  {
    guard let input = number(entry["input_cost_per_token\(suffix)"]),
      let output = number(entry["output_cost_per_token\(suffix)"])
    else { return nil }
    let cacheRead =
      number(entry["cache_read_input_token_cost\(suffix)"])
      ?? scaledCache(standard?.cacheRead, standardInput: standard?.input, input: input)
      ?? input
    let cacheWrite =
      number(entry["cache_creation_input_token_cost\(suffix)"])
      ?? scaledCache(standard?.cacheWrite, standardInput: standard?.input, input: input)
      ?? input
    return TokenRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
  }

  private static func scaledCache(_ field: Double?, standardInput: Double?, input: Double)
    -> Double?
  {
    guard let field, let standardInput, standardInput > 0 else { return nil }
    return field / standardInput * input
  }

  private static func fastMultiplier(_ entry: [String: Any]) -> Double? {
    guard let specific = entry["provider_specific_entry"] as? [String: Any],
      let fast = number(specific["fast"]), fast > 0
    else { return nil }
    return fast
  }

  private static func scale(_ rates: TokenRates, by multiple: Double) -> TokenRates {
    TokenRates(
      input: rates.input * multiple, output: rates.output * multiple,
      cacheRead: rates.cacheRead * multiple, cacheWrite: rates.cacheWrite * multiple)
  }

  private static func normalize(_ model: String) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func bare(_ key: String) -> String {
    key.split(separator: "/").last.map(String.init) ?? key
  }

  private static func stripVariant(_ key: String) -> String {
    key.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
      ?? key
  }

  private static func name(_ any: Any, in models: [String]) -> String? {
    guard let index = int(any), models.indices.contains(index) else { return nil }
    return models[index]
  }

  private static func number(_ any: Any?) -> Double? {
    if any is NSNull { return nil }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s) }
    return nil
  }

  private static func int(_ any: Any?) -> Int? {
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String { return Int(s) }
    return nil
  }
}
