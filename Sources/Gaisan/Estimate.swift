import Foundation

struct Money: Sendable, Equatable {
  var dollars: Double

  var ticker: String { "≈\(Self.format(dollars))" }
  var label: String { "≈ \(Self.format(dollars))" }

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

struct SourceLine: Sendable, Equatable, Identifiable {
  var id: String
  var name: String
  var today: Double?
}

struct Estimate: Sendable, Equatable {
  var today: Double
  var week: Double
  var allTime: Double
  var sources: [SourceLine]
  var hasLogs: Bool
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

enum Scan {
  private static let speeds = ["standard", "fast", "ultrafast"]
  private static let unpriceable: Set<String> = [
    "<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable",
  ]

  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  static var cacheURL: URL {
    home.appendingPathComponent(".t3/userdata/usage-scan-cache-v5.json")
  }

  static var ratesURL: URL {
    home.appendingPathComponent(".t3/userdata/usage-model-rates.json")
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

  static func load(
    cache: URL = cacheURL, rates: URL = ratesURL, sessions: [URL] = sessionRoots,
    now: Date = Date(), fileManager: FileManager = .default
  ) -> Estimate? {
    guard hasLogs(cache: cache, sessions: sessions, fileManager: fileManager) else { return nil }
    guard let cacheData = try? Data(contentsOf: cache),
      let cacheJSON = try? JSONSerialization.jsonObject(with: cacheData) as? [String: Any],
      let ratesData = try? Data(contentsOf: rates),
      let ratesJSON = try? JSONSerialization.jsonObject(with: ratesData) as? [String: Any]
    else {
      return Estimate(today: 0, week: 0, allTime: 0, sources: [], hasLogs: true)
    }
    return fold(cache: cacheJSON, rates: ratesJSON, now: now)
  }

  static func fold(cache: [String: Any], rates: [String: Any], now: Date) -> Estimate {
    let models = cache["models"] as? [String] ?? []
    let document = rates["document"] as? [String: Any] ?? rates
    let table = parseRateTable(document)
    let files = cache["files"] as? [String: Any] ?? [:]
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: now)
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    var today = 0.0
    var week = 0.0
    var allTime = 0.0
    var todayBy: [String: Double] = [:]
    var seen: Set<String> = []

    for (_, value) in files {
      guard let rec = value as? [String: Any] else { continue }
      let provider = rec["p"] as? String ?? "other"
      seen.insert(provider)
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
        let speed = speeds[speedIndex]
        let reported = number(cells[9])
        let cost = price(
          model: rateModel ?? model, speed: speed, uncached: uncached, cached: cached,
          created: created, output: output, reported: reported, table: table)
        allTime += cost
        let stamp = Date(timeIntervalSince1970: ts > 1_000_000_000_000 ? ts / 1000 : ts)
        if stamp >= weekAgo { week += cost }
        if stamp >= startOfToday {
          today += cost
          todayBy[provider, default: 0] += cost
        }
      }
    }

    let order = ["claude", "codex", "grok", "pi"]
    let names = ["claude": "Claude", "codex": "Codex", "grok": "Grok", "pi": "Pi"]
    var sources: [SourceLine] = []
    for id in order where seen.contains(id) || todayBy[id] != nil {
      sources.append(SourceLine(id: id, name: names[id] ?? id, today: todayBy[id]))
    }
    return Estimate(today: today, week: week, allTime: allTime, sources: sources, hasLogs: true)
  }

  /// Same layout T3 writes: uncached, cached, cache-create, output. Reasoning is already inside output.
  /// `reportedCostUsd` wins when the provider already priced the row.
  static func price(
    model: String?, speed: String, uncached: Double, cached: Double, created: Double,
    output: Double, reported: Double?, table: [String: ModelRate]
  ) -> Double {
    let reportedCost = reported.flatMap { $0.isFinite ? $0 : nil }
    guard let rate = lookup(model, in: table) else { return reportedCost ?? 0 }
    let list = cost(
      uncached: uncached, cached: cached, created: created, output: output,
      rates: ratesAt(rate, speed))
    if let reportedCost, list <= 0 { return reportedCost }
    return reportedCost ?? list
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

  private static func cost(
    uncached: Double, cached: Double, created: Double, output: Double, rates: TokenRates
  ) -> Double {
    uncached * rates.input + cached * rates.cacheRead + created * rates.cacheWrite + output
      * rates.output
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
