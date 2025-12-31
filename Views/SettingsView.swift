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
                
                Section("Optional Features") {
                    Toggle("Track Opponents", isOn: $settings.trackOpponents)
                    Toggle("Show Math Details", isOn: $settings.showMathDetails)
                    Toggle("Simple Explanations", isOn: $settings.simpleExplanations)
                    Toggle("Progressive Results", isOn: $settings.progressiveResults)
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
