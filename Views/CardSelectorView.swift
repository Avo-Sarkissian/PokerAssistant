import SwiftUI
import PokerCore

struct CardSelectorView: View {
    @Binding var selectedCard: Card?
    @EnvironmentObject var gameViewModel: GameViewModel
    let onDismiss: () -> Void

    private let ranks: [Rank] = Array(Rank.allCases.reversed()) // A → 2
    private let suits: [Suit] = Suit.allCases

    var body: some View {
        VStack(spacing: 0) {
            // Handle indicator
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 4)
                .padding(.top, 14)
                .padding(.bottom, 18)

            // Header
            HStack {
                Text("Select Card")
                    .font(.title3.bold())
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(.systemGray3))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            // Card grid — 4 rows (one per suit), each row scrolls horizontally
            VStack(spacing: 8) {
                ForEach(suits, id: \.self) { suit in
                    suitRow(suit: suit)
                }
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 24)
        }
        .background(Color(.systemBackground))
    }

    private func suitRow(suit: Suit) -> some View {
        HStack(spacing: 8) {
            Text(suit.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(suit.color == "red" ? .red : .primary)
                .frame(width: 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ranks, id: \.self) { rank in
                        let isUsed = gameViewModel.gameState.isUsed(Card(rank: rank, suit: suit))
                        CardGridCell(
                            rank: rank,
                            suit: suit,
                            isUsed: isUsed,
                            onSelect: {
                                selectedCard = Card(rank: rank, suit: suit)
                                onDismiss()
                            }
                        )
                    }
                }
            }
        }
    }
}

struct CardGridCell: View {
    let rank: Rank
    let suit: Suit
    let isUsed: Bool
    let onSelect: () -> Void

    private var displaySymbol: String {
        rank == .ten ? "T" : rank.symbol
    }

    var body: some View {
        Button(action: { if !isUsed { onSelect() } }) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isUsed ? Color(.systemGray5) : Color(.systemBackground))
                    .shadow(
                        color: isUsed ? .clear : Color.black.opacity(0.1),
                        radius: 1.5, x: 0, y: 1
                    )

                Text(displaySymbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(
                        isUsed
                            ? Color(.systemGray3)
                            : (suit.color == "red" ? .red : .primary)
                    )
            }
            .frame(width: 48, height: 52)
        }
        .disabled(isUsed)
    }
}
