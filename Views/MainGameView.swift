import SwiftUI

struct MainGameView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @State private var selectedCardIndex: CardSelectionType?
    @State private var showingResetAlert = false

    // Position Toggle State
    @State private var selectedPosition: String = "Btn"
    let positions = ["SB", "BB", "Btn"]

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
        VStack(spacing: 0) {
            // Performance Monitor at the top
            PerformanceMonitorView()
                .padding(.horizontal)
                .padding(.top, 8)
            
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
                            .frame(width: 140)
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
                    
                    // --- POT CONTROLS ---
                    PotInfoViewEnhanced(selectedPosition: $selectedPosition)
                    
                    // --- ACTION BUTTON OR RESULT ---
                    if gameViewModel.isCalculating {
                        CalculationProgressView()
                    } else if let result = gameViewModel.calculationResult {
                        ResultView(result: result)
                            .transition(.opacity)
                    }
                    
                    CalculateButton()
                        .padding(.top, 4)
                    
                    // --- RESET BUTTON ---
                    Button(action: {
                        showingResetAlert = true
                    }) {
                        Label("Reset Hand", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 10)
                    }
                }
                .padding()
            }
        }
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
        }
        .alert("Reset Hand?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                gameViewModel.resetHand()
                selectedPosition = "Btn"
                initializePotWithBlinds()
            }
        } message: {
            Text("This will clear all cards and reset the calculation.")
        }
    }
    
    private var isPostFlop: Bool {
        gameViewModel.gameState.communityCards.compactMap { $0 }.count >= 3
    }
    
    private var positionExplanation: String {
        if isPostFlop {
            switch selectedPosition {
            case "SB":
                return "Post-flop: You act FIRST (worst position). Consider switching to Btn if you're on the button."
            case "BB":
                return "Post-flop: You act SECOND. Consider switching to Btn if you're on the button."
            case "Btn":
                return "Post-flop: You act LAST (best position). Maximum information before deciding."
            default:
                return ""
            }
        } else {
            switch selectedPosition {
            case "SB":
                return "Small Blind: You've posted $\(String(format: "%.2f", settings.smallBlind)). Need $\(String(format: "%.2f", settings.smallBlind)) more to call."
            case "BB":
                return "Big Blind: You've posted $\(String(format: "%.2f", settings.bigBlind)). You can check if no raise."
            case "Btn":
                return "Button: Best position. You act last post-flop."
            default:
                return ""
            }
        }
    }
    
    private func initializePotWithBlinds() {
        // Start pot with SB + BB
        let blindsTotal = settings.smallBlind + settings.bigBlind
        if gameViewModel.gameState.potSize < blindsTotal {
            gameViewModel.gameState.potSize = blindsTotal
        }
        updateForPosition(selectedPosition)
    }
    
    private func updateForPosition(_ pos: String) {
        // Only auto-set toCall pre-flop
        if !isPostFlop {
            switch pos {
            case "BB":
                // Big Blind: You've posted full BB, can check if no raise
                gameViewModel.gameState.toCall = 0
            case "SB":
                // Small Blind: You've posted half, need to complete
                gameViewModel.gameState.toCall = settings.smallBlind
            case "Btn":
                // Button/Other: Must pay full BB to enter
                gameViewModel.gameState.toCall = settings.bigBlind
            default:
                gameViewModel.gameState.toCall = settings.bigBlind
            }
        }
        // Update position in game state for solver
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
                .fill(card != nil ? Color.white : Color.gray.opacity(0.3))
                .frame(width: 60, height: 80)
            
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                .frame(width: 60, height: 80)
            
            if let card = card {
                VStack(spacing: 2) {
                    Text(card.rank.symbol)
                        .font(.system(size: 24, weight: .bold))
                    Text(card.suit.symbol)
                        .font(.system(size: 20))
                }
                .foregroundColor(card.suit.color == "red" ? .red : .black)
            } else {
                Text("?")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct PotInfoViewEnhanced: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @Binding var selectedPosition: String
    
    @State private var localPotSize: Double = 0
    @State private var localToCall: Double = 0
    @State private var isInitialized = false
    
    private var isPostFlop: Bool {
        gameViewModel.gameState.communityCards.compactMap { $0 }.count >= 3
    }
    
    var body: some View {
        VStack(spacing: 15) {
            // Post-flop position reminder
            if isPostFlop && selectedPosition != "Btn" {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.orange)
                    Text("Post-flop: Switch to Btn if you're on the button")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Switch") {
                        selectedPosition = "Btn"
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
            
            // Pot Size Control
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("POT SIZE")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("$\(String(format: "%.2f", localPotSize))")
                        .font(.title2)
                        .bold()
                }
                
                Spacer()
                
                HStack(spacing: 15) {
                    Button(action: decrementPot) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    
                    Button(action: incrementPot) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            
            Divider()
            
            // Cost to Call Control
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localToCall == 0 ? "CHECK AVAILABLE" : "COST TO CALL")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(localToCall == 0 ? "FREE" : "$\(String(format: "%.2f", localToCall))")
                        .font(.title2)
                        .bold()
                        .foregroundColor(localToCall == 0 ? .green : .primary)
                }
                
                Spacer()
                
                HStack(spacing: 15) {
                    Button(action: decrementCall) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    
                    Button(action: incrementCall) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            
            // Pot Odds Display
            if localToCall > 0 {
                HStack {
                    Text("Pot Odds:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(String(format: "%.1f", (localPotSize / localToCall))):1")
                        .font(.caption)
                        .bold()
                    Text("(need \(String(format: "%.1f", (localToCall / (localPotSize + localToCall)) * 100))% equity)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Quick Presets - opponent bet sizing
            HStack(spacing: 10) {
                Text("Opp bet:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach([0.33, 0.5, 0.75, 1.0], id: \.self) { multiplier in
                    Button(action: {
                        setBetMultiplier(multiplier)
                    }) {
                        Text(multiplier == 1.0 ? "Pot" : "\(Int(multiplier * 100))%")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .onAppear {
            if !isInitialized {
                localPotSize = gameViewModel.gameState.potSize
                localToCall = gameViewModel.gameState.toCall
                isInitialized = true
            }
        }
        .onChange(of: gameViewModel.gameState.potSize) { _, newValue in
            localPotSize = newValue
        }
        .onChange(of: gameViewModel.gameState.toCall) { _, newValue in
            localToCall = newValue
        }
    }
    
    // All increments/decrements use smallBlind as the unit
    private func incrementPot() { updatePot(localPotSize + settings.smallBlind) }
    private func decrementPot() { updatePot(max(settings.smallBlind + settings.bigBlind, localPotSize - settings.smallBlind)) }
    private func incrementCall() { updateCall(localToCall + settings.smallBlind) }
    private func decrementCall() { updateCall(max(0, localToCall - settings.smallBlind)) }
    
    private func setBetMultiplier(_ multiplier: Double) {
        // This sets the "cost to call" as if opponent bet X% of pot
        updateCall(localPotSize * multiplier)
    }
    
    private func updatePot(_ value: Double) {
        localPotSize = value
        gameViewModel.gameState.potSize = value
    }
    
    private func updateCall(_ value: Double) {
        localToCall = value
        gameViewModel.gameState.toCall = value
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

