import SwiftUI
import PokerCore

struct HandHistoryView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showingClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if gameViewModel.allSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Hand History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !gameViewModel.allSessions.isEmpty {
                        Button(role: .destructive) {
                            showingClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear all hand history?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    gameViewModel.clearHistory()
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Hands Yet")
                .font(.title2)
                .bold()
            Text("Your analyzed hands will appear here after you calculate.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            ForEach(gameViewModel.allSessions.reversed()) { session in
                Section {
                    ForEach(session.records.reversed()) { record in
                        HandRecordRow(record: record)
                    }
                } header: {
                    HStack {
                        Text(session.displayTitle)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(session.handCount) hands · avg \(String(format: "%.0f%%", session.averageEquity * 100)) equity")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Hand Record Row

struct HandRecordRow: View {
    let record: HandRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Cards
                Text(record.holeCards.joined(separator: " "))
                    .font(.system(.subheadline, design: .monospaced))
                    .bold()

                if !record.communityCards.isEmpty {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(record.communityCards.prefix(5).joined(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Action badge
                Text(record.recommendedAction)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(actionColor(record.recommendedAction).opacity(0.2))
                    .foregroundColor(actionColor(record.recommendedAction))
                    .clipShape(Capsule())
            }

            HStack(spacing: 12) {
                Label(record.street, systemImage: "suit.club.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Label(record.position, systemImage: "person.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Label(record.equityPercent, systemImage: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundColor(equityColor(record.equity))

                Spacer()

                Text(record.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func actionColor(_ action: String) -> Color {
        if action == "Fold"           { return .red }
        if action.hasPrefix("Raise")  { return .green }
        return .blue
    }

    private func equityColor(_ equity: Double) -> Color {
        switch equity {
        case 0.65...: return .green
        case 0.45..<0.65: return .orange
        default: return .red
        }
    }
}
