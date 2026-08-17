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
    // Slots that actually exist in the results and seeds buffers. Appended last so the
    // offsets above are unchanged; must stay in step with the Swift struct.
    uint threadCount;
};

// Each thread writes to its own slot.
//
// Equity is accumulated in exact integer units rather than as wins and ties, because
// a chopped pot is worth 1/(n+1) and a flat half-pot credit overstates hero's share
// by up to 30 points when the board plays. EQUITY_UNIT is the least common multiple
// of 1...10, so every split up to a ten-way chop divides exactly.
#define EQUITY_UNIT 2520u

struct ThreadResult {
    uint equityUnits;
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
        // 50000 keeps the largest one-pair score (1,714,142) below the 2,000,000
        // two-pair base. With 100000 a pair of jacks or better outranked two pair.
        return 1000000 + pairRanks[0] * 50000 + k[0] * 1000 + k[1] * 10 + k[2];
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
    // The grid is dispatched in whole threadgroups of 256, but the results and seeds
    // buffers hold exactly `threadCount` slots. Every dispatch whose thread count is not
    // a multiple of 256 therefore had up to 255 threads reading and writing past the end
    // of both buffers — undefined behaviour that has only ever been survivable because
    // Metal rounds allocations up to a page.
    if (gid >= params->threadCount) return;

    uint seed = randomSeeds[gid] ^ (gid * 1099087573u) ^ 0xDEADBEEF;
    if (seed == 0) seed = 0x9E3779B9u;   // xorshift is degenerate at zero

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

    // Cards this deal still has to take from the deck: the rest of the board, plus two
    // for every opponent.
    uint neededCards = (5 - params->communityCount) + (params->opponents * 2);

    // The deck cannot seat the deal. Report nothing — a zero `total` makes the host
    // return nil, and the caller falls back rather than believing this thread.
    //
    // Reporting *something* is what made this dangerous. With no cards left the opponent
    // loop below breaks on its first seat, so `bestOppValue` stays 0, hero's real hand
    // beats 0, and every one of the 1000 iterations scored a win: the kernel answered a
    // spot that cannot be dealt with a confident 100%. With a partial board it was worse
    // still — the board fill is bounded by `communityCount`, not by `availableCount`, so
    // it read uninitialised stack and fed the garbage to `evaluate5Cards`, where
    // `counts[r[i]]++` indexes a 15-element array with whatever rank fell out.
    if (availableCount < neededCards) {
        results[gid].equityUnits = 0;
        results[gid].total = 0;
        return;
    }

    uint equityUnits = 0;

    // Pre-allocate shuffle array once outside loop
    uint shuffled[52];

    for (uint iter = 0; iter < 1000; iter++) {
        // Copy available cards for this iteration
        for (uint i = 0; i < availableCount; i++) shuffled[i] = availableCards[i];

        // Fisher-Yates partial shuffle - only shuffle what we need
        // CRITICAL: Use signed int to avoid unsigned underflow causing infinite loop
        for (int i = 0; i < (int)neededCards && i < (int)availableCount; i++) {
            // xorshift32 rather than an LCG: the LCG's low bits have period 2^k, and
            // `% bound` reads exactly those bits, which made consecutive draws
            // correlated and the two-card opponent distribution non-uniform.
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            // Lemire's multiply-shift: unbiased-enough bounded draw from the HIGH bits.
            uint bound = availableCount - (uint)i;
            uint j = (uint)i + (uint)(((ulong)seed * (ulong)bound) >> 32);
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

        // Evaluate opponents, tracking how many share the best hand so a chop can be
        // split by the number of players actually in it.
        uint bestOppValue = 0;
        uint tiedOpponents = 0;
        for (uint opp = 0; opp < params->opponents; opp++) {
            if (cardIndex + 1 >= availableCount) break;

            uint oppHand[7];
            oppHand[0] = shuffled[cardIndex++];
            oppHand[1] = shuffled[cardIndex++];
            for (uint i = 0; i < 5; i++) oppHand[2 + i] = myHand[2 + i];

            uint oppValue = evaluateHand7(oppHand);
            if (oppValue > bestOppValue) { bestOppValue = oppValue; tiedOpponents = 1; }
            else if (oppValue == bestOppValue) { tiedOpponents++; }
        }

        if (myValue > bestOppValue) {
            equityUnits += EQUITY_UNIT;
        } else if (myValue == bestOppValue) {
            equityUnits += EQUITY_UNIT / (tiedOpponents + 1);
        }
    }

    // Write to this thread's slot
    results[gid].equityUnits = equityUnits;
    results[gid].total = 1000;
}
