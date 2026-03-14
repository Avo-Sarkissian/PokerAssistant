import SwiftUI

struct DeadCardsView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showingCardSelector = false
    
    var body: some View {
        NavigationView {
            VStack {
                Text("CARDS TO REMOVE")
                    .font(.headline)
                    .padding()
                
                Text("Cards you've seen (bottom of deck, opponent flash, etc.)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if gameViewModel.gameState.deadCards.isEmpty {
                    Text("No cards removed")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 10) {
                            ForEach(Array(gameViewModel.gameState.deadCards), id: \.id) { card in
                                DeadCardView(card: card)
                                    .environmentObject(gameViewModel)
                            }
                        }
                        .padding()
                    }
                    
                    Text("Impact: \(String(format: "%.1f%%", calculateImpact()))")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                
                Spacer()
                
                Button(action: { showingCardSelector = true }) {
                    Label("Add Card", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationBarItems(trailing: Button("Done") { dismiss() })
            .sheet(isPresented: $showingCardSelector) {
                DeadCardSelector(showingCardSelector: $showingCardSelector)
                    .environmentObject(gameViewModel)
            }
        }
    }
    
    private func calculateImpact() -> Double {
        let totalCards = 52
        let knownCards = gameViewModel.gameState.holeCards.compactMap { $0 }.count +
                        gameViewModel.gameState.communityCards.compactMap { $0 }.count
        let deadCount = gameViewModel.gameState.deadCards.count
        
        return Double(deadCount) / Double(totalCards - knownCards) * 100
    }
}

struct DeadCardView: View {
    let card: Card
    @EnvironmentObject var gameViewModel: GameViewModel
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            CardView(card: card)
                .scaleEffect(0.8)
            
            Button(action: {
                gameViewModel.gameState.deadCards.remove(card)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .background(Circle().fill(Color.white))
            }
            .offset(x: 5, y: -5)
        }
    }
}

struct DeadCardSelector: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @Binding var showingCardSelector: Bool
    @State private var selectedCard: Card? = nil

    var body: some View {
        CardSelectorView(
            selectedCard: $selectedCard,
            onDismiss: { showingCardSelector = false }
        )
        .environmentObject(gameViewModel)
        .onChange(of: selectedCard) { _, newCard in
            if let card = newCard {
                gameViewModel.gameState.deadCards.insert(card)
            }
        }
    }
}
