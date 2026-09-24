import { ethers } from 'hardhat';
import { formatEther } from 'ethers';
import pool from '@ricokahler/pool';
import AsyncLock from 'async-lock';

import { Network, tryLoadPairs, getTokens } from './tokens';
import { getBnbPrice } from './basetoken-price';
import log from './log';
import config from './config';

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/// Net profit in USD, after the gas the arbitrage transaction will cost.
async function calcNetProfit(profitWei: bigint, address: string, baseTokens: Tokens): Promise<number> {
  let price = 1;
  if (baseTokens.wbnb.address === address) {
    price = await getBnbPrice();
  }
  // ethers v6 returns bigint, not BigNumber.
  const profit = parseFloat(formatEther(profitWei)) * price;
  const gasCost = price * parseFloat(formatEther(config.gasPrice)) * config.gasLimit;
  return profit - gasCost;
}

function arbitrageFunc(flashBot: any, baseTokens: Tokens) {
  const lock = new AsyncLock({ timeout: 2000, maxPending: 20 });

  return async function arbitrage(pair: ArbitragePair) {
    const [pair0, pair1] = pair.pairs;

    let profit: bigint;
    let baseToken: string;
    try {
      const res = await flashBot.getProfit(pair0, pair1);
      profit = res[0] as bigint;
      baseToken = res[1] as string;
      log.debug(`Profit on ${pair.symbols}: ${formatEther(profit)}`);
    } catch (err) {
      log.debug(`getProfit failed on ${pair.symbols}: ${errorMessage(err)}`);
      return;
    }

    if (profit <= 0n) return;

    const netProfit = await calcNetProfit(profit, baseToken, baseTokens);
    if (netProfit < config.minimumProfit) return;

    log.info(`Calling flash arbitrage on ${pair.symbols}, net profit: $${netProfit.toFixed(2)}`);
    try {
      // Serialise sends so two transactions cannot claim the same nonce.
      await lock.acquire('flash-bot', async () => {
        const response = await flashBot.flashArbitrage(pair0, pair1, {
          gasPrice: config.gasPrice,
          gasLimit: config.gasLimit,
        });
        const receipt = await response.wait(1);
        // ethers v6 renamed `transactionHash` to `hash`.
        log.info(`Tx: ${receipt?.hash}`);
      });
    } catch (err) {
      const msg = errorMessage(err);
      if (msg === 'Too much pending tasks' || msg === 'async-lock timed out') return;
      log.error(msg);
    }
  };
}

async function main() {
  const pairs = await tryLoadPairs(Network.BSC);
  const flashBot = await ethers.getContractAt('FlashBot', config.contractAddr);
  const [baseTokens] = getTokens(Network.BSC);

  log.info(`Start arbitraging ${pairs.length} pairs at concurrency ${config.concurrency}`);

  // Consecutive failures back off, so a flaky RPC endpoint does not turn into a hot loop hammering
  // it. The original was a bare `while (true)` with a fixed 1s sleep and no error handling at all.
  let consecutiveFailures = 0;

  for (;;) {
    try {
      await pool({
        collection: pairs,
        task: arbitrageFunc(flashBot, baseTokens),
        // The original passed no concurrency limit -- the `maxConcurrency` line was commented out --
        // so `config.concurrency` was dead config and every pair was queried at once.
        maxConcurrency: config.concurrency,
      });
      consecutiveFailures = 0;
      await sleep(1000);
    } catch (err) {
      consecutiveFailures += 1;
      const backoff = Math.min(1000 * 2 ** consecutiveFailures, 60_000);
      log.error(`Sweep failed (${consecutiveFailures}): ${errorMessage(err)}. Retrying in ${backoff}ms`);
      await sleep(backoff);
    }
  }
}

main().catch((err) => {
  log.error(err);
  process.exit(1);
});
