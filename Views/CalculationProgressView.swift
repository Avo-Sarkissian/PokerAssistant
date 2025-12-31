import SwiftUI

struct CalculationProgressView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    
    var body: some View {
        VStack(spacing: 15) {
            Text("CALCULATING...")
                .font(.headline)
            
            // Simulation count
            if let settings = gameViewModel.settings {
                Text("Running \(formatIterations(settings.calculationDepth.iterations)) simulations")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Overall progress bar
            ProgressView(value: overallProgress)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 8)
            
            VStack(alignment: .leading, spacing: 10) {
                ProgressStageView(
                    stage: .basicMath,
                    currentStage: gameViewModel.progressUpdate?.stage,
                    timeElapsed: gameViewModel.stageTimings[.basicMath] ?? currentStageTime(for: .basicMath),
                    isComplete: isStageComplete(.basicMath)
                )
                
                ProgressStageView(
                    stage: .winPercentage,
                    currentStage: gameViewModel.progressUpdate?.stage,
                    timeElapsed: gameViewModel.stageTimings[.winPercentage] ?? currentStageTime(for: .winPercentage),
                    isComplete: isStageComplete(.winPercentage)
                )
                
                ProgressStageView(
                    stage: .bestStrategy,
                    currentStage: gameViewModel.progressUpdate?.stage,
                    timeElapsed: gameViewModel.stageTimings[.bestStrategy] ?? currentStageTime(for: .bestStrategy),
                    isComplete: isStageComplete(.bestStrategy)
                )
                
                ProgressStageView(
                    stage: .fineTuning,
                    currentStage: gameViewModel.progressUpdate?.stage,
                    timeElapsed: gameViewModel.stageTimings[.fineTuning] ?? currentStageTime(for: .fineTuning),
                    isComplete: isStageComplete(.fineTuning)
                )
            }
            
            // SHOW INTERMEDIATE RESULT IMMEDIATELY
            if let intermediateResult = gameViewModel.progressUpdate?.intermediateResult {
                VStack(spacing: 10) {
                    Divider()
                    
                    Text("PRELIMINARY RESULT")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Image(systemName: iconForAction(intermediateResult.action))
                            .font(.title)
                            .foregroundColor(colorForAction(intermediateResult.action))
                        
                        Text(intermediateResult.action.displayString)
                            .font(.title2)
                            .bold()
                    }
                    
                    Text("Confidence: \(intermediateResult.confidence.displayString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let equity = gameViewModel.progressUpdate?.preliminaryEquity {
                        Text("Win Rate: \(Int(equity * 100))%")
                            .font(.headline)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private func formatIterations(_ count: Int) -> String {
        if count >= 1_000_000 {
            return "\(count / 1_000_000)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }
    
    private func iconForAction(_ action: CalculationResult.RecommendedAction) -> String {
        switch action {
        case .fold: return "xmark.circle.fill"
        case .call: return "checkmark.circle.fill"
        case .raise: return "arrow.up.circle.fill"
        }
    }
    
    private func colorForAction(_ action: CalculationResult.RecommendedAction) -> Color {
        switch action {
        case .fold: return .red
        case .call: return .yellow
        case .raise: return .green
        }
    }
    
    private var overallProgress: Double {
        guard let update = gameViewModel.progressUpdate else { return 0 }
        let stageWeight = 0.25
        let baseProgress = Double(update.stage.ordinal) * stageWeight
        let stageProgress = update.progress * stageWeight
        return min(baseProgress + stageProgress, 1.0)
    }
    
    private func currentStageTime(for stage: ProgressUpdate.CalculationStage) -> TimeInterval {
        guard let update = gameViewModel.progressUpdate,
              update.stage == stage else { return 0 }
        return update.timeElapsed
    }
    
    private func isStageComplete(_ stage: ProgressUpdate.CalculationStage) -> Bool {
        guard let update = gameViewModel.progressUpdate else { return false }
        return stage.ordinal < update.stage.ordinal ||
               (stage == update.stage && update.isComplete)
    }
}

struct ProgressStageView: View {
    let stage: ProgressUpdate.CalculationStage
    let currentStage: ProgressUpdate.CalculationStage?
    let timeElapsed: TimeInterval
    let isComplete: Bool
    
    private var isActive: Bool {
        stage == currentStage && !isComplete
    }
    
    var body: some View {
        HStack {
            Image(systemName: isComplete ? "checkmark.circle.fill" : isActive ? "circle.fill" : "circle")
                .foregroundColor(isComplete ? .green : isActive ? .blue : .gray)
                .font(.system(size: 14))
            
            Text(stage.rawValue)
                .font(.system(size: 14))
                .foregroundColor(isActive ? .primary : .secondary)
            
            Spacer()
            
            if timeElapsed > 0 {
                Text(String(format: "%.1fs", timeElapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

extension ProgressUpdate.CalculationStage {
    var ordinal: Int {
        switch self {
        case .basicMath: return 0
        case .winPercentage: return 1
        case .bestStrategy: return 2
        case .fineTuning: return 3
        }
    }
}
