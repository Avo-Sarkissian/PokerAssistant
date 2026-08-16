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
                .preferredColorScheme(settings.forceDarkMode ? .dark : nil)
                .task {
                    // Connect settings after view appears
                    gameViewModel.settings = settings
                }
        }
    }
}
