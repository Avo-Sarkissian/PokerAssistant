import Testing
import Foundation
import PokerCore

@Suite("Pot entry")
struct PotEntryTests {

    @Test("The total pot includes the outstanding bet")
    func totalIncludesTheBet() {
        let entry = PotEntry(potBeforeBet: 10, toCall: 7.5)
        #expect(entry.totalPot == 17.5)
    }

    /// The price of calling a 75% pot bet is 30%, not the 42.9% the app used to show
    /// by treating the displayed pot as if the bet were not in it.
    @Test("A 75% pot bet costs 30% equity to call")
    func threeQuarterPotPrice() {
        var entry = PotEntry(potBeforeBet: 10, toCall: 0)
        entry.applyOpponentBet(fractionOfPot: 0.75)

        #expect(entry.toCall == 7.5)
        #expect(entry.totalPot == 17.5)
        #expect(abs(entry.requiredEquity - 0.30) < 1e-9,
                "required equity was \(entry.requiredEquity)")
    }

    @Test("Standard bet sizings price correctly",
          arguments: [(0.33, 0.1985), (0.5, 0.25), (0.75, 0.30), (1.0, 1.0 / 3.0)])
    func betSizingLadder(fraction: Double, expected: Double) {
        var entry = PotEntry(potBeforeBet: 20, toCall: 0)
        entry.applyOpponentBet(fractionOfPot: fraction)
        #expect(abs(entry.requiredEquity - expected) < 0.001,
                "\(fraction) of pot gave \(entry.requiredEquity), expected \(expected)")
    }

    /// Tapping the same sizing twice must not compound.
    @Test("Applying a bet sizing twice is idempotent")
    func betSizingIsIdempotent() {
        var entry = PotEntry(potBeforeBet: 10, toCall: 0)
        entry.applyOpponentBet(fractionOfPot: 0.75)
        let once = entry
        entry.applyOpponentBet(fractionOfPot: 0.75)

        #expect(entry == once)
    }

    /// A shove for four times the pot is a legal bet and has to be enterable.
    @Test("Overbets and shoves survive entry")
    func overbetsAreNotClamped() {
        var entry = PotEntry(potBeforeBet: 50, toCall: 0)
        entry.setCall(200)

        #expect(entry.toCall == 200)
        #expect(entry.totalPot == 250)
        #expect(abs(entry.requiredEquity - (200.0 / 450.0)) < 1e-9)
    }

    @Test("Entering the bet before the pot does not destroy it")
    func entryOrderDoesNotMatter() {
        var first = PotEntry(potBeforeBet: 0, toCall: 0)
        first.setCall(200)
        first.setPotBeforeBet(50)

        var second = PotEntry(potBeforeBet: 0, toCall: 0)
        second.setPotBeforeBet(50)
        second.setCall(200)

        #expect(first == second)
        #expect(first.toCall == 200)
    }

    @Test("Checking is free and has no price")
    func checkingHasNoPrice() {
        let entry = PotEntry(potBeforeBet: 12, toCall: 0)
        #expect(entry.requiredEquity == 0)
        #expect(entry.potOddsRatio == nil)
    }
}

// MARK: - Preflop presets

@Suite("Preflop presets")
struct PreflopPresetTests {

    /// Independently derived and cross-checked: pot and cost-to-call in big blinds
    /// for each preset and hero seat, with the required equity each implies.
    /// The BB-versus-2.5x-open cell at 27.3% is the textbook defence price.
    @Test("Presets reproduce the derived pot odds",
          arguments: [
            (PreflopPreset.limp,     Position.btn, 2.5,  1.0,  0.2857),
            (PreflopPreset.limp,     Position.sb,  2.5,  0.5,  0.1667),
            (PreflopPreset.limp,     Position.bb,  2.5,  0.0,  0.0),
            (PreflopPreset.open,     Position.btn, 4.0,  2.5,  0.3846),
            (PreflopPreset.open,     Position.sb,  4.0,  2.0,  0.3333),
            (PreflopPreset.open,     Position.bb,  4.0,  1.5,  0.2727),
            (PreflopPreset.threeBet, Position.btn, 12.0, 6.5,  0.3514),
            (PreflopPreset.threeBet, Position.sb,  11.5, 6.5,  0.3611),
            (PreflopPreset.threeBet, Position.bb,  12.0, 6.5,  0.3514),
            (PreflopPreset.fourBet,  Position.btn, 35.5, 16.0, 0.3107),
            (PreflopPreset.fourBet,  Position.sb,  35.0, 16.0, 0.3140),
            (PreflopPreset.fourBet,  Position.bb,  34.5, 16.0, 0.3171),
          ])
    func presetPotOdds(preset: PreflopPreset, position: Position,
                       expectedTotal: Double, expectedCall: Double, expectedEquity: Double) {
        let entry = PotEntry.preflop(preset, heroPosition: position,
                                     smallBlind: 0.5, bigBlind: 1.0)

        #expect(abs(entry.totalPot - expectedTotal) < 1e-9,
                "\(preset.rawValue)/\(position.rawValue): total pot \(entry.totalPot), expected \(expectedTotal)")
        #expect(abs(entry.toCall - expectedCall) < 1e-9,
                "\(preset.rawValue)/\(position.rawValue): to call \(entry.toCall), expected \(expectedCall)")
        #expect(abs(entry.requiredEquity - expectedEquity) < 0.0005,
                "\(preset.rawValue)/\(position.rawValue): required equity \(entry.requiredEquity), expected \(expectedEquity)")
    }

    /// No preset may land on exactly 50%, which is the signature of the old bug that
    /// set the pot equal to the call in every line.
    @Test("No preset demands a coin flip to continue")
    func noPresetDemandsFiftyPercent() {
        for preset in PreflopPreset.allCases {
            for position in Position.allCases {
                let entry = PotEntry.preflop(preset, heroPosition: position,
                                             smallBlind: 0.5, bigBlind: 1.0)
                #expect(abs(entry.requiredEquity - 0.5) > 0.01,
                        "\(preset.rawValue)/\(position.rawValue) needs \(entry.requiredEquity)")
            }
        }
    }

    @Test("Presets scale with the blind level")
    func presetsScaleWithBlinds() {
        let atOne = PotEntry.preflop(.open, heroPosition: .bb, smallBlind: 0.5, bigBlind: 1.0)
        let atFive = PotEntry.preflop(.open, heroPosition: .bb, smallBlind: 2.5, bigBlind: 5.0)

        #expect(abs(atFive.totalPot - atOne.totalPot * 5) < 1e-9)
        #expect(abs(atFive.toCall - atOne.toCall * 5) < 1e-9)
        // Price is scale-free.
        #expect(abs(atFive.requiredEquity - atOne.requiredEquity) < 1e-9)
    }
}
