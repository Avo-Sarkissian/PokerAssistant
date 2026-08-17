import Foundation

public struct Hand: Sendable {
    public let holeCards: [Card]
    public let communityCards: [Card]

    public init(holeCards: [Card], communityCards: [Card]) {
        self.holeCards = holeCards
        self.communityCards = communityCards
    }

    public var allCards: [Card] {
        holeCards + communityCards
    }

    public var isValid: Bool {
        holeCards.count == 2 && communityCards.count <= 5 && !hasDuplicateCards
    }

    /// The same card appearing twice across hole cards and board — an impossible deal.
    ///
    /// Worth an explicit check because nothing downstream will raise one: every engine
    /// builds the remaining deck from a set of 0–51 indices, so a duplicate silently
    /// collapses there while still being scored twice in the hand itself. Duplicate hole
    /// cards were answered with a confident 76.82%.
    public var hasDuplicateCards: Bool {
        let all = allCards
        return Set(all).count != all.count
    }

    public var street: Street {
        switch communityCards.count {
        case 0: return .preflop
        case 3: return .flop
        case 4: return .turn
        case 5: return .river
        default: return .preflop
        }
    }
}

public enum Street: String, CaseIterable, Sendable {
    case preflop = "Pre-flop"
    case flop = "Flop"
    case turn = "Turn"
    case river = "River"
}
