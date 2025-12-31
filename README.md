# PokerAssistant

A real-time Texas Hold'em strategy assistant for iOS, featuring GPU-accelerated Monte Carlo equity simulations and an exploitative solver for optimal decision-making.

**Target Device:** iPhone 16 Pro (A18 Pro)
**Platform:** iOS 17+ / SwiftUI
**Status:** Working

## Overview

PokerAssistant calculates hand equity and recommends optimal actions (fold/call/raise) in real-time. It uses:

- **Metal GPU compute** for Monte Carlo simulations (up to 2M iterations in ~1s)
- **Exploitative Solver** with position-aware, SPR-aware decision logic
- **Opponent Range Weighting** to filter opponent hands by their likely holdings

The app is designed for $0.50/$1.00 blind cash games with a $20 buy-in.

## Architecture

```
PokerAssistant/
├── App/
│   ├── PokerAssistantApp.swift    # App entry point, environment setup
│   └── ContentView.swift          # Root navigation
├── Engine/
│   ├── MetalCompute.swift         # GPU shader for Monte Carlo simulation
│   ├── MonteCarloEngine.swift     # CPU fallback with multi-core parallelism
│   ├── EquityCalculator.swift     # GPU-first routing with CPU fallback
│   ├── PokerIntelligence.swift    # Fast 7-card hand evaluation
│   ├── ExploitativeSolver.swift   # Position/SPR-aware decision engine
│   ├── OpponentRange.swift        # Preflop hand rankings (169 hands)
│   ├── HandEvaluator.swift        # Alternative evaluator for reasoning
│   └── PerformanceMonitor.swift   # Metrics collection
├── Models/
│   ├── Card.swift                 # Card, Rank, Suit definitions
│   ├── Hand.swift                 # Hole cards + community cards
│   ├── GameState.swift            # Pot, stack, position, toCall
│   ├── Settings.swift             # Calculation depth, blind sizes
│   └── CalculationResult.swift    # Action recommendations + EV
├── ViewModels/
│   ├── GameViewModel.swift        # Main game state management
│   └── CalculationViewModel.swift # Async calculation orchestration
├── Views/
│   ├── MainGameView.swift         # Primary game interface
│   ├── CardSelectorView.swift     # Card picker UI
│   ├── ResultView.swift           # Recommendation display
│   ├── SettingsView.swift         # Configuration screen
│   └── ...
└── Utils/
    ├── Extensions.swift           # Suit.suitIndex for card encoding
    └── Constants.swift            # Default values
```

### Design Pattern

**MVVM** with SwiftUI:
- `GameState` and `Settings` are `@Published` ObservableObjects
- ViewModels handle async calculations and state updates
- Views bind directly to published properties

### Compute Architecture

```
User Input → CalculationViewModel
                    │
                    ▼
            EquityCalculator
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
   MetalCompute            MonteCarloEngine
   (GPU, 2M cap)           (CPU, 6 cores)
        │                       │
        └───────────┬───────────┘
                    ▼
            ExploitativeSolver
                    │
                    ▼
            CalculationResult
```

## Performance

### GPU (Metal)

| Iterations | Time    | Accuracy  |
|------------|---------|-----------|
| 500K       | ~0.3s   | ±0.07%    |
| 1M         | ~0.5s   | ±0.05%    |
| 2M         | ~1.0s   | ±0.035%   |

The Metal shader runs a fully self-contained Monte Carlo simulation:
- Per-thread result buffers (no atomics)
- Fisher-Yates shuffle with LCG PRNG
- 7-card to 5-card best-hand evaluation

### CPU Fallback

Uses all 6 performance cores on A18 Pro with:
- Thread-local storage to eliminate allocation overhead
- Index-based shuffling (faster than object shuffling)
- Opponent range filtering via rejection sampling

### Opponent Range Weighting

When opponents bet/raise, the simulator filters their dealt hands:

| Opponent Action     | Range Applied | Effect on Your Equity |
|---------------------|---------------|----------------------|
| No bet (limp/check) | Top 70%       | Higher (weak range)  |
| Small bet (<25% pot)| Top 50%       | Slightly lower       |
| Medium bet (50% pot)| Top 35%       | Lower                |
| Large bet (>80% pot)| Top 20%       | Much lower           |

This significantly improves accuracy vs random-hand simulations.

## Accuracy Validation

Run these tests to verify correct operation:

| Hand   | Opponents | Expected Equity | Notes                    |
|--------|-----------|-----------------|--------------------------|
| T♥ 2♦  | 5         | ~12%            | Trash hand baseline      |
| A♠ K♠  | 5         | ~36-40%         | Premium suited connector |
| A♠ A♥  | 1         | ~85%            | Heads-up with aces       |
| 7♠ 2♦  | 5         | ~8-10%          | Worst hand in poker      |

