# AMM Arbitrageur

Atomic arbitrage between two Uniswap-V2-style AMMs holding the same token pair, funded by a flash
swap so no capital is ever at risk across transactions. If the trade is not profitable the whole
transaction reverts and you are out only the gas.

Originally [`paco0x/amm-arbitrageur`](https://github.com/paco0x/amm-arbitrageur) by Penghui Liao and
contributors, WTFPL. This tree is a 2026 overhaul: Solidity 0.7.6 → 0.8.28, a modern toolchain, a test
suite, and fixes for a set of defects described below.

```
contracts/
  FlashBot.sol                 the arbitrage contract
  libraries/PairMath.sol       constant-product maths, fee as a parameter
bot/                           TypeScript scanner that drives the contract
test/foundry/                  30 tests, incl. fuzz
```

## How it works

Two AMMs quoting the same pair at different prices can be closed out atomically:

1. Flash-borrow the quote token from the **cheaper** pool.
2. Sell it into the **richer** pool for the base token.
3. Repay the first pool's debt in base token, keep the difference.

The borrow size that maximises profit is the root of a quadratic in the four reserves; `FlashBot`
solves it on-chain in `calcBorrowAmount`, so the caller only supplies two pool addresses.

## Quick start

```bash
make setup                  # forge deps + node modules
make test                   # 30 tests
cp .env.example .env        # then fill it in
npx hardhat run scripts/deploy.ts --network bsc
```

Contract tests run under Foundry — no `node_modules` needed, and fuzzing the AMM maths is what it is
good at. Hardhat is retained for deployment and for the TypeScript bot, which needs Node anyway.

## Configuration

Everything comes from the environment; see [`.env.example`](.env.example). Nothing secret belongs in
source — the previous revision had the contract address and an API key as string literals in
`bot/config.ts`, and `scripts/` carried `'CONTRACT ADDRESS'` placeholders that threw at runtime.

### Pool fees matter

`FlashBot` tracks the swap fee **per pool**, because V2 forks do not agree on it — Uniswap V2 and
SushiSwap charge 0.30%, ApeSwap and PancakeSwap V1 charge 0.20%. Register anything that is not 0.30%
before you trade against it:

```solidity
flashBot.setPairFeeNumerator(apeSwapPool, 998);  // 998/1000 = 0.20%
```

Getting this wrong does not produce a small error. The profit calculation is wrong in both directions:
it claims profit that is not there, and rejects trades that were profitable.

## What was fixed

| | |
|---|---|
| **Swap fee hardcoded to 0.30%** | `getAmountIn`/`getAmountOut` multiplied by a literal `997` while the project advertised PancakeSwap, ApeSwap and MDEX support. Fees are now per pool. |
| **`sqrt` underflowed its own exit test** | An unbounded `while (true)` Newton loop breaking on `res - xi < 1000`. Under 0.7 that wrapped silently; under 0.8 it panics — so the naive compiler bump would have reverted on-chain inside an infinite loop. Replaced with a bit-length-seeded fixed-iteration root, exact to the floor. It also called `assert`, which burns all remaining gas. |
| **255 lines of `Decimal` to compare two prices** | The library existed only to divide reserves so the quotients could be compared. Cross-multiplication answers the same question with no division, so deleting it made the comparison *more* accurate. `SafeMath` and `SafeMathCopy` went too — 432 lines total. |
| **Borrow solver assumed 18 decimals** | The scaling divisor came from a hardcoded ladder of decimal thresholds, with a comment admitting the limitation. USDC (6) and WBTC (8) fell outside it. The shift is now derived from the actual bit width, correct for any decimals and any reserve size. |
| **Discriminant had to be strictly positive** | A legitimate double root reverted. |
| **`hardhat/console.sol` imported into the deployed contract** | Debug code and wasted gas in production bytecode. |
| **`payable(owner()).transfer(...)`** | The 2300-gas stipend fails outright when the owner is a Safe or any multisig. Now a checked `.call`. |
| **`withdraw()` was unguarded** | Callable by anyone, and a single reverting base token stranded every other balance. Now `onlyOwner`, per-token failures isolated, plus `withdrawToken` for anything left behind. |
| **Secrets in source** | Contract address and API key were string literals. Now environment variables, and the process refuses to start without them. |
| **Dependency rot** | `axios 0.21.1`, OpenZeppelin 3.4.2, ethers 5, hardhat 2.1.2, `@types/node` 14. The tree did not install on current Node at all. `axios` was pulled in for a single GET and is gone — native `fetch` replaces it. |
| **Bot had no error handling** | A bare `while (true)` with no backoff, so one RPC failure became a hot loop. `config.concurrency` was dead config — the `maxConcurrency` line was commented out, so every pair was queried at once. |

## Testing

```bash
make test        # 30 tests
make test-deep   # 20,000 fuzz runs
```

Tests target the defects specifically, so a regression names itself: the fee tests demonstrate the
mispricing the hardcoded constant caused, the `sqrt` tests cover exactly the inputs the old loop
mishandled, and the borrow-solver tests run 6-, 8- and 18-decimal reserves.

## Caveats

This is a proof of concept, and that has not changed. It is **not** competitive with production
arbitrage infrastructure:

- No MEV protection. Submitting these transactions to a public mempool invites front-running; route
  through a private relay if you intend to trade.
- Only V2-style constant-product pools. No V3, no concentrated liquidity, no stable-swap curves.
- Pair discovery is a static JSON file, not live factory enumeration.
- **Unaudited.** The contract has not been reviewed by anyone.

The contract is deliberately built for Paris, not Cancun, so it deploys across the long tail of EVM
chains. That costs about 5,000 gas per arbitrage versus using transient storage for the callback
guard; see the note in `FlashBot.sol` if you only target Cancun chains.

## Licence

WTFPL, inherited from the original.
