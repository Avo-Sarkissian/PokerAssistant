import SwiftUI

struct ResultView: View {
    let result: CalculationResult
    @EnvironmentObject var gameViewModel: GameViewModel
    @State private var showDetails = false
    
    var body: some View {
        VStack(spacing: 15) {
            // Main Recommendation
            VStack(spacing: 5) {
                Image(systemName: iconForAction(result.action, toCall: result.toCall))
                    .font(.system(size: 40))
                    .foregroundColor(colorForAction(result.action, toCall: result.toCall))
                
                Text(result.action.displayStringWithContext(toCall: result.toCall))
                    .font(.title2)
                    .bold()
                    .multilineTextAlignment(.center)
            }
            
            // Expected Result
            HStack {
                Text("Expected Result:")
                    .foregroundColor(.secondary)
                Text(result.expectedValue >= 0 ? "WIN $\(String(format: "%.2f", result.expectedValue))" : "LOSE $\(String(format: "%.2f", -result.expectedValue))")
                    .foregroundColor(result.expectedValue >= 0 ? .green : .red)
                    .bold()
            }
            
            // Win Percentage
            VStack(spacing: 5) {
                Text("Your Win Rate: \(Int(result.equity * 100))%")
                    .font(.headline)
                
                EquityBar(percentage: result.equity)
                
                // Accuracy indicator
                if let settings = gameViewModel.settings {
                    Text("Accuracy: \(settings.calculationDepth.confidenceLevel)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Pot odds comparison if facing a bet
                if gameViewModel.gameState.toCall > 0 {
                    let potOddsNeeded = gameViewModel.gameState.toCall / (gameViewModel.gameState.potSize + gameViewModel.gameState.toCall) * 100
                    HStack(spacing: 4) {
                        Text("Need \(Int(potOddsNeeded))% to call")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if result.equity * 100 >= potOddsNeeded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            
            // Position indicator
            HStack {
                Image(systemName: gameViewModel.gameState.isInPosition ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                    .foregroundColor(gameViewModel.gameState.isInPosition ? .green : .orange)
                Text(gameViewModel.gameState.isInPosition ? "In Position (acting last)" : "Out of Position (acting first)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Simple Reasoning
            Text("💡 \(result.reasoning)")
                .font(.caption)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            
            // Alternative Actions
            VStack(alignment: .leading, spacing: 8) {
                Text("Other Options:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(result.alternativeActions, id: \.action.displayString) { alternative in
                    HStack {
                        Text("• \(alternative.action.shortDisplayString(toCall: result.toCall)):")
                            .font(.caption)
                        Spacer()
                        Text(formatEV(alternative.expectedValue))
                            .foregroundColor(alternative.expectedValue >= 0 ? .green : .red)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Calculation time
            Text("Calculated in \(String(format: "%.2f", result.calculationTime))s")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private func formatEV(_ ev: Double) -> String {
        if ev >= 0 {
            return "+$\(String(format: "%.2f", ev))"
        } else {
            return "-$\(String(format: "%.2f", -ev))"
        }
    }
    
    private func iconForAction(_ action: CalculationResult.RecommendedAction, toCall: Double) -> String {
        switch action {
        case .fold: return "xmark.circle.fill"
        case .call:
            if toCall == 0 {
                return "checkmark.square.fill"
            }
            return "checkmark.circle.fill"
        case .raise: return "arrow.up.circle.fill"
        }
    }

    private func colorForAction(_ action: CalculationResult.RecommendedAction, toCall: Double) -> Color {
        switch action {
        case .fold: return .red
        case .call:
            if toCall == 0 {
                return .green
            }
            return .yellow
        case .raise: return .green
        }
    }
}

struct EquityBar: View {
    let percentage: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(equityColor)
                    .frame(width: geometry.size.width * CGFloat(percentage))
            }
        }
        .frame(height: 8)
    }
    
    private var equityColor: Color {
        switch percentage {
        case 0.7...: return .green
        case 0.5..<0.7: return .yellow
        case 0.35..<0.5: return .orange
        default: return .red
        }
    }
}
