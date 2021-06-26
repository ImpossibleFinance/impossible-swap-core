# Impossible Swap Core

This is the core repository for the new Impossible Swap v2, built by the Impossible Finance community.

Template is from [Uniswap V2](https://github.com/Uniswap/uniswap-v2-core) with logic modifications to support higher capital efficiency trades

Check out gitbook for some documentation:
https://docs.impossible.finance/impossible-swap/overview

# For auditors:

Can skip auditing Router01 file and just look at Router02. We'll do a cleanup of router01 file and in the tests before audit ends just to get a final clean commit.

# Overview of changes:

1. In pair contracts, we removed price oracle functionality
2. In pair contracts, added variable fee + ability to change invariants + ability to tune hardstops. For xybk invariants, boosts can be changed (note: boosts change over time instead of immediate. Immediate changes in boosts opens up the possibility for governance to rugpull). Hardstop toggling opens up halting all trade in swaps through setting lower hardstop > higher hardstop.
3. In pair contracts, for K invariant check, either xyk or xybk is done
4. In pair contracts, swap can only be called by our IF router (extra safety precaution)
5. In router contracts, getAmountX/getAmountsX at the library level is reengineered to perform optimal input/output calculations for xyk and xybk swaps. Note: although our test cases passes, we're slightly worried about the calculations at router level not matching the K check calculations at pair level. We're planning to create a fuzzy test in hardhat to check if there are any cases in which amounts quoted by a good IF router can end up being reverted at pair contract level for insufficient K.
6. In factory contracts, we have a token whitelist feature to prevent attackers from performing custom token attacks (extra safety precaution)

# Testing information:

yarn && yarn test

In ImpossiblePair.sol, we set ONE_DAY to 50 blocks. It will be 28800 in production. We have to do 50 in tests because calling evm_mine 28800 times per test to set the right boost causes tests to timeout
