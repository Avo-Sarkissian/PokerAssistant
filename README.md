<div align="center">

# PokerAssistant

**Real-Time Texas Hold'em Strategy Engine for iOS**

*GPU-accelerated Monte Carlo simulations with exploitative decision-making*

![Platform](https://img.shields.io/badge/Platform-iOS%2017+-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![Metal](https://img.shields.io/badge/GPU-Metal%20Compute-purple)
![Architecture](https://img.shields.io/badge/Architecture-MVVM-green)

<img src="assets/demo.gif" alt="PokerAssistant Demo" width="300"/>

</div>

---

## Overview

PokerAssistant is a native iOS app that calculates hand equity and recommends optimal poker actions in real-time. It leverages Metal GPU compute and multi-core CPU parallelism to run up to **2 million Monte Carlo simulations per second**.

### Key Features

- **Real-Time Equity Calculation** — Sub-second results using Metal GPU compute
- **Exploitative Solver** — Position-aware decisions with dynamic bet sizing
- **Opponent Range Modeling** — Infers opponent hand ranges from betting patterns
- **Adaptive Precision** — Automatically allocates more compute time to close decisions

---

## Technical Architecture

### Hybrid GPU/CPU Compute Pipeline

The app implements a sophisticated dual-engine architecture that intelligently routes calculations based on scenario requirements:

```
User Input → CalculationViewModel
                    │
                    ▼
            EquityCalculator
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
   MetalCompute            MonteCarloEngine
   (GPU · 2M iter/s)       (CPU · 6 cores)
        │                       │
        └───────────┬───────────┘
                    ▼
            ExploitativeSolver
                    │
                    ▼
            Action Recommendation
```

| Engine | Technology | Speed | Use Case |
|--------|------------|-------|----------|
| **GPU** | Metal Compute Shaders | 2M iterations/sec | Standard calculations |
| **CPU** | Swift Concurrency (6 cores) | 500K iterations/sec | Opponent range filtering |

### Intelligent Routing Logic

```swift
// Automatic engine selection
if rangeFilteringNeeded && headsUp {
    → CPU with opponent modeling
} else if metalReady {
    → GPU (faster) with 5s timeout protection
} else {
    → CPU fallback
}
```

---

## Performance Engineering

### Statistical Convergence Optimization

Instead of fixed iteration counts, the engine uses **adaptive early termination** based on Standard Error (SE):

| Mode | Confidence | Typical Time | Max Iterations |
|------|------------|--------------|----------------|
| Fast | SE < 1.0% | 1-3s | 1M |
| Accurate | SE < 0.5% | 3-6s | 10M |
| Deep | SE < 0.25% | 5-8s | 50M |
| Maximum | SE < 0.1% | 8-10s | 100M |

> **Key Insight:** Clear fold/raise decisions converge in 2-3 seconds. Marginal spots automatically receive more computation, up to the 10-second cap.

### Metal GPU Optimizations

- **Pre-compiled shaders** — Build-time compilation eliminates 5-10s runtime delay
- **Partial Fisher-Yates shuffle** — Only shuffles needed cards, preventing infinite loops
- **Per-thread result buffers** — Eliminates atomic operations overhead
- **LCG PRNG** — Fast, deterministic random number generation per thread
- **5-second timeout protection** — Prevents GPU hangs from freezing the app

### CPU Optimizations

- **6-core parallelism** — Utilizes all performance cores on A18 Pro
- **Local resource allocation** — Avoids GCD/Swift concurrency deadlocks
- **Index-based shuffling** — Faster than object-based approaches
- **Batch processing** — 50K iterations per batch with convergence checks

---

## Poker Intelligence

### Hand Evaluation Algorithm

The engine evaluates all **21 combinations** of 5 cards from 7, identical logic running on both CPU (Swift) and GPU (Metal):

```
Hand Value Encoding:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Straight Flush   │ 8,000,000 + high card
Four of a Kind   │ 7,000,000 + quad rank × 100 + kicker
Full House       │ 6,000,000 + trips × 100 + pair
Flush            │ 5,000,000 + bit-ranked kickers
Straight         │ 4,000,000 + high card
Three of a Kind  │ 3,000,000 + trips × 10,000 + kickers
Two Pair         │ 2,000,000 + high × 10,000 + low × 100
Pair             │ 1,000,000 + pair × 100,000 + kickers
High Card        │ Bit-shifted ranks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Opponent Range Modeling

The `OpponentRange` module implements **Sklansky-Chubukov** hand rankings with dynamic range inference:

| Opponent Action | Inferred Range | Example Hands |
|-----------------|----------------|---------------|
| 3-bet/4-bet | Top 10% | AA, KK, QQ, AKs |
| EP Open-Raise | Top 20% | JJ+, AQs+, AKo |
| MP/CO Open | Top 35% | 88+, ATs+, KQs |
| BTN Open | Top 50% | 55+, A8s+, KJo+ |
| Limp/Call | Top 70% | Any playable hand |

### Exploitative Decision Solver

Position-aware strategy with multi-factor optimization:

```swift
Decision Factors:
├── Position multipliers (Button: 1.2× aggression, SB: 0.8×)
├── Stack-to-Pot Ratio (SPR) adjustments
├── Pot odds vs equity comparison (+5% edge required)
├── Fold equity estimation by opponent range
└── Street-dependent sizing (preflop → river)
```

---

## Project Structure

```
PokerAssistant/
├── App/
│   ├── PokerAssistantApp.swift     # Entry point, environment setup
│   └── ContentView.swift           # Root navigation
│
├── Engine/
│   ├── PokerShaders.metal          # GPU Monte Carlo kernel
│   ├── MetalCompute.swift          # GPU orchestration + timeout
│   ├── MonteCarloEngine.swift      # 6-core CPU simulation
│   ├── EquityCalculator.swift      # Smart GPU/CPU routing
│   ├── PokerIntelligence.swift     # 7-card hand evaluator
│   ├── ExploitativeSolver.swift    # EV-based decisions
│   └── OpponentRange.swift         # 169-hand Sklansky rankings
│
├── Models/
│   ├── Card.swift                  # Card, Rank, Suit types
│   ├── GameState.swift             # Pot, stack, position
│   ├── Settings.swift              # Calculation depth config
│   └── CalculationResult.swift     # Action + EV + reasoning
│
├── ViewModels/
│   ├── GameViewModel.swift         # Main state management
│   └── CalculationViewModel.swift  # Async calculation handling
│
└── Views/
    ├── MainGameView.swift          # Primary game interface
    ├── CardSelectorView.swift      # Interactive card picker
    ├── ResultView.swift            # Recommendation display
    └── SettingsView.swift          # Configuration screen
```

---

## Technology Stack

| Layer | Technology |
|-------|------------|
| **UI** | SwiftUI, SF Symbols |
| **Architecture** | MVVM, Combine |
| **GPU Compute** | Metal Performance Shaders |
| **Concurrency** | Swift Concurrency (async/await) |
| **Persistence** | @AppStorage (UserDefaults) |
| **Target** | iOS 17+, iPhone 16 Pro (A18 Pro) |

---

## Accuracy Validation

Verified equity calculations against known poker probabilities:

| Hand | Opponents | Expected | Actual | Status |
|------|-----------|----------|--------|--------|
| A♠A♥ | 1 | ~85% | 85.2% | ✅ |
| A♠A♥ | 5 | ~49% | 49.1% | ✅ |
| A♠K♠ | 5 | ~31% | 31.4% | ✅ |
| T♥2♦ | 5 | ~12% | 12.3% | ✅ |
| 7♠2♦ | 5 | ~16% | 15.8% | ✅ |

---

## Getting Started

### Requirements

- Xcode 15+
- iOS 17+ SDK
- Physical device recommended (Metal simulator has limitations)

### Build & Run

```bash
git clone https://github.com/yourusername/PokerAssistant.git
cd PokerAssistant
open PokerAssistant.xcodeproj
```

1. Select your target device (iPhone recommended)
2. Press `Cmd + R` to build and run

---

## Roadmap

- [ ] Board texture analysis (wet/dry board adjustments)
- [ ] Pre-flop hand charts by position
- [ ] GPU-accelerated opponent range filtering
- [ ] Hand history and session tracking
- [ ] Multi-street opponent modeling
- [ ] iPad layout support

---

## Technical Highlights

<table>
<tr>
<td width="50%">

### GPU Acceleration
- 2M Monte Carlo iterations/second
- Pre-compiled Metal shaders
- Non-blocking shader initialization
- Automatic timeout protection

</td>
<td width="50%">

### Statistical Rigor
- Adaptive SE-based convergence
- Confidence thresholds (0.1% - 1.0%)
- Proper fold equity calculation
- Pot odds with edge requirements

</td>
</tr>
<tr>
<td>

### Poker Strategy
- 169-hand Sklansky rankings
- Position-aware multipliers
- SPR-based adjustments
- Opponent range inference

</td>
<td>

### iOS Engineering
- MVVM with SwiftUI
- Thread-safe Sendable types
- @MainActor UI isolation
- Zero force-unwraps

</td>
</tr>
</table>

---

<div align="center">

**Built with Swift and Metal**

*Tested on iPhone 16 Pro (A18 Pro) · Compatible with all iOS 17+ devices*

</div>
