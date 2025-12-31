import SwiftUI

@main
struct PokerAssistantApp: App {
    @StateObject private var gameViewModel = GameViewModel()
    @StateObject private var settings = Settings()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gameViewModel)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .task {
                    // Connect settings after view appears
                    gameViewModel.settings = settings
                    
                    // Warm up PokerIntelligence in background
                    Task.detached(priority: .background) {
                        _ = PokerIntelligence.shared
                    }
                }
        }
    }
}
