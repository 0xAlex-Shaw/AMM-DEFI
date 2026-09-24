import { ethers } from 'hardhat';
import * as dotenv from 'dotenv';

dotenv.config();

async function main() {
  const address = process.env.FLASHBOT_ADDRESS;
  if (!address) throw new Error('Set FLASHBOT_ADDRESS in .env');

  const flashBot = await ethers.getContractAt('FlashBot', address);

  console.log(`Address:      ${address}`);
  console.log(`Owner:        ${await flashBot.owner()}`);
  console.log(`WETH:         ${await flashBot.WETH()}`);
  console.log(`Default fee:  ${await flashBot.defaultFeeNumerator()} / 1000`);
  console.log('Base tokens: ', await flashBot.getBaseTokens());
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
