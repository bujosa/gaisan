import SwiftUI

struct PanelView: View {
  let estimate: Estimate?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("API estimate · not a bill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Local logs × public rates")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      if let estimate, estimate.hasLogs {
        totals(estimate)
        if !estimate.sources.isEmpty {
          Divider().opacity(0.35)
          Text("Today by source")
            .font(.caption2)
            .foregroundStyle(.secondary)
          ForEach(estimate.sources) { source in
            HStack {
              Text(source.name)
              Spacer()
              Text(source.today.map { Money(dollars: $0).label } ?? "—")
                .monospacedDigit()
                .foregroundStyle(source.today == nil ? .tertiary : .primary)
            }
            .font(.subheadline)
          }
        }
      } else {
        Text("No local agent logs on this Mac.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(width: 300, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func totals(_ estimate: Estimate) -> some View {
    VStack(spacing: 6) {
      row("Today", estimate.today)
      row("Last 7 days", estimate.week)
      row("All time", estimate.allTime)
    }
    .font(.subheadline)
  }

  private func row(_ title: String, _ dollars: Double) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(Money(dollars: dollars).label)
        .monospacedDigit()
    }
  }
}
