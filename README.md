# PokerAssistant

A real-time Texas Hold'em strategy assistant for iOS, featuring GPU-accelerated Monte Carlo equity simulations and an exploitative solver for optimal decision-making.

**Target Device:** iPhone 16 Pro (A18 Pro)
**Platform:** iOS 17+ / SwiftUI
**Status:** Working

## Overview

PokerAssistant calculates hand equity and recommends optimal actions (fold/call/raise) in real-time. It uses:

- **Metal GPU compute** for Monte Carlo simulations (up to 2M iterations in ~0.5s)
- **6-core CPU fallback** with early termination for optimal accuracy/speed trade-off
- **Exploitative decision logic** with pot odds and equity-based thresholds
- **Opponent Range Weighting** for heads-up preflop situations

The app is designed for $0.50/$1.00 blind cash games with a $20 buy-in.

## Recent Improvements

### Calculation Accuracy Fix (Latest)

- **Fixed GPU/CPU inconsistency** - A♠K♠ was showing 52% on first run (CPU) and 37% on subsequent runs (GPU). Root cause: CPU fallback was applying opponent range filtering while GPU uses random opponents. Now both paths use consistent random opponents for multi-way pots.
- **Correct equity values** - A♠K♠ vs 5 opponents now correctly shows ~31% (previously varied between 37-52%)
- **Improved reasoning messages** - Now shows specific pot odds, equity percentages, and edge calculations (e.g., "Call: 45% equity vs 25% needed (3.0:1 odds). +20% edge makes calling profitable")
- **Settings persistence** - All settings now persist across app restarts via @AppStorage
- **Code cleanup** - Removed 224 lines of dead code, fixed force unwraps, improved defensive programming

### Performance & Stability Fixes

- **Fixed GPU hang** - Resolved infinite loop in Metal shader caused by unsigned integer underflow
- **Optimized shuffle algorithm** - Partial Fisher-Yates shuffle (only shuffles needed cards)
- **Non-blocking architecture** - Metal compilation and initialization don't block UI or calculations
- **Pre-compiled shaders** - PokerShaders.metal compiles at build time (eliminates 5-10s runtime delay)
- **Improved fold logic** - Adjusted threshold to require 5% edge over pot odds for calls

## Architecture

```
PokerAssistant/
├── App/
│   ├── PokerAssistantApp.swift    # App entry point, environment setup
│   └── ContentView.swift          # Root navigation
├── Engine/
│   ├── PokerShaders.metal         # Pre-compiled GPU kernel (build-time compilation)
│   ├── MetalCompute.swift         # GPU compute orchestration with timeout
│   ├── MonteCarloEngine.swift     # CPU fallback with 6-core parallelism
│   ├── EquityCalculator.swift     # GPU-first routing with non-blocking fallback
│   ├── PokerIntelligence.swift    # Fast 7-card hand evaluation (CPU & GPU compatible)
│   ├── OpponentRange.swift        # Preflop hand rankings (169 hands)
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

### Early Termination Optimization

**New in latest version**: Calculations now use **adaptive early termination** with confidence intervals instead of fixed iteration counts. This achieves maximum accuracy in minimal time.

#### How It Works

The engine runs Monte Carlo simulations in 50K batches and checks for **statistical convergence** after each batch:
- Calculates **Standard Error (SE)** of the equity estimate
- Stops when SE drops below the configured threshold
- Guarantees maximum 10 second runtime

#### Performance by Depth Setting

| Mode     | Confidence | Typical Time | Max Iterations | Use Case              |
|----------|------------|--------------|----------------|-----------------------|
| Fast     | SE < 1.0%  | 1-3s         | 1M             | Quick estimates       |
| Accurate | SE < 0.5%  | 3-6s         | 10M            | Default for play      |
| Deep     | SE < 0.25% | 5-8s         | 50M            | Important decisions   |
| Maximum  | SE < 0.1%  | 8-10s        | 100M           | Maximum precision     |

**Key insight**: Simple hands (clear fold/raise) converge in 2-3 seconds. Marginal decisions automatically get more computation, up to 10 seconds.

### GPU (Metal)

| Iterations | Time    | Used When                 |
|------------|---------|---------------------------|
| 500K       | ~0.25s  | No opponent action (limp) |
| 1M         | ~0.5s   | Pre-flop random range     |
| 2M         | ~1.0s   | Max GPU iterations        |

The Metal shader (PokerShaders.metal) runs a fully self-contained Monte Carlo simulation:
- **Pre-compiled at build time** - no runtime compilation delay
- **Partial Fisher-Yates shuffle** - only shuffles needed cards, preventing infinite loops
- **Per-thread result buffers** - eliminates need for atomic operations
- **LCG PRNG** - fast, deterministic random number generation per thread
- **7-card to 5-card evaluation** - checks all 21 combinations for best hand
- **5-second timeout** - prevents GPU hangs from freezing the app
- **Limitation**: No range filtering support (uses random opponent hands)

### CPU (Multi-Core)

Uses all 6 performance cores on A18 Pro with:
- **Early termination** - stops when statistically converged (SE below threshold)
- **Local resource allocation** - avoids GCD/Swift concurrency deadlocks
- **Index-based shuffling** - faster than object-based approaches
- **Opponent range filtering** - rejection sampling for heads-up preflop scenarios
- **Batch processing** - 50K iterations per batch with convergence checks
- **Hard 10-second timeout** - guarantees calculations complete

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
| A♠ K♠  | 5         | ~31%            | Premium suited (corrected)|
| A♠ A♥  | 1         | ~85%            | Heads-up with aces       |
| A♠ A♥  | 5         | ~49%            | Aces vs 5 opponents      |
| 7♠ 2♦  | 5         | ~16%            | Worst hand in poker      |

The debug panel (expandable at top of screen) shows:
```
CPU: 150K, SE=0.412%, 2.3s
```

This indicates:
- 150K iterations completed
- Standard error of 0.412% (converged)
- 2.3 seconds elapsed

## Known Limitations

1. **GPU range filtering not implemented** - Metal shader uses random opponent hands; range weighting only applies to CPU path (heads-up preflop only)
2. **App startup time** - Still ~7 seconds on first launch (Metal initialization in background)
3. **No hand history** - Each session is independent; past hands are not saved
4. **No opponent tracking** - No villain profiling across sessions
5. **Post-flop ranges simplified** - Range filtering only applies preflop; post-flop assumes any two cards
6. **No test coverage** - Unit test stubs exist but are empty

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

**Updated**: Depth settings now use confidence thresholds instead of fixed times:

| Mode     | Confidence | Max Iterations | Typical Time | Description           |
|----------|------------|----------------|--------------|----------------------|
| Fast     | SE < 1.0%  | 1M             | 1-3s         | Quick estimates      |
| Accurate | SE < 0.5%  | 10M            | 3-6s         | Default for play     |
| Deep     | SE < 0.25% | 50M            | 5-8s         | Important decisions  |
| Maximum  | SE < 0.1%  | 100M           | 8-10s        | Maximum precision    |

**Note**: Times shown are typical - simple decisions finish faster, complex ones use more time (up to 10s max).

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
- [x] **Settings persistence** - ~~Save configuration to UserDefaults~~ (Done via @AppStorage)

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
