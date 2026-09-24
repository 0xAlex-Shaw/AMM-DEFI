import { ethers } from 'hardhat';
import * as dotenv from 'dotenv';

dotenv.config();

async function main(token: string) {
  if (!token || !ethers.isAddress(token)) {
    throw new Error(`Usage: hardhat run scripts/add-basetoken.ts  (pass a token address)\nGot: ${token}`);
  }
  const address = process.env.FLASHBOT_ADDRESS;
  if (!address) throw new Error('Set FLASHBOT_ADDRESS in .env');

  const [signer] = await ethers.getSigners();
  const flashBot = await ethers.getContractAt('FlashBot', address, signer);

  const tx = await flashBot.addBaseToken(token);
  await tx.wait(1);
  console.log(`Base token added: ${token}`);
}

main(process.argv.slice(2)[0])
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
