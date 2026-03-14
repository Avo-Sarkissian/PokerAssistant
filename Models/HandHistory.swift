import Foundation

// MARK: - Hand Record

/// A snapshot of one analyzed hand and its recommended action.
struct HandRecord: Identifiable, Codable {
    let id: UUID
    let timestamp: Date

    // Cards
    let holeCards: [String]       // displayString, e.g. ["A♠", "K♥"]
    let communityCards: [String]

    // Situation
    let street: String
    let position: String
    let potSize: Double
    let toCall: Double

    // Result
    let equity: Double
    let recommendedAction: String  // "Fold", "Call", "Raise $X.XX"
    let reasoning: String

    init(
        holeCards: [Card],
        communityCards: [Card],
        street: Street,
        position: String,
        potSize: Double,
        toCall: Double,
        equity: Double,
        action: CalculationResult.RecommendedAction,
        reasoning: String
    ) {
        self.id            = UUID()
        self.timestamp     = Date()
        self.holeCards     = holeCards.map { $0.displayString }
        self.communityCards = communityCards.map { $0.displayString }
        self.street        = street.rawValue.capitalized
        self.position      = position
        self.potSize       = potSize
        self.toCall        = toCall
        self.equity        = equity
        self.reasoning     = reasoning

        switch action {
        case .fold:             self.recommendedAction = "Fold"
        case .call:             self.recommendedAction = toCall == 0 ? "Check" : "Call"
        case .raise(let amt):   self.recommendedAction = String(format: "Raise $%.2f", amt)
        }
    }

    var equityPercent: String { String(format: "%.1f%%", equity * 100) }
}

// MARK: - Hand Session

/// Groups hand records from a single playing session (app launch).
struct HandSession: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    var records: [HandRecord]

    init() {
        self.id        = UUID()
        self.startedAt = Date()
        self.records   = []
    }

    var handCount: Int { records.count }

    var averageEquity: Double {
        guard !records.isEmpty else { return 0 }
        return records.map(\.equity).reduce(0, +) / Double(records.count)
    }

    var winRateByAction: (folds: Int, calls: Int, raises: Int) {
        var f = 0, c = 0, r = 0
        for rec in records {
            if rec.recommendedAction == "Fold"  { f += 1 }
            else if rec.recommendedAction.hasPrefix("Raise") { r += 1 }
            else { c += 1 }
        }
        return (f, c, r)
    }

    /// Display title: "Session – Mar 14"
    var displayTitle: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "Session – \(fmt.string(from: startedAt))"
    }
}
