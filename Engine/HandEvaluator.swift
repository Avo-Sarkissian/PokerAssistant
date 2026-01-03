import Foundation

class HandEvaluator {
    enum HandRank: Int, Comparable {
        case highCard = 0
        case pair = 1
        case twoPair = 2
        case threeOfAKind = 3
        case straight = 4
        case flush = 5
        case fullHouse = 6
        case fourOfAKind = 7
        case straightFlush = 8
        
        static func < (lhs: HandRank, rhs: HandRank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    struct HandValue: Comparable {
        let rank: HandRank
        let tieBreakers: [Int]
        
        static func < (lhs: HandValue, rhs: HandValue) -> Bool {
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            
            for (l, r) in zip(lhs.tieBreakers, rhs.tieBreakers) {
                if l != r {
                    return l < r
                }
            }
            
            return false
        }
        
        static func == (lhs: HandValue, rhs: HandValue) -> Bool {
            lhs.rank == rhs.rank && lhs.tieBreakers == rhs.tieBreakers
        }
    }
    
    func evaluate(_ cards: [Card]) -> HandValue {
        guard cards.count >= 5 else {
            return HandValue(rank: .highCard, tieBreakers: cards.map { $0.rank.rawValue }.sorted(by: >))
        }
        
        // For now, use simplified evaluation
        // This is much faster than checking all combinations
        return evaluateBestHand(cards)
    }
    
    private func evaluateBestHand(_ cards: [Card]) -> HandValue {
        let sortedCards = cards.sorted { $0.rank.rawValue > $1.rank.rawValue }
        
        // Count ranks
        var rankCounts: [Rank: Int] = [:]
        for card in cards {
            rankCounts[card.rank, default: 0] += 1
        }
        
        // Sort by count then rank
        let sortedRanks = rankCounts.sorted {
            if $0.value != $1.value {
                return $0.value > $1.value
            }
            return $0.key.rawValue > $1.key.rawValue
        }
        
        // Check for flush
        var suitCounts: [Suit: Int] = [:]
        for card in cards {
            suitCounts[card.suit, default: 0] += 1
        }
        let hasFlush = suitCounts.values.contains { $0 >= 5 }
        
        // Check for straight
        let uniqueRanks = Set(cards.map { $0.rank.rawValue }).sorted(by: >)
        var hasStraight = false
        var straightHighCard = 0
        
        // Only check for straight if we have at least 5 unique ranks
        if uniqueRanks.count >= 5 {
            for i in 0...(uniqueRanks.count - 5) {
                let slice = Array(uniqueRanks[i..<(i + 5)])
                if let first = slice.first, let last = slice.last,
                   slice.count == 5 && first - last == 4 {
                    hasStraight = true
                    straightHighCard = first
                    break
                }
            }
            
            // Check for wheel (A-2-3-4-5)
            if uniqueRanks.contains(14) && uniqueRanks.contains(2) &&
               uniqueRanks.contains(3) && uniqueRanks.contains(4) && uniqueRanks.contains(5) {
                hasStraight = true
                straightHighCard = 5
            }
        }
        
        // Determine hand rank
        if hasFlush && hasStraight {
            return HandValue(rank: .straightFlush, tieBreakers: [straightHighCard])
        }
        
        if sortedRanks.count > 0 && sortedRanks[0].value == 4 {
            let quadRank = sortedRanks[0].key.rawValue
            let kicker = sortedCards.first { $0.rank.rawValue != quadRank }?.rank.rawValue ?? 0
            return HandValue(
                rank: .fourOfAKind,
                tieBreakers: [quadRank, kicker]
            )
        }
        
        if sortedRanks.count >= 2 && sortedRanks[0].value == 3 && sortedRanks[1].value >= 2 {
            return HandValue(
                rank: .fullHouse,
                tieBreakers: [sortedRanks[0].key.rawValue, sortedRanks[1].key.rawValue]
            )
        }
        
        if hasFlush, let flushSuit = suitCounts.first(where: { $0.value >= 5 })?.key {
            let flushCards = cards.filter { $0.suit == flushSuit }.sorted { $0.rank.rawValue > $1.rank.rawValue }
            return HandValue(
                rank: .flush,
                tieBreakers: Array(flushCards.prefix(5).map { $0.rank.rawValue })
            )
        }
        
        if hasStraight {
            return HandValue(rank: .straight, tieBreakers: [straightHighCard])
        }
        
        if sortedRanks.count > 0 && sortedRanks[0].value == 3 {
            let tripRank = sortedRanks[0].key.rawValue
            let kickers = sortedCards.filter { $0.rank.rawValue != tripRank }.prefix(2).map { $0.rank.rawValue }
            return HandValue(
                rank: .threeOfAKind,
                tieBreakers: [tripRank] + Array(kickers)
            )
        }
        
        if sortedRanks.count >= 2 && sortedRanks[0].value == 2 && sortedRanks[1].value == 2 {
            let pair1 = sortedRanks[0].key.rawValue
            let pair2 = sortedRanks[1].key.rawValue
            let kicker = sortedCards.first { $0.rank.rawValue != pair1 && $0.rank.rawValue != pair2 }?.rank.rawValue ?? 0
            return HandValue(
                rank: .twoPair,
                tieBreakers: [max(pair1, pair2), min(pair1, pair2), kicker]
            )
        }
        
        if sortedRanks.count > 0 && sortedRanks[0].value == 2 {
            let pairRank = sortedRanks[0].key.rawValue
            let kickers = sortedCards.filter { $0.rank.rawValue != pairRank }.prefix(3).map { $0.rank.rawValue }
            return HandValue(
                rank: .pair,
                tieBreakers: [pairRank] + Array(kickers)
            )
        }
        
        return HandValue(
            rank: .highCard,
            tieBreakers: Array(sortedCards.prefix(5).map { $0.rank.rawValue })
        )
    }
}
