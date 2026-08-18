import SwiftUI
import PokerCore

struct ResultView: View {
    let result: CalculationResult
    @EnvironmentObject var gameViewModel: GameViewModel

    var body: some View {
        VStack(spacing: 0) {
            actionBanner
            statsRow
            equitySection
            if let texture = result.boardTexture {
                boardTextureRow(texture)
            }
            reasoningSection
            if !result.alternativeActions.isEmpty {
                alternativesSection
            }
            footerRow
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: actionColor.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    // MARK: – Action Banner

    private var actionBanner: some View {
        ZStack {
            LinearGradient(
                colors: [actionColor, actionColor.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: actionIcon)
                        .font(.system(size: 22, weight: .bold))
                    Text(result.actionDisplay)
                        .font(.system(size: 26, weight: .black))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .foregroundColor(.white)

                Text(evLabel)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.88))
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: – Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                label: "Win Rate",
                value: "\(Int(result.equity * 100))%",
                color: equityColor
            )
            Divider().frame(height: 36)
            statCell(
                label: "SPR",
                value: String(format: "%.1f", result.spr),
                color: sprColor
            )
            Divider().frame(height: 36)
            statCell(
                label: "Pot Odds",
                value: result.potOddsDisplay ?? "--",
                color: .secondary
            )
        }
        .padding(.vertical, 14)
        .background(Color(.systemGray6))
    }

    @ViewBuilder
    private func statCell(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold).monospacedDigit())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: – Equity Section

    private var equitySection: some View {
        VStack(spacing: 8) {
            EquityBar(percentage: result.equity)
                .frame(height: 7)

            HStack(spacing: 6) {
                // Pot odds check, from the snapshot rather than from the live table —
                // see the note on `CalculationResult.heroActsLast`.
                if result.toCall > 0 {
                    let needed = result.requiredEquity * 100
                    let have = result.equity * 100
                    Image(systemName: have >= needed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(have >= needed ? .green : .red)
                    Text("Need \(Int(needed))% to call")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    Spacer()
                }

                // Position, likewise from the snapshot: tapping a seat used to flip this
                // badge above a reasoning string that still said the opposite.
                Image(systemName: result.heroActsLast
                      ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                    .font(.caption)
                    .foregroundColor(result.heroActsLast ? .green : .orange)
                Text(result.heroActsLast ? "In Position" : "Out of Position")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    // MARK: – Board Texture

    private func boardTextureRow(_ texture: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "suit.club.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(texture)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    // MARK: – Reasoning

    private var reasoningSection: some View {
        Text(result.reasoning)
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
    }

    // MARK: – Alternatives

    private var alternativesSection: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 16)

            VStack(spacing: 6) {
                Text("Other Options")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(result.alternativeActions, id: \.action.displayString) { alt in
                    HStack(spacing: 10) {
                        Image(systemName: iconForAction(alt.action, toCall: result.toCall))
                            .font(.system(size: 13))
                            .foregroundColor(colorForAction(alt.action, toCall: result.toCall))
                            .frame(width: 18)

                        Text(alt.action.shortDisplayString(toCall: result.toCall))
                            .font(.caption)
                            .foregroundColor(.primary)

                        Spacer()

                        Text(formatEV(alt.expectedValue))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(alt.expectedValue >= 0 ? .green : .red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }

    // MARK: – Footer

    private var footerRow: some View {
        HStack {
            // Street badge
            Text(result.street.rawValue.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(streetColor.opacity(0.15))
                .foregroundColor(streetColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if let settings = gameViewModel.settings {
                Text(settings.calculationDepth.confidenceLevel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(String(format: "%.2f", result.calculationTime))s")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
    }

    // MARK: – Helpers

    private var actionColor: Color {
        switch result.action {
        case .fold: return .red
        case .call: return result.toCall == 0 ? Color(red: 0.15, green: 0.65, blue: 0.45) : Color(red: 0.2, green: 0.5, blue: 0.9)
        case .raise: return Color(red: 0.15, green: 0.65, blue: 0.35)
        }
    }

    private var actionIcon: String {
        switch result.action {
        case .fold: return "xmark.circle.fill"
        case .call: return result.toCall == 0 ? "checkmark.square.fill" : "checkmark.circle.fill"
        case .raise: return "arrow.up.circle.fill"
        }
    }

    private var evLabel: String {
        let ev = result.expectedValue
        if ev >= 0 {
            return "Expected: +$\(String(format: "%.2f", ev))"
        } else {
            return "Expected: -$\(String(format: "%.2f", -ev))"
        }
    }

    private var streetColor: Color {
        switch result.street {
        case .preflop: return .blue
        case .flop: return .green
        case .turn: return .orange
        case .river: return .red
        }
    }

    private var sprColor: Color {
        if result.spr < 3 { return .red }
        if result.spr < 8 { return .orange }
        return .green
    }

    private var equityColor: Color {
        switch result.equity {
        case 0.7...: return .green
        case 0.5..<0.7: return Color(red: 0.6, green: 0.75, blue: 0.1)
        case 0.35..<0.5: return .orange
        default: return .red
        }
    }

    private func formatEV(_ ev: Double) -> String {
        ev >= 0
            ? "+$\(String(format: "%.2f", ev))"
            : "-$\(String(format: "%.2f", -ev))"
    }

    private func iconForAction(_ action: CalculationResult.RecommendedAction, toCall: Double) -> String {
        switch action {
        case .fold: return "xmark.circle.fill"
        case .call: return toCall == 0 ? "checkmark.square.fill" : "checkmark.circle.fill"
        case .raise: return "arrow.up.circle.fill"
        }
    }

    private func colorForAction(_ action: CalculationResult.RecommendedAction, toCall: Double) -> Color {
        switch action {
        case .fold: return .red
        case .call: return toCall == 0 ? Color(red: 0.15, green: 0.65, blue: 0.45) : Color(red: 0.2, green: 0.5, blue: 0.9)
        case .raise: return Color(red: 0.15, green: 0.65, blue: 0.35)
        }
    }
}

struct EquityBar: View {
    let percentage: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))

                RoundedRectangle(cornerRadius: 4)
                    .fill(equityGradient)
                    .frame(width: geometry.size.width * CGFloat(min(percentage, 1.0)))
                    .animation(.easeOut(duration: 0.4), value: percentage)
            }
        }
        .frame(height: 7)
    }

    private var equityGradient: LinearGradient {
        let color: Color = {
            switch percentage {
            case 0.7...: return .green
            case 0.5..<0.7: return Color(red: 0.6, green: 0.75, blue: 0.1)
            case 0.35..<0.5: return .orange
            default: return .red
            }
        }()
        return LinearGradient(
            colors: [color.opacity(0.8), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
