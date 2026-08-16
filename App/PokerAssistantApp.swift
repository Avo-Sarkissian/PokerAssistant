import SwiftUI
import PokerCore

@main
struct PokerAssistantApp: App {
    @StateObject private var gameViewModel = GameViewModel()
    @StateObject private var settings = Settings()

    init() {
        // PokerCore reports what it is doing through a protocol so that it stays free
        // of SwiftUI. Nothing in the engine knows about the monitor until this line.
        EngineTelemetry.sink = PerformanceMonitor.shared
    }


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
