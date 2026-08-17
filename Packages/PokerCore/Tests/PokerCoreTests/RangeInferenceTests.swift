import Testing
import Foundation
import PokerCore

@Suite("Range inference input")
struct RangeInferenceTests {

    /// The thresholds in `OpponentRange.rangeFromAction` are calibrated against "villain
    /// bet X% of the pot". Measuring the bet against the pot it is already sitting
    /// inside makes a pot-sized bet read as 50%, which shifts every postflop read one
    /// or two tiers looser.
    @Test("A bet is measured against the pot it was bet into",
          arguments: [(0.33, 0.33), (0.5, 0.5), (0.75, 0.75), (1.0, 1.0), (1.5, 1.5)])
    func betFractionIsRelativeToPotBeforeBet(applied: Double, expected: Double) {
        var entry = PotEntry(potBeforeBet: 20, toCall: 0)
        entry.applyOpponentBet(fractionOfPot: applied)

        #expect(abs(entry.betFractionOfPotBeforeBet - expected) < 1e-9,
                "a \(applied) pot bet reported as \(entry.betFractionOfPotBeforeBet)")
    }

    /// The postflop tiers each sizing should land in. Values are chosen inside each
    /// band rather than on a boundary: `rangeFromAction` compares with a strict `>`,
    /// so a bet of exactly half pot sits on the `.wide`/`.standard` edge. Those
    /// thresholds are long-standing and not re-tuned here.
    @Test("Postflop sizings infer the intended range",
          arguments: [
            (0.20, OpponentRange.RangeType.veryWide),
            (0.33, OpponentRange.RangeType.wide),
            (0.60, OpponentRange.RangeType.standard),
            (0.75, OpponentRange.RangeType.standard),
            (1.00, OpponentRange.RangeType.tight),
          ])
    func postflopSizingInfersRange(fraction: Double, expected: OpponentRange.RangeType) {
        var entry = PotEntry(potBeforeBet: 20, toCall: 0)
        entry.applyOpponentBet(fractionOfPot: fraction)

        let inferred = OpponentRange.postflopRange(
            potRelativeBet: entry.betFractionOfPotBeforeBet)
        #expect(inferred == expected,
                "\(fraction) pot inferred \(inferred), expected \(expected)")
    }

    /// The property that actually matters, independent of where the boundaries sit:
    /// a larger bet must never be read as a looser range.
    @Test("A bigger bet is never read as a looser range")
    func rangeTightensMonotonically() {
        let tiers: [OpponentRange.RangeType] = [.veryWide, .wide, .standard, .tight, .veryTight]
        func tierIndex(_ r: OpponentRange.RangeType) -> Int { tiers.firstIndex(of: r) ?? -1 }

        var previous = -1
        for step in stride(from: 0.1, through: 2.0, by: 0.05) {
            var entry = PotEntry(potBeforeBet: 20, toCall: 0)
            entry.applyOpponentBet(fractionOfPot: step)
            let index = tierIndex(OpponentRange.postflopRange(
                potRelativeBet: entry.betFractionOfPotBeforeBet))

            #expect(index >= previous,
                    "a \(String(format: "%.2f", step)) pot bet loosened the read")
            previous = max(previous, index)
        }
    }

    /// Preflop the pot is only the blinds, so a bet measured against it saturates
    /// immediately: the big blind alone is twice the 0.5bb sitting in front of the
    /// button, which read as a 3-bet range inferred from nobody acting. Preflop reads
    /// are in big blinds.
    @Test("An unopened pot is not read as a raise",
          arguments: ["BTN", "SB", "BB"])
    func unopenedPotIsNotARaise(position: String) {
        let entry = PotEntry.blindsOnly(heroPosition: position, smallBlind: 0.5, bigBlind: 1.0)
        // Villain's street total is what hero must reach to call: their blind plus
        // whatever hero still owes.
        let heroBlind = position == "SB" ? 0.5 : (position == "BB" ? 1.0 : 0.0)
        let villainWager = entry.toCall + heroBlind

        let inferred = OpponentRange.preflopRange(villainWagerInBigBlinds: villainWager / 1.0)
        #expect(inferred == .random,
                "\(position) with nobody acting inferred \(inferred)")
    }

    /// Each line has to land in its own tier, strictly tighter than the one before.
    /// Collapsing them all into `.veryTight` throws away the whole read.
    @Test("Each preflop line reads as its own, progressively tighter range")
    func preflopLinesAreDistinctAndOrdered() {
        let tiers: [OpponentRange.RangeType] = [.random, .veryWide, .wide, .standard, .tight, .veryTight]
        func tightness(_ r: OpponentRange.RangeType) -> Int { tiers.firstIndex(of: r) ?? -1 }

        let reads = [PreflopPreset.limp, .open, .threeBet, .fourBet].map { preset -> (String, OpponentRange.RangeType) in
            (preset.rawValue, OpponentRange.preflopRange(villainWagerInBigBlinds: preset.villainWager))
        }

        for (looser, tighter) in zip(reads, reads.dropFirst()) {
            #expect(tightness(tighter.1) > tightness(looser.1),
                    "\(tighter.0) read \(tighter.1), no tighter than \(looser.0)'s \(looser.1)")
        }
        #expect(Set(reads.map(\.1)).count == reads.count,
                Comment(rawValue: "lines collapsed into the same tier: "
                        + reads.map { "\($0.0) \($0.1)" }.joined(separator: ", ")))
    }

    /// A read in blinds is scale-free: the same line at 2.50/5.00 reads the same as at
    /// 0.50/1.00. Measured against a pot of blinds it would not.
    @Test("The preflop read does not change with the stake")
    func preflopReadIsScaleFree() {
        for preset in PreflopPreset.allCases {
            let low = PotEntry.preflop(preset, heroPosition: "BTN", smallBlind: 0.5, bigBlind: 1.0)
            let high = PotEntry.preflop(preset, heroPosition: "BTN", smallBlind: 2.5, bigBlind: 5.0)

            let atOne = OpponentRange.preflopRange(villainWagerInBigBlinds: low.toCall / 1.0)
            let atFive = OpponentRange.preflopRange(villainWagerInBigBlinds: high.toCall / 5.0)

            #expect(atOne == atFive, "\(preset.rawValue): \(atOne) at 0.50/1.00, \(atFive) at 2.50/5.00")
        }
    }

    /// The property that matters wherever the boundaries sit: a bigger raise is never a
    /// looser read.
    @Test("A bigger preflop raise is never read as a looser range")
    func preflopReadTightensMonotonically() {
        let tiers: [OpponentRange.RangeType] = [.random, .veryWide, .wide, .standard, .tight, .veryTight]
        func tightness(_ r: OpponentRange.RangeType) -> Int { tiers.firstIndex(of: r) ?? -1 }

        var previous = -1
        for wager in stride(from: 0.5, through: 40.0, by: 0.5) {
            let index = tightness(OpponentRange.preflopRange(villainWagerInBigBlinds: wager))
            #expect(index >= previous,
                    "a \(String(format: "%.1f", wager))bb wager loosened the read")
            previous = max(previous, index)
        }
    }

    /// The unopened pot: just the posted blinds, nobody has raised.
    @Test("Blinds-only spots price correctly",
          arguments: [("BTN", 1.5, 1.0, 0.4), ("SB", 1.5, 0.5, 0.25), ("BB", 1.5, 0.0, 0.0)])
    func blindsOnlySpots(position: String, total: Double, call: Double, requiredEquity: Double) {
        let entry = PotEntry.blindsOnly(heroPosition: position, smallBlind: 0.5, bigBlind: 1.0)

        #expect(abs(entry.totalPot - total) < 1e-9, "\(position) total \(entry.totalPot)")
        #expect(abs(entry.toCall - call) < 1e-9, "\(position) call \(entry.toCall)")
        #expect(abs(entry.requiredEquity - requiredEquity) < 1e-9,
                "\(position) required \(entry.requiredEquity)")
    }
}
