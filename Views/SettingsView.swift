import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Game Setup") {
                    HStack {
                        Text("Buy-in")
                        Spacer()
                        TextField("Buy-in", value: $settings.buyIn, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Text("Small Blind")
                        Spacer()
                        TextField("SB", value: $settings.smallBlind, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Text("Big Blind")
                        Spacer()
                        TextField("BB", value: $settings.bigBlind, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    Picker("Players at Table", selection: $settings.numberOfPlayers) {
                        ForEach(2...9, id: \.self) { count in
                            Text("\(count) players").tag(count)
                        }
                    }
                    
                    // Show opponent count
                    HStack {
                        Text("Opponents to beat")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(settings.numberOfOpponents)")
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
                
                // Only show depth settings for heads-up (2 players)
                // Multi-way pots use fast GPU path where depth doesn't matter
                if settings.numberOfPlayers == 2 {
                    Section {
                        Picker("Calculation Depth", selection: $settings.calculationDepth) {
                            ForEach(Settings.CalculationDepth.allCases, id: \.self) { depth in
                                Text(depth.rawValue).tag(depth)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Simulations:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(settings.calculationDepth.description)
                                    .bold()
                            }

                            HStack {
                                Text("Accuracy:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(settings.calculationDepth.confidenceLevel)
                                    .foregroundColor(.green)
                                    .bold()
                            }
                        }
                        .font(.caption)
                        .padding(.vertical, 4)
                    } header: {
                        Text("Calculation Depth")
                    } footer: {
                        Text(depthFooterText)
                    }
                }
                
                // MARK: - Game Mode

                Section {
                    Picker("Game Mode", selection: $settings.gameMode) {
                        ForEach(GameMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.gameMode == .tournament {
                        Picker("Tournament Phase", selection: $settings.tournamentPhase) {
                            ForEach(TournamentPhase.allCases, id: \.self) { phase in
                                Text(phase.rawValue).tag(phase)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(settings.tournamentPhase.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if settings.tournamentPhase.icmPressure > 0 {
                                HStack {
                                    Text("ICM Pressure:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.0f%%", settings.tournamentPhase.icmPressure * 100))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(settings.tournamentPhase.icmPressure > 0.25 ? .red : .orange)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Game Mode")
                } footer: {
                    if settings.gameMode == .tournament {
                        Text("Tournament mode adjusts fold thresholds to account for ICM pressure and chip survival.")
                    } else {
                        Text("Cash game mode optimizes for EV without chip-survival constraints.")
                    }
                }

                Section("Optional Features") {
                    Toggle("Track Opponents", isOn: $settings.trackOpponents)
                    Toggle("Show Math Details", isOn: $settings.showMathDetails)
                    Toggle("Simple Explanations", isOn: $settings.simpleExplanations)
                    Toggle("Progressive Results", isOn: $settings.progressiveResults)
                }

                Section {
                    PerformanceMonitorSettingsView()
                } header: {
                    Text("Engine Performance")
                } footer: {
                    Text("Live diagnostics from the equity calculation engine.")
                }

                Section {
                } footer: {
                    Text("More players = harder to win. Your equity decreases with more opponents.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") { dismiss() })
        }
    }
    
    private var depthFooterText: String {
        switch settings.calculationDepth {
        case .fast:
            return "Quick estimate for rapid decisions. Good for obvious spots."
        case .accurate:
            return "Balanced speed and accuracy. Recommended for most situations."
        case .deep:
            return "High accuracy for important decisions."
        case .maximum:
            return "Maximum accuracy for critical all-in decisions."
        }
    }
}

// MARK: - Performance Monitor Settings Row

struct PerformanceMonitorSettingsView: View {
    @ObservedObject private var monitor = PerformanceMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Last Calc", systemImage: "cpu")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(monitor.lastCalcInfo)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            HStack {
                Label("Active Cores", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(monitor.activeCores)")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            HStack {
                Label("Compute", systemImage: "memorychip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(monitor.computeMode)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(monitor.isGPUActive ? .green : .secondary)
            }

            HStack {
                Label("Memory", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(monitor.memoryUsageMB) MB")
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .padding(.vertical, 4)
    }
}
