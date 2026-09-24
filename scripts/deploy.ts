import { ethers, run } from 'hardhat';
import * as dotenv from 'dotenv';

dotenv.config();

// WBNB on BSC. Override for other chains.
const DEFAULT_WETH = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';

async function main() {
  await run('compile');

  const weth = process.env.WETH_ADDRESS ?? DEFAULT_WETH;
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error('No signer. Set PRIVATE_KEY in .env.');

  console.log(`Deploying FlashBot from ${signer.address} with WETH=${weth}`);

  const factory = await ethers.getContractFactory('FlashBot');
  const flashBot = await factory.deploy(weth);
  await flashBot.waitForDeployment();

  // ethers v6: `.address` became `getAddress()`, and deployment is awaited explicitly.
  console.log(`FlashBot deployed to ${await flashBot.getAddress()}`);
  console.log('Set FLASHBOT_ADDRESS in .env to this value before running the bot.');
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
