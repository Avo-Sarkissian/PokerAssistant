//
//  PokerShaders.metal
//  PokerAssistant
//
//  Pre-compiled Metal shader for Monte Carlo poker simulation
//  Compiled at BUILD time, not runtime - eliminates 5-10 second startup delay
//

#include <metal_stdlib>
using namespace metal;

struct SimulationParams {
    uint iterations;
    uint opponents;
    uint holeCard1;
    uint holeCard2;
    uint communityCount;
    uint community[5];
    uint deadCount;
    uint deadCards[52];
};

// Each thread writes to its own slot
struct ThreadResult {
    uint wins;
    uint ties;
    uint total;
};

uint evaluate5Cards(uint c0, uint c1, uint c2, uint c3, uint c4) {
    uint r[5], s[5];
    r[0] = (c0 >> 2) + 2;
    r[1] = (c1 >> 2) + 2;
    r[2] = (c2 >> 2) + 2;
    r[3] = (c3 >> 2) + 2;
    r[4] = (c4 >> 2) + 2;
    s[0] = c0 & 3;
    s[1] = c1 & 3;
    s[2] = c2 & 3;
    s[3] = c3 & 3;
    s[4] = c4 & 3;

    for (int i = 0; i < 4; i++) {
        for (int j = i + 1; j < 5; j++) {
            if (r[j] > r[i]) {
                uint temp = r[i]; r[i] = r[j]; r[j] = temp;
                temp = s[i]; s[i] = s[j]; s[j] = temp;
            }
        }
    }

    bool isFlush = (s[0] == s[1]) && (s[1] == s[2]) && (s[2] == s[3]) && (s[3] == s[4]);
    bool isStraight = (r[0] - r[4] == 4) && (r[0] != r[1]) && (r[1] != r[2]) && (r[2] != r[3]) && (r[3] != r[4]);
    bool isWheel = (r[0] == 14 && r[1] == 5 && r[2] == 4 && r[3] == 3 && r[4] == 2);
    if (isWheel) isStraight = true;

    if (isFlush && isStraight) return 8000000 + (isWheel ? 5 : r[0]);

    uint counts[15] = {0};
    for (int i = 0; i < 5; i++) counts[r[i]]++;

    uint quadRank = 0, tripRank = 0, pairRanks[2] = {0, 0}, numPairs = 0;

    for (int rank = 14; rank >= 2; rank--) {
        if (counts[rank] == 4) quadRank = rank;
        else if (counts[rank] == 3) tripRank = rank;
        else if (counts[rank] == 2 && numPairs < 2) pairRanks[numPairs++] = rank;
    }

    if (quadRank > 0) {
        uint kicker = 0;
        for (int i = 0; i < 5; i++) if (r[i] != quadRank) { kicker = r[i]; break; }
        return 7000000 + quadRank * 100 + kicker;
    }
    if (tripRank > 0 && numPairs > 0) return 6000000 + tripRank * 100 + pairRanks[0];
    if (isFlush) return 5000000 + (r[0] << 16) + (r[1] << 12) + (r[2] << 8) + (r[3] << 4) + r[4];
    if (isStraight) return 4000000 + (isWheel ? 5 : r[0]);
    if (tripRank > 0) {
        uint k[2]; int ki = 0;
        for (int i = 0; i < 5 && ki < 2; i++) if (r[i] != tripRank) k[ki++] = r[i];
        return 3000000 + tripRank * 10000 + k[0] * 100 + k[1];
    }
    if (numPairs >= 2) {
        uint kicker = 0;
        for (int i = 0; i < 5; i++) if (r[i] != pairRanks[0] && r[i] != pairRanks[1]) { kicker = r[i]; break; }
        return 2000000 + pairRanks[0] * 10000 + pairRanks[1] * 100 + kicker;
    }
    if (numPairs == 1) {
        uint k[3]; int ki = 0;
        for (int i = 0; i < 5 && ki < 3; i++) if (r[i] != pairRanks[0]) k[ki++] = r[i];
        return 1000000 + pairRanks[0] * 100000 + k[0] * 1000 + k[1] * 10 + k[2];
    }
    return (r[0] << 16) + (r[1] << 12) + (r[2] << 8) + (r[3] << 4) + r[4];
}

uint evaluateHand7(uint cards[7]) {
    uint best = 0;
    for (int skip1 = 0; skip1 < 6; skip1++) {
        for (int skip2 = skip1 + 1; skip2 < 7; skip2++) {
            uint hand[5]; int hi = 0;
            for (int k = 0; k < 7; k++) {
                if (k != skip1 && k != skip2) hand[hi++] = cards[k];
            }
            uint val = evaluate5Cards(hand[0], hand[1], hand[2], hand[3], hand[4]);
            if (val > best) best = val;
        }
    }
    return best;
}

kernel void monteCarloPoker(
    device ThreadResult* results [[buffer(0)]],
    constant SimulationParams* params [[buffer(1)]],
    device uint* randomSeeds [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    uint seed = randomSeeds[gid] ^ (gid * 1099087573u) ^ 0xDEADBEEF;

    // Build available cards array
    uint availableCards[52];
    uint availableCount = 0;

    bool isUsed[52] = {false};
    isUsed[params->holeCard1] = true;
    isUsed[params->holeCard2] = true;

    for (uint i = 0; i < params->communityCount; i++) {
        isUsed[params->community[i]] = true;
    }
    for (uint i = 0; i < params->deadCount; i++) {
        isUsed[params->deadCards[i]] = true;
    }

    for (uint i = 0; i < 52; i++) {
        if (!isUsed[i]) availableCards[availableCount++] = i;
    }

    uint wins = 0, ties = 0;

    for (uint iter = 0; iter < 1000; iter++) {
        // Fisher-Yates shuffle
        uint shuffled[52];
        for (uint i = 0; i < availableCount; i++) shuffled[i] = availableCards[i];

        for (uint i = availableCount - 1; i > 0; i--) {
            seed = seed * 1664525u + 1013904223u;
            uint j = seed % (i + 1);
            uint temp = shuffled[i];
            shuffled[i] = shuffled[j];
            shuffled[j] = temp;
        }

        // Build my hand
        uint myHand[7];
        myHand[0] = params->holeCard1;
        myHand[1] = params->holeCard2;

        uint cardIndex = 0;
        for (uint i = 0; i < params->communityCount; i++) {
            myHand[2 + i] = params->community[i];
        }
        for (uint i = params->communityCount; i < 5; i++) {
            myHand[2 + i] = shuffled[cardIndex++];
        }

        uint myValue = evaluateHand7(myHand);

        // Evaluate opponents
        uint bestOppValue = 0;
        for (uint opp = 0; opp < params->opponents; opp++) {
            if (cardIndex + 1 >= availableCount) break;

            uint oppHand[7];
            oppHand[0] = shuffled[cardIndex++];
            oppHand[1] = shuffled[cardIndex++];
            for (uint i = 0; i < 5; i++) oppHand[2 + i] = myHand[2 + i];

            uint oppValue = evaluateHand7(oppHand);
            if (oppValue > bestOppValue) bestOppValue = oppValue;
        }

        if (myValue > bestOppValue) wins++;
        else if (myValue == bestOppValue) ties++;
    }

    // Write to this thread's slot
    results[gid].wins = wins;
    results[gid].ties = ties;
    results[gid].total = 1000;
}
