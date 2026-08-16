import SwiftUI

struct ContentView: View {
    @EnvironmentObject var gameViewModel: GameViewModel
    @EnvironmentObject var settings: Settings
    @State private var showSettings = false
    @State private var showDeadCards = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            MainGameView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Settings") {
                            showSettings = true
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 16) {
                            Button(action: { showHistory = true }) {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            Button("Dead Cards") {
                                showDeadCards = true
                            }
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
                .sheet(isPresented: $showHistory) {
                    HandHistoryView()
                        .environmentObject(gameViewModel)
                }
        }
    }
}
