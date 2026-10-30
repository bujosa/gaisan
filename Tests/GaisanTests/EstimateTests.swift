import Foundation
import Testing

@testable import Gaisan

struct EstimateTests {
  @Test func foldSumsTodayWeekAndAllTimeBySource() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let today = now.timeIntervalSince1970 * 1000
    let lastWeek = (now.timeIntervalSince1970 - 86_400 * 3) * 1000
    let old = (now.timeIntervalSince1970 - 86_400 * 40) * 1000
    let cache: [String: Any] = [
      "models": ["claude-opus-5-5"],
      "files": [
        "a.jsonl": [
          "p": "claude",
          "r": [
            row(today, uncached: 1_000_000),
            row(lastWeek, uncached: 1_000_000),
            row(old, uncached: 1_000_000),
          ],
        ],
        "b.jsonl": [
          "p": "codex",
          "r": [row(today, output: 1_000_000)],
        ],
      ],
    ]
    let estimate = Scan.fold(cache: cache, rates: opusRates, now: now)
    #expect(estimate.hasLogs)
    #expect(abs(estimate.allTime - 32) < 0.01)
    #expect(abs(estimate.week - 28) < 0.01)
    #expect(abs(estimate.today - 24) < 0.01)
    #expect(estimate.sources.map(\.id) == ["claude", "codex"])
    #expect(Money(dollars: 12.4).ticker == "≈$12.40")
    #expect(Money(dollars: 18_214).ticker == "≈$18,214")
  }

  @Test func cacheTokensUseDiscountAndPremiumRates() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let today = now.timeIntervalSince1970 * 1000
    let cache: [String: Any] = [
      "models": ["claude-opus-5-5"],
      "files": [
        "a.jsonl": [
          "p": "claude",
          "r": [row(today, uncached: 1_000, cached: 10_000, created: 2_000, output: 500)],
        ]
      ],
    ]
    let estimate = Scan.fold(cache: cache, rates: opusRates, now: now)
    // 1000*4e-6 + 10000*2e-7 + 2000*5e-6 + 500*2e-5 = 0.004 + 0.002 + 0.010 + 0.010 = 0.026
    #expect(abs(estimate.today - 0.026) < 0.0001)
  }

  @Test func reportedCostWinsOverListPrice() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let today = now.timeIntervalSince1970 * 1000
    let cache: [String: Any] = [
      "models": ["claude-opus-5-5"],
      "files": [
        "a.jsonl": [
          "p": "grok",
          "r": [row(today, uncached: 1_000_000, reported: 0.5)],
        ]
      ],
    ]
    let estimate = Scan.fold(cache: cache, rates: opusRates, now: now)
    #expect(abs(estimate.today - 0.5) < 0.0001)
  }

  @Test func syntheticAndBareFamilyNamesStayUnpriced() {
    #expect(
      Scan.price(
        model: "<synthetic>", speed: "standard", uncached: 9, cached: 0, created: 0, output: 9,
        reported: nil, table: [:]) == 0)
    #expect(
      Scan.price(
        model: "opus", speed: "standard", uncached: 9, cached: 0, created: 0, output: 9,
        reported: nil, table: [:]) == 0)
  }

  @Test func uniqueBareRateAliasIsUsed() {
    let table = Scan.parseRateTable([
      "xai/grok-4.7": [
        "input_cost_per_token": 0.000002,
        "output_cost_per_token": 0.000006,
      ]
    ])
    let cost = Scan.price(
      model: "grok-4.7", speed: "standard", uncached: 1_000_000, cached: 0, created: 0, output: 0,
      reported: nil, table: table)
    #expect(abs(cost - 2) < 0.0001)
  }

  @Test func missingLogsAreNil() {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gaisan-empty-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let missing = Scan.load(
      cache: empty.appendingPathComponent("missing.json"),
      rates: empty.appendingPathComponent("missing-rates.json"),
      sessions: [empty.appendingPathComponent("sessions")])
    #expect(missing == nil)
  }

  private var opusRates: [String: Any] {
    [
      "claude-opus-5-5": [
        "input_cost_per_token": 0.000004,
        "output_cost_per_token": 0.00002,
        "cache_read_input_token_cost": 0.0000002,
        "cache_creation_input_token_cost": 0.000005,
      ]
    ]
  }

  private func row(
    _ timestamp: Double, uncached: Double = 0, cached: Double = 0, created: Double = 0,
    output: Double = 0, reported: Double? = nil, speed: Int = 0
  ) -> [Any] {
    [
      timestamp, 0, 0, uncached, cached, created, output, 0, NSNull(), reported as Any? ?? NSNull(),
      speed, NSNull(),
    ]
  }
}
