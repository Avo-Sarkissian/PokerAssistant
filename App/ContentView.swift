import SwiftUI

struct ContentView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @State private var showSettings = false
    @State private var showDeadCards = false
    
    var body: some View {
        NavigationView {
            MainGameView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Settings") {
                            showSettings = true
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Dead Cards") {
                            showDeadCards = true
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                        .environmentObject(settings)
                }
                .sheet(isPresented: $showDeadCards) {
                    DeadCardsView()
                        .environmentObject(gameViewModel)
                }
        }
    }
}
