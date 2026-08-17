import SwiftUI
import PokerCore

struct MainGameView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @State private var selectedCardIndex: CardSelectionType?
    // Position Toggle State
    @State private var selectedPosition: String = "BTN"
    let positions = ["BTN", "SB", "BB"]

    enum CardSelectionType: Identifiable {
        case hole(Int)
        case community(Int)

        var id: String {
            switch self {
            case .hole(let i): return "hole-\(i)"
            case .community(let i): return "community-\(i)"
            }
        }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                    
                    // --- POSITION & STACK HEADER ---
                    HStack(spacing: 12) {
                        // Position Toggle
                        VStack(alignment: .leading, spacing: 4) {
                            Text("POSITION")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Picker("Position", selection: $selectedPosition) {
                                ForEach(positions, id: \.self) { pos in
                                    Text(pos).tag(pos)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 200)
                            .onChange(of: selectedPosition) { _, newVal in
                                updateForPosition(newVal)
                            }
                        }

                        Spacer()

                        // Stack Display
                        StackInfoView()
                    }
                    .padding(.horizontal)

                    // Position explanation
                    Text(positionExplanation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    // --- HAND VIEW ---
                    YourHandView(onCardTap: { index in
                        selectedCardIndex = .hole(index)
                    })

                    // --- BOARD VIEW ---
                    CommunityCardsView(onCardTap: { index in
                        selectedCardIndex = .community(index)
                    })
                    
                    // --- OPPONENT STYLE (only when trackOpponents is enabled) ---
                    if settings.trackOpponents {
                        OpponentStyleSelector()
                    }

                    // --- POT CONTROLS ---
                    PotInfoViewEnhanced(selectedPosition: $selectedPosition)
                    
                    // --- ACTION BUTTON OR RESULT ---
                    if gameViewModel.isCalculating {
                        CalculationProgressView()
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else if let result = gameViewModel.calculationResult {
                        ResultView(result: result)
                            .id("result")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    CalculateButton()
                        .padding(.top, 4)
                        .animation(.easeInOut(duration: 0.3), value: gameViewModel.isCalculating)
                        .animation(.easeInOut(duration: 0.3), value: gameViewModel.calculationResult != nil)

                    // --- RESET BUTTON ---
                    Button(action: {
                        gameViewModel.resetHand()
                        selectedPosition = "BTN"
                    }) {
                        Label("Reset Hand", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 10)
                    }
                }
                .padding()
            }
            .onChange(of: gameViewModel.calculationResult != nil) { _, hasResult in
                if hasResult {
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo("result", anchor: .top)
                    }
                }
            }
        } // ScrollViewReader
        .onAppear {
            // Ensure settings are connected
            if gameViewModel.settings == nil {
                gameViewModel.settings = settings
            }
            // Initialize pot with blinds
            initializePotWithBlinds()
            // Store position in game state
            gameViewModel.gameState.position = selectedPosition
        }
        .sheet(item: $selectedCardIndex) { selection in
            CardSelectorView(
                selectedCard: binding(for: selection),
                onDismiss: { selectedCardIndex = nil }
            )
            .environmentObject(gameViewModel)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
    
    private var isPostFlop: Bool {
        gameViewModel.gameState.communityCards.compactMap { $0 }.count >= 3
    }
    
    private var positionExplanation: String {
        if isPostFlop {
            switch selectedPosition {
            case "BTN":
                return "Post-flop: You act LAST (best position). Maximum information before deciding."
            case "SB":
                return "Post-flop: You act FIRST. Out of position against everyone."
            case "BB":
                return "Post-flop: You act SECOND. Out of position except vs SB."
            default:
                return ""
            }
        } else {
            switch selectedPosition {
            case "BTN":
                return "Button: Best position. You act last post-flop. Widest opening range."
            case "SB":
                return "Small Blind: Posted $\(String(format: "%.2f", settings.smallBlind)). Need $\(String(format: "%.2f", settings.smallBlind)) more to call."
            case "BB":
                return "Big Blind: Posted $\(String(format: "%.2f", settings.bigBlind)). You can check if no raise."
            default:
                return ""
            }
        }
    }
    
    private func initializePotWithBlinds() {
        // Seed the pot with the posted blinds if it has not been set yet.
        let blindsTotal = settings.smallBlind + settings.bigBlind
        if gameViewModel.gameState.potSize < blindsTotal {
            gameViewModel.gameState.potSize = blindsTotal
        }
        gameViewModel.gameState.bigBlind = settings.bigBlind
        if gameViewModel.gameState.playersInHand > settings.numberOfPlayers {
            gameViewModel.gameState.playersInHand = settings.numberOfPlayers
        }
        // Only seed the blinds when nothing has been entered for this hand yet.
        if gameViewModel.gameState.potSize <= blindsTotal {
            updateForPosition(selectedPosition)
        } else {
            gameViewModel.gameState.position = selectedPosition
        }
    }
    
    private func updateForPosition(_ pos: String) {
        // Preflop, changing seat changes what hero owes. Write the whole spot rather
        // than toCall alone: the pot and the bet have to stay consistent or the
        // derived "pot before their bet" silently absorbs the difference.
        if !isPostFlop {
            let entry = PotEntry.blindsOnly(heroPosition: pos,
                                            smallBlind: settings.smallBlind,
                                            bigBlind: settings.bigBlind)
            gameViewModel.gameState.potSize = entry.totalPot
            gameViewModel.gameState.toCall = entry.toCall
            // Nobody has raised, so hero's only contribution is this seat's blind.
            gameViewModel.gameState.heroWagerThisStreet =
                pos == "SB" ? settings.smallBlind : (pos == "BB" ? settings.bigBlind : 0)
        }
        gameViewModel.gameState.position = pos
    }
    
    private func binding(for selection: CardSelectionType) -> Binding<Card?> {
        switch selection {
        case .hole(let index):
            return $gameViewModel.gameState.holeCards[index]
        case .community(let index):
            return $gameViewModel.gameState.communityCards[index]
        }
    }
}

// MARK: - Supporting Views

struct StackInfoView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @State private var editingStack = false
    
    var body: some View {
        VStack(alignment: .trailing) {
            HStack {
                Text("STACK")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Button(action: { editingStack = true }) {
                    Text("$\(Int(gameViewModel.gameState.stack))")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
            }
            
            Text("(\(String(format: "%.1f", gameViewModel.gameState.effectiveStack)) BB)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .alert("Update Stack", isPresented: $editingStack) {
            TextField("Stack Size", value: $gameViewModel.gameState.stack, format: .currency(code: "USD"))
                .keyboardType(.decimalPad)
            Button("OK", role: .cancel) { }
        }
    }
}

struct YourHandView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    let onCardTap: (Int) -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            Text("YOUR CARDS")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 15) {
                ForEach(0..<2) { index in
                    CardView(card: gameViewModel.gameState.holeCards[index])
                        .onTapGesture {
                            onCardTap(index)
                        }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

struct CommunityCardsView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    let onCardTap: (Int) -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            Text("TABLE CARDS")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { index in
                    if index < visibleCards {
                        CardView(card: gameViewModel.gameState.communityCards[index])
                            .onTapGesture {
                                onCardTap(index)
                            }
                    }
                }
                
                if visibleCards < 5 && hasValidStreet {
                    Button(action: {
                        onCardTap(visibleCards)
                    }) {
                        Text("+ Add \(nextStreet)")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 20)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(8)
                    }
                }
            }
            
            Text(currentStreet)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var communityCount: Int {
        gameViewModel.gameState.communityCards.compactMap({ $0 }).count
    }
    
    private var visibleCards: Int {
        switch communityCount {
        case 0: return 0
        case 1, 2, 3: return 3
        case 4: return 4
        default: return 5
        }
    }
    
    private var hasValidStreet: Bool {
        switch communityCount {
        case 0, 3, 4: return true
        default: return false
        }
    }
    
    private var currentStreet: String {
        switch communityCount {
        case 0: return "Pre-flop"
        case 3: return "Flop"
        case 4: return "Turn"
        case 5: return "River"
        default: return "Invalid"
        }
    }
    
    private var nextStreet: String {
        switch communityCount {
        case 0: return "Flop"
        case 3: return "Turn"
        case 4: return "River"
        default: return ""
        }
    }
}

