import SwiftUI

extension Color {
    static let pokerGreen = Color(red: 0.0, green: 0.5, blue: 0.25)
    static let cardRed = Color(red: 0.8, green: 0.1, blue: 0.1)
    static let cardBlack = Color.black
}

extension View {
    func cardStyle() -> some View {
        self
            .frame(width: 60, height: 80)
            .background(Color.white)
            .cornerRadius(8)
            .shadow(radius: 2)
    }
}

// Reliable suit index for card encoding (0-3)
extension Suit {
    var suitIndex: Int {
        switch self {
        case .spades: return 0
        case .hearts: return 1
        case .diamonds: return 2
        case .clubs: return 3
        }
    }
}
