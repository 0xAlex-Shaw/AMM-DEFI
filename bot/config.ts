import { parseUnits } from 'ethers';
import * as dotenv from 'dotenv';

dotenv.config();

interface Config {
  contractAddr: string;
  logLevel: string;
  minimumProfit: number;
  gasPrice: bigint;
  gasLimit: number;
  basePriceUrl: string;
  concurrency: number;
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}. Copy .env.example to .env.`);
  }
  return value;
}

function num(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) throw new Error(`${name} is not a number: ${raw}`);
  return parsed;
}

// The original hardcoded the contract address and a BscScan API key as string literals in this file,
// with `XXXXXX` placeholders, which is how keys end up committed. Both now come from the environment
// and the process refuses to start without them.
const etherscanApiKey = required('ETHERSCAN_API_KEY');

const config: Config = {
  contractAddr: required('FLASHBOT_ADDRESS'),
  logLevel: process.env.LOG_LEVEL ?? 'info',
  // The per-chain bscscan.com endpoint the original used is being retired in favour of Etherscan's
  // V2 multichain API; chainid=56 is BSC.
  basePriceUrl: `https://api.etherscan.io/v2/api?chainid=56&module=stats&action=bnbprice&apikey=${etherscanApiKey}`,
  concurrency: num('MAX_CONCURRENCY', 20),
  minimumProfit: num('MIN_PROFIT_USD', 50),
  gasPrice: parseUnits(process.env.GAS_PRICE_GWEI ?? '10', 'gwei'),
  gasLimit: num('GAS_LIMIT', 300_000),
};

export default config;
