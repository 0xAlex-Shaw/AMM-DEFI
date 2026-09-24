import AsyncLock from 'async-lock';

import config from './config';
import log from './log';

const lock = new AsyncLock();
const CACHE_TTL_MS = 60 * 60 * 1000;

let bnbPrice = 0;
let fetchedAt = 0;

/// Price of the chain's native token in USD, cached for an hour.
///
/// The original cleared this with a module-scope `setInterval`, which both kept the Node event loop
/// alive forever and cleared the cache on a wall-clock schedule unrelated to when it was last read.
/// A timestamp checked on read does the same job with no timer.
export async function getBnbPrice(): Promise<number> {
  return lock.acquire('bnb-price', async () => {
    if (bnbPrice !== 0 && Date.now() - fetchedAt < CACHE_TTL_MS) {
      return bnbPrice;
    }

    // Native fetch, available since Node 18. Replaces axios, which was pinned at 0.21.1 here and
    // has published advisories against it.
    const res = await fetch(config.basePriceUrl);
    if (!res.ok) throw new Error(`price lookup failed: ${res.status} ${res.statusText}`);

    const body = (await res.json()) as { result?: { ethusd?: string } };
    const raw = body.result?.ethusd;
    if (!raw) throw new Error(`price lookup returned no result: ${JSON.stringify(body)}`);

    const parsed = parseFloat(raw);
    if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`implausible price: ${raw}`);

    bnbPrice = parsed;
    fetchedAt = Date.now();
    log.info(`Base token price: $${bnbPrice}`);
    return bnbPrice;
  });
}
