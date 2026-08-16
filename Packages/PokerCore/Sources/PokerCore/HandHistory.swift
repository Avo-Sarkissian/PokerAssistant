import Foundation

// MARK: - Hand Record

/// A snapshot of one analyzed hand and its recommended action.
public struct HandRecord: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date

    // Cards
    public let holeCards: [String]       // displayString, e.g. ["A♠", "K♥"]
    public let communityCards: [String]

    // Situation
    public let street: String
    public let position: String
    public let potSize: Double
    public let toCall: Double

    // Result
    public let equity: Double
    public let recommendedAction: String  // "Fold", "Call", "Raise $X.XX"
    public let reasoning: String

    public init(
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

    public var equityPercent: String { String(format: "%.1f%%", equity * 100) }
}

// MARK: - Hand Session

/// Groups hand records from a single playing session (app launch).
public struct HandSession: Identifiable, Codable {
    public let id: UUID
    public let startedAt: Date
    public var records: [HandRecord]

    public init() {
        self.id        = UUID()
        self.startedAt = Date()
        self.records   = []
    }

    public var handCount: Int { records.count }

    public var averageEquity: Double {
        guard !records.isEmpty else { return 0 }
        return records.map(\.equity).reduce(0, +) / Double(records.count)
    }

    public var winRateByAction: (folds: Int, calls: Int, raises: Int) {
        var f = 0, c = 0, r = 0
        for rec in records {
            if rec.recommendedAction == "Fold"  { f += 1 }
            else if rec.recommendedAction.hasPrefix("Raise") { r += 1 }
            else { c += 1 }
        }
        return (f, c, r)
    }

    /// Display title: "Session – Mar 14"
    public var displayTitle: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "Session – \(fmt.string(from: startedAt))"
    }
}
