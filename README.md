<div align="center">

# PokerAssistant

**Real-Time Probability Engine for Strategic Decision-Making**

*A mobile application that processes 2M+ scenarios per second to deliver actionable recommendations under uncertainty*

![Platform](https://img.shields.io/badge/Platform-iOS%2017+-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![Metal](https://img.shields.io/badge/GPU-Metal%20Compute-purple)
![Architecture](https://img.shields.io/badge/Architecture-MVVM-green)

</div>

---

## Why This Matters

PokerAssistant is more than a poker tool—it's a **real-time risk and probability model** that demonstrates how hardware acceleration and statistical methods can transform decision-making under uncertainty.

The same computational principles used here—Monte Carlo simulation, confidence intervals, and behavioral pattern recognition—are foundational to portfolio risk modeling, options pricing, and scenario analysis in quantitative finance.

<table>
<tr>
<td>

**The Analogy**

Just as a Growth Equity analyst evaluates hundreds of data points to price a deal and assess downside risk, this engine evaluates **2 million scenarios per second** to price "hand equity"—the probability-weighted expected value of a position given incomplete information.

The difference? This engine returns a decision recommendation in under 3 seconds.

</td>
</tr>
</table>

---

## Core Capabilities

| Capability | What It Does | Why It Matters |
|------------|--------------|----------------|
| **Real-Time Valuation** | Calculates position equity using Monte Carlo simulation | Quantifies expected value under uncertainty |
| **Adaptive Confidence Scoring** | Dynamically allocates compute until statistical convergence | Ensures recommendations meet precision thresholds |
| **Behavioral Pattern Recognition** | Infers opponent strategy from betting patterns | Identifies exploitable edges in adversarial scenarios |
| **Hardware-Accelerated Processing** | Leverages GPU compute for 10x throughput | Enables real-time "stress testing" of strategies |

---

## How It Works

### 1. The Valuation Engine

The core engine runs **Monte Carlo simulations** to estimate the probability of winning given:
- Known information (your cards, visible community cards)
- Unknown information (opponent holdings, remaining deck)

Rather than fixed iteration counts, the engine uses **adaptive convergence**—it continues processing until the result meets a confidence threshold:

| Mode | Decision Confidence | Typical Response Time |
|------|---------------------|----------------------|
| Fast | 99% confident | 1-3 seconds |
| Accurate | 99.5% confident | 3-6 seconds |
| Deep | 99.75% confident | 5-8 seconds |
| Maximum | 99.9% confident | 8-10 seconds |

> The engine automatically allocates more computation to marginal decisions. Clear fold/raise scenarios resolve in 2 seconds; close calls receive additional processing to ensure accuracy.

### 2. Hardware-Accelerated Insight

Traditional mobile apps process data on the CPU. This engine offloads computation to the **GPU via Apple's Metal framework**, achieving:

- **2M iterations/second** on GPU (vs. ~200K on CPU alone)
- **Pre-compiled shaders** eliminate startup latency
- **Automatic fallback** to multi-core CPU when GPU is unavailable
- **Timeout protection** ensures the app never hangs

This isn't a technical flex—it's about **speed-to-insight**. Real-time decision support requires real-time computation.

```
Calculation Pipeline:

User Input → Probability Engine → Strategy Layer → Recommendation
                   │                    │
         ┌─────────┴─────────┐          │
         ▼                   ▼          ▼
    GPU Compute         CPU Compute   Behavioral
    (2M iter/s)        (6-core)       Analysis
```

### 3. The Strategy Layer

Beyond raw probability, the **Exploitative Solver** analyzes opponent behavior to find edges:

**Behavioral Pattern Recognition:**
- Opponent bet sizing → Inferred hand strength range
- Position at table → Adjusted aggression expectations
- Stack-to-pot dynamics → Risk tolerance modeling

**Decision Framework:**
- Expected Value calculation for each action (fold/call/raise)
- Required edge threshold (must exceed pot odds by 5%)
- Position-aware adjustments (in-position players can profitably play wider ranges)

This layer transforms probability data into **actionable strategy**—not just "you have 45% equity," but "call: your 45% equity exceeds the 25% required by pot odds, giving you a +20% edge."

---

## Technical Architecture

```
PokerAssistant/
├── Engine/
│   ├── PokerShaders.metal          # GPU compute kernel (Monte Carlo)
│   ├── MetalCompute.swift          # Hardware acceleration layer
│   ├── MonteCarloEngine.swift      # Multi-core CPU simulation
│   ├── EquityCalculator.swift      # Intelligent compute routing
│   ├── ExploitativeSolver.swift    # Strategy & behavioral analysis
│   └── OpponentRange.swift         # 169-hand strength rankings
│
├── Models/
│   ├── GameState.swift             # Position, stack, pot state
│   └── CalculationResult.swift     # Recommendation + reasoning
│
├── ViewModels/
│   └── CalculationViewModel.swift  # Async computation handling
│
└── Views/
    └── [SwiftUI Interface]         # Real-time result display
```

### Technology Stack

| Layer | Implementation |
|-------|----------------|
| Interface | SwiftUI with reactive data binding |
| Architecture | MVVM with Combine framework |
| GPU Compute | Metal Performance Shaders |
| Concurrency | Swift async/await with actor isolation |
| Persistence | UserDefaults via @AppStorage |

---

## Validation

Equity calculations verified against known poker probabilities:

| Scenario | Expected | Calculated | Variance |
|----------|----------|------------|----------|
| AA vs 1 opponent | ~85% | 85.2% | +0.2% |
| AA vs 5 opponents | ~49% | 49.1% | +0.1% |
| AKs vs 5 opponents | ~31% | 31.4% | +0.4% |
| T2o vs 5 opponents | ~12% | 12.3% | +0.3% |

---

## Development Methodology

**Architected by Avo Sarkissian** using AI-assisted development workflows (Claude) to prioritize rapid prototyping and high-performance logic over boilerplate code.

This approach enabled:
- Faster iteration on complex algorithmic logic
- Focus on core engine performance rather than scaffolding
- Systematic debugging of GPU/CPU consistency issues

The result is a codebase optimized for **computational efficiency and maintainability**—not lines of code.

---

## Getting Started

**Requirements:** Xcode 15+, iOS 17+, physical device recommended

```bash
git clone https://github.com/Avo-Sarkissian/PokerAssistant.git
cd PokerAssistant
open PokerAssistant.xcodeproj
```

---

## Future Development

- Board texture analysis (scenario complexity modeling)
- Session analytics and decision review
- Extended behavioral modeling across multiple interactions
- GPU-accelerated opponent range filtering

---

<div align="center">

**Built with Swift and Metal**

*Tested on iPhone 16 Pro (A18 Pro) · Compatible with all iOS 17+ devices*

</div>
