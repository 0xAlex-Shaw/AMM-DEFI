import '@nomicfoundation/hardhat-toolbox';
import * as dotenv from 'dotenv';
import type { HardhatUserConfig } from 'hardhat/config';

dotenv.config();

// Forking is opt-in: without an archive endpoint the fork tests are skipped rather than failing,
// so `npm test` works on a clean clone with no configuration at all.
const forkUrl = process.env.BSC_ARCHIVE_RPC_URL ?? '';

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: { enabled: true, runs: 800 },
      // The bot targets a long tail of EVM chains, several of which are not on Cancun.
      // Paris keeps the bytecode deployable everywhere; see the note in FlashBot.sol.
      evmVersion: 'paris',
    },
  },
  networks: {
    hardhat: {
      forking: forkUrl ? { url: forkUrl } : undefined,
    },
    bsc: {
      url: process.env.BSC_RPC_URL ?? 'https://bsc-dataseed1.binance.org',
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
  mocha: { timeout: 120_000 },
};

export default config;