struct CardView: View {
    let card: Card?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(card != nil ? Color.white : Color(.systemGray6))
                .frame(width: 60, height: 80)

            if card != nil {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.systemGray4), lineWidth: 1)
                    .frame(width: 60, height: 80)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .foregroundColor(Color(.systemGray3))
                    .frame(width: 60, height: 80)
            }

            if let card = card {
                VStack(spacing: 2) {
                    Text(card.rank.symbol)
                        .font(.system(size: 24, weight: .bold))
                    Text(card.suit.symbol)
                        .font(.system(size: 20))
                }
                .foregroundColor(card.suit.color == "red" ? .red : .black)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(Color(.systemGray3))
            }
        }
        .shadow(color: card != nil ? Color.black.opacity(0.08) : .clear, radius: 3, x: 0, y: 2)
    }
}

struct PotInfoViewEnhanced: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @Binding var selectedPosition: String

    @State private var editingPot = false
    @State private var editingCall = false
    @State private var draftAmount: Double = 0

    private var isPostFlop: Bool {
        gameViewModel.gameState.communityCards.compactMap { $0 }.count >= 3
    }

    /// Derived from game state rather than mirrored into local @State, so the fields
    /// and the engine can never drift apart.
    private var entry: PotEntry {
        PotEntry(potBeforeBet: gameViewModel.gameState.potSize - gameViewModel.gameState.toCall,
                 toCall: gameViewModel.gameState.toCall)
    }

    /// `heroWager` is what hero has already put into the street. Manual entry cannot know
    /// it — the steppers only move the pot and the bet — so it defaults to nil and leaves
    /// the existing value alone; `heroCommitted` floors that at the posted blind.
    private func commit(_ updated: PotEntry, heroWager: Double? = nil) {
        gameViewModel.gameState.potSize = updated.totalPot
        gameViewModel.gameState.toCall = updated.toCall
        if let heroWager { gameViewModel.gameState.heroWagerThisStreet = heroWager }
    }

    var body: some View {
        VStack(spacing: 15) {
            playersInHandRow

            Divider()

            amountRow(
                title: "POT BEFORE THEIR BET",
                value: entry.potBeforeBet,
                tint: .primary,
                onEdit: { draftAmount = entry.potBeforeBet; editingPot = true },
                onDecrement: { var e = entry; e.setPotBeforeBet(e.potBeforeBet - settings.smallBlind); commit(e) },
                onIncrement: { var e = entry; e.setPotBeforeBet(e.potBeforeBet + settings.smallBlind); commit(e) }
            )

            Divider()

            amountRow(
                title: entry.toCall == 0 ? "THEIR BET — CHECK AVAILABLE" : "THEIR BET",
                value: entry.toCall,
                tint: entry.toCall == 0 ? .green : .primary,
                freeLabel: entry.toCall == 0 ? "FREE" : nil,
                onEdit: { draftAmount = entry.toCall; editingCall = true },
                onDecrement: { var e = entry; e.setCall(e.toCall - settings.smallBlind); commit(e) },
                onIncrement: { var e = entry; e.setCall(e.toCall + settings.smallBlind); commit(e) }
            )

            priceRow

            presets
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .alert("Pot before their bet", isPresented: $editingPot) {
            TextField("Amount", value: $draftAmount, format: .number)
                .keyboardType(.decimalPad)
            Button("Set") { var e = entry; e.setPotBeforeBet(draftAmount); commit(e) }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Their bet", isPresented: $editingCall) {
            TextField("Amount", value: $draftAmount, format: .number)
                .keyboardType(.decimalPad)
            Button("Set") { var e = entry; e.setCall(draftAmount); commit(e) }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Players still in the hand

    private var playersInHandRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PLAYERS IN HAND")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(gameViewModel.gameState.playersInHand) players · \(gameViewModel.gameState.opponentCount) opponent\(gameViewModel.gameState.opponentCount == 1 ? "" : "s")")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
            }

            Spacer()

            Stepper("") {
                gameViewModel.gameState.playersInHand = min(9, gameViewModel.gameState.playersInHand + 1)
            } onDecrement: {
                gameViewModel.gameState.playersInHand = max(2, gameViewModel.gameState.playersInHand - 1)
            }
            .labelsHidden()
            .accessibilityLabel("Players still in the hand")
            .accessibilityValue("\(gameViewModel.gameState.playersInHand)")
        }
    }

    // MARK: - Amount rows

    @ViewBuilder
    private func amountRow(title: String,
                           value: Double,
                           tint: Color,
                           freeLabel: String? = nil,
                           onEdit: @escaping () -> Void,
                           onDecrement: @escaping () -> Void,
                           onIncrement: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button(action: onEdit) {
                    Text(freeLabel ?? "$\(String(format: "%.2f", value))")
                        .font(.title2)
                        .bold()
                        .foregroundColor(tint)
                }
                .accessibilityLabel(title)
                .accessibilityHint("Double tap to type an amount")
            }

            Spacer()

            HStack(spacing: 15) {
                Button(action: onDecrement) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Decrease \(title)")

                Button(action: onIncrement) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Increase \(title)")
            }
        }
    }

    // MARK: - Price

    @ViewBuilder
    private var priceRow: some View {
        if let ratio = entry.potOddsRatio {
            HStack(spacing: 6) {
                Text("Pot")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("$\(String(format: "%.2f", entry.totalPot))")
                    .font(.caption.bold())
                Text("·")
                    .foregroundColor(.secondary)
                Text("\(String(format: "%.1f", ratio)):1")
                    .font(.caption.bold())
                Text("· need \(String(format: "%.1f", entry.requiredEquity * 100))% to call")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Presets

    private var presets: some View {
        VStack(spacing: 8) {
            if !isPostFlop {
                HStack(spacing: 6) {
                    Text("Preflop:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(PreflopPreset.allCases) { preset in
                        Button {
                            // The preset knows what hero already had in; `commit` only
                            // sees the flattened pot, so pass it explicitly.
                            let heroBlind = selectedPosition == "SB" ? settings.smallBlind
                                : (selectedPosition == "BB" ? settings.bigBlind : 0)
                            commit(PotEntry.preflop(preset,
                                                    heroPosition: selectedPosition,
                                                    smallBlind: settings.smallBlind,
                                                    bigBlind: settings.bigBlind),
                                   heroWager: max(preset.heroPriorWager * settings.bigBlind,
                                                  heroBlind))
                        } label: {
                            Text(preset.label)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                    }
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Text("Opp bet:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach([0.33, 0.5, 0.75, 1.0, 1.5], id: \.self) { multiplier in
                    Button {
                        var e = entry
                        e.applyOpponentBet(fractionOfPot: multiplier)
                        commit(e)
                    } label: {
                        Text(multiplier == 1.0 ? "Pot" : (multiplier > 1 ? "\(String(format: "%.1f", multiplier))x" : "\(Int(multiplier * 100))%"))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text("Set pot:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach([3.0, 5.0, 10.0, 15.0, 30.0], id: \.self) { bbMultiplier in
                    Button {
                        var e = entry
                        e.setPotBeforeBet(settings.bigBlind * bbMultiplier)
                        commit(e)
                    } label: {
                        Text("\(Int(bbMultiplier))BB")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Opponent Style Selector

struct OpponentStyleSelector: View {
    @EnvironmentObject var gameViewModel: GameViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPPONENT STYLE")
                .font(.caption2)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(OpponentStyle.allCases, id: \.self) { style in
                        let isSelected = gameViewModel.gameState.opponentStyle == style
                        Button(action: {
                            gameViewModel.gameState.opponentStyle = style
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: style.symbol)
                                    .font(.caption)
                                Text(style.rawValue)
                                    .font(.caption)
                                    .fontWeight(isSelected ? .semibold : .regular)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.blue : Color(.systemGray5))
                            .foregroundColor(isSelected ? .white : .primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct CalculateButton: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    
    var body: some View {
        VStack(spacing: 5) {
            Button(action: {
                Task {
                    await gameViewModel.calculate()
                }
            }) {
                Text(buttonText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(buttonColor)
                    .cornerRadius(10)
            }
            .disabled(!gameViewModel.canCalculate && !isShowingResult)
            
            if !gameViewModel.canCalculate && !gameViewModel.calculationError.isEmpty && !isShowingResult {
                Text(gameViewModel.calculationError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    private var isShowingResult: Bool {
        gameViewModel.calculationResult != nil && !gameViewModel.canCalculate
    }
    
    private var buttonColor: Color {
        if gameViewModel.canCalculate { return Color.blue }
        else if isShowingResult { return Color.green }
        else { return Color.gray }
    }
    
    private var buttonText: String {
        if gameViewModel.isCalculating { return "CALCULATING..." }
        else if isShowingResult { return "CALCULATION COMPLETE" }
        else { return "CALCULATE BEST PLAY" }
    }
}

