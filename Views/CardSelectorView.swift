import SwiftUI

struct CardSelectorView: View {
    @Binding var selectedCard: Card?
    @EnvironmentObject var gameViewModel: GameViewModel
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            VStack {
                Text("SELECT CARD")
                    .font(.headline)
                    .padding()
                
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(Suit.allCases, id: \.self) { suit in
                            SuitRowView(
                                suit: suit,
                                selectedCard: $selectedCard,
                                usedCards: gameViewModel.gameState.usedCards,
                                onSelect: onDismiss
                            )
                        }
                    }
                    .padding()
                }
                
                if !gameViewModel.gameState.usedCards.isEmpty {
                    VStack {
                        Text("Already selected:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(gameViewModel.gameState.usedCards).sorted(by: {
                                    $0.rank.rawValue > $1.rank.rawValue ||
                                    ($0.rank.rawValue == $1.rank.rawValue && $0.suit.suitIndex < $1.suit.suitIndex)
                                }), id: \.id) { card in
                                    Text(card.displayString)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationBarItems(trailing: Button("Cancel") { onDismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Force stack style
    }
}

struct SuitRowView: View {
    let suit: Suit
    @Binding var selectedCard: Card?
    let usedCards: Set<Card>
    let onSelect: () -> Void
    
    private let ranks = Rank.allCases.reversed()
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(suit.symbol)
                .font(.title2)
                .foregroundColor(suit.color == "red" ? .red : .black)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ranks, id: \.self) { rank in
                        CardButton(
                            rank: rank,
                            suit: suit,
                            isUsed: usedCards.contains { $0.rank == rank && $0.suit == suit },
                            onSelect: {
                                selectedCard = Card(rank: rank, suit: suit)
                                onSelect()
                            }
                        )
                    }
                }
            }
        }
    }
}

struct CardButton: View {
    let rank: Rank
    let suit: Suit
    let isUsed: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: {
            if !isUsed {
                onSelect()
            }
        }) {
            Text(rank.symbol)
                .font(.title3)
                .frame(width: 44, height: 60)
                .background(isUsed ? Color.gray.opacity(0.3) : Color.white)
                .foregroundColor(isUsed ? .gray : (suit.color == "red" ? .red : .black))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                )
        }
        .disabled(isUsed)
    }
}