The debug output (if enabled) shows:
```
GPU: 2000K -> 36.2%
```

## Known Limitations

1. **GPU range filtering not implemented** - Metal shader uses random opponent hands; range weighting only applies to CPU fallback
2. **No hand history persistence** - Settings and state reset on app restart
3. **No opponent tracking** - Each hand is independent; no villain profiling across sessions
4. **Post-flop ranges simplified** - Range filtering only applies preflop; post-flop assumes any two cards
5. **No test coverage** - Unit test stubs exist but are empty

## How to Run

### Requirements

- Xcode 15+
- iOS 17+ SDK
- Physical device recommended (Metal simulator has limitations)

### Setup

```bash
# Clone the repository
git clone <repo-url>
cd PokerAssistant

# Open in Xcode
open PokerAssistant.xcodeproj
```

### Build & Run

1. Select your target device (iPhone 16 Pro recommended)
2. Press `Cmd + R` to build and run
3. If prompted, trust the developer certificate in Settings > General > Device Management

### Adding New Files

If you pulled changes that include new `.swift` files (e.g., `OpponentRange.swift`):

1. In Xcode, right-click the appropriate folder (e.g., `Engine/`)
2. Select "Add Files to PokerAssistant..."
3. Select the new file(s)
4. Ensure "Copy items if needed" is unchecked (files are already in place)

## Configuration

### Calculation Depth (Settings.swift)

| Mode     | Iterations | Time   | Use Case              |
|----------|------------|--------|-----------------------|
| Fast     | 1M         | ~0.2s  | Quick estimates       |
| Accurate | 10M        | ~1.3s  | Default for play      |
| Deep     | 50M        | ~6s    | Important decisions   |
| Maximum  | 100M       | ~13s   | Analysis mode         |

### Default Blinds (Constants.swift)

```swift
static let buyIn = 20.0       // $20 stack
static let smallBlind = 0.5   // $0.50
static let bigBlind = 1.0     // $1.00
```

## Debug Mode

Debug output was removed from the UI for production. To re-enable:

In `ResultView.swift`, add back the debug VStack before the main recommendation:

```swift
// DEBUG INFO - Uncomment to enable
VStack(alignment: .leading, spacing: 4) {
    Text("DEBUG INFO").font(.caption).bold().foregroundColor(.orange)
    Text("Equity: \(String(format: "%.2f", result.equity * 100))%")
    Text("Engine: \(MetalCompute.lastDebugInfo)")
}
.padding(8)
.background(Color.orange.opacity(0.1))
.cornerRadius(6)
```

Console logs still show:
- `🚀 MonteCarloEngine using X cores`
- GPU pipeline initialization status

## Roadmap

### High Priority

- [ ] **Board texture analysis** - Adjust recommendations for wet/dry boards
- [ ] **Pre-flop hand charts** - Opening ranges by position
- [ ] **Settings persistence** - Save configuration to UserDefaults

### Medium Priority

- [ ] **GPU range filtering** - Port opponent range logic to Metal shader
- [ ] **Multi-street opponent modeling** - Track villain tendencies
- [ ] **Hand history** - Review past decisions

### Low Priority

- [ ] **Unit tests** - Cover equity calculation and hand evaluation
- [ ] **iPad support** - Larger layout for tablet
- [ ] **Apple Watch companion** - Quick equity lookup

## Technical Notes

### Card Encoding

Cards are encoded as `(rank - 2) * 4 + suitIndex` for GPU compatibility:

```swift
// Extensions.swift
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
```

### Hand Evaluation

The GPU shader and `PokerIntelligence` use identical logic:
1. Generate all 21 combinations of 5 cards from 7
2. Evaluate each 5-card hand
3. Return the maximum value

Hand values are encoded as:
```
Straight Flush: 8,000,000 + high card
Four of a Kind:  7,000,000 + quad rank * 100 + kicker
Full House:      6,000,000 + trips * 100 + pair
Flush:           5,000,000 + (r0 << 16) + (r1 << 12) + ...
Straight:        4,000,000 + high card
Three of a Kind: 3,000,000 + trips * 10000 + kickers
Two Pair:        2,000,000 + high pair * 10000 + low pair * 100 + kicker
Pair:            1,000,000 + pair * 100000 + kickers
High Card:       (r0 << 16) + (r1 << 12) + (r2 << 8) + (r3 << 4) + r4
```

## License

Private project - not for distribution.
