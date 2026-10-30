import SwiftUI

struct PanelView: View {
  @EnvironmentObject private var board: Board

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      windowPicker
      if let estimate = board.estimate, estimate.hasLogs {
        let slice = estimate.slice(board.window)
        hero(slice)
        sources(slice)
        mix(slice)
        models(slice)
        if slice.unpricedShare > 0 {
          Text("Excludes \(percent(slice.unpricedShare)) unpriced records.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      } else if board.loading {
        Text("Reading local logs…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
      } else {
        Text("No local agent logs on this Mac.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
      }
    }
    .padding(16)
    .frame(width: 400, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("API estimate")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("Not a bill · local logs × public rates")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var windowPicker: some View {
    HStack(spacing: 6) {
      ForEach(Window.allCases) { window in
        Button {
          board.window = window
        } label: {
          Text(window.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
              Capsule(style: .continuous)
                .fill(
                  board.window == window ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05)
                )
            )
            .foregroundStyle(board.window == window ? .primary : .secondary)
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
    }
  }

  private func hero(_ slice: Slice) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(Money(dollars: slice.cost).label)
        .font(.system(size: 34, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText())
      Text(caption(slice))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .animation(.snappy(duration: 0.35), value: slice.cost)
  }

  private func sources(_ slice: Slice) -> some View {
    let total = max(slice.cost, 0.0001)
    return VStack(alignment: .leading, spacing: 10) {
      ForEach(slice.sources) { source in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Accent.color(for: source.id)).frame(width: 7, height: 7)
            Text(source.name)
              .font(.subheadline.weight(.medium))
            Text(sessionLabel(source.sessions))
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(Money(dollars: source.cost).label)
              .font(.subheadline.weight(.medium).monospacedDigit())
          }
          Meter(used: source.cost / total * 100, accent: Accent.color(for: source.id))
        }
      }
    }
  }

  private func mix(_ slice: Slice) -> some View {
    let rows: [(String, Double)] = [
      ("Input", slice.input),
      ("Cache read", slice.cacheRead),
      ("Cache write", slice.cacheWrite),
      ("Output", slice.output),
    ].filter { $0.1 > 0 }
    return Group {
      if !rows.isEmpty || slice.cacheSavings > 0 {
        VStack(alignment: .leading, spacing: 6) {
          Text("Mix")
            .font(.caption2)
            .foregroundStyle(.secondary)
          ForEach(rows, id: \.0) { row in
            HStack {
              Text(row.0)
              Spacer()
              Text(Money(dollars: row.1).label)
                .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          if slice.cacheSavings > 0 {
            HStack {
              Text("Cache savings")
              Spacer()
              Text(Money(dollars: slice.cacheSavings).label)
                .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func models(_ slice: Slice) -> some View {
    Group {
      if !slice.models.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Models")
            .font(.caption2)
            .foregroundStyle(.secondary)
          ForEach(slice.models) { model in
            HStack {
              Text(model.name)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(Money(dollars: model.cost).label)
                .monospacedDigit()
            }
            .font(.caption)
          }
        }
      }
    }
  }

  private func caption(_ slice: Slice) -> String {
    var bits = [sessionLabel(slice.sessions)]
    if board.loading { bits.append("updating") }
    return bits.joined(separator: " · ")
  }

  private func sessionLabel(_ count: Int) -> String {
    count == 1 ? "1 session" : "\(count) sessions"
  }

  private func percent(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .percent
    formatter.maximumFractionDigits = value < 0.01 ? 1 : 0
    return formatter.string(from: NSNumber(value: value)) ?? "\(Int((value * 100).rounded()))%"
  }
}

enum Accent {
  static func color(for id: String) -> Color {
    switch id {
    case "claude": return Color(red: 0.85, green: 0.45, blue: 0.28)
    case "codex": return Color(red: 0.22, green: 0.68, blue: 0.48)
    case "grok": return Color(red: 0.55, green: 0.58, blue: 0.64)
    case "pi": return Color(red: 0.62, green: 0.42, blue: 0.86)
    default: return Color.secondary
    }
  }
}

struct Meter: View {
  var used: Double
  var accent: Color

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let fill = min(max(used / 100, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule().fill(accent).frame(width: max(width * fill, fill > 0 ? 4 : 0))
      }
    }
    .frame(height: 4)
  }
}
