# Impossible Swap Core

This is the core repository for the new Impossible Swap v2, built by the Impossible Finance community.

Template is from [Uniswap V2](https://github.com/Uniswap/uniswap-v2-core) with logic modifications to support higher capital efficiency trades

Check out gitbook:
https://docs.impossible.finance/impossible-swap/overview

## Run Tests

`yarn` && `yarn test`

Test instructions:
1. In ImpossiblePair.sol, comment out line 59 in onlyGovernance modifier. This allows pools to be made stable for our tests.
2. Also in ImpossiblePair.sol, change delay of ONE_DAY to 50 instead of ONE_DAY = 24 * 60 * 60 / 3
3. In ImpossibleFactory.sol, comment out line 35-36 in setRouter function. This allows pair contracts to set router address and change for testing both routers

Deploy instructions:
1. Make sure to compile contracts in the non-test environment (to get correct pair ABI in ImpossibleLibrary's pairfor CREATE2)
2. Update pair ABI in ImpossibleLibrary in pairFor for CREATE2
3. Deploy factory and router, call factory.setRouter() on router
