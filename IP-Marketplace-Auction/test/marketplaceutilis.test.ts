import { ethers } from "hardhat";
import { Contract, Signer } from "ethers";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";

export const DAY_IN_SECONDS = 24 * 60 * 60;

export type Deployed = {
  owner: Signer;
  bob: Signer;
  alice: Signer;
  ownerAddr: string;
  bobAddr: string;
  aliceAddr: string;
  erc20: Contract;
  erc721: Contract;
  market: Contract;
  tokenId: bigint;
};

export const AUCTION_DURATION_DAYS = 1n;
export const REVEAL_DURATION_DAYS = 1n;

export const STARTING_PRICE = 200n;
export const BID_BOB = 200n;
export const BID_ALICE = 500n;
export const SALT = ethers.encodeBytes32String("salt");

export async function deployAll(): Promise<Deployed> {
  const [owner, bob, alice] = await ethers.getSigners();
  const ownerAddr = await owner.getAddress();
  const bobAddr = await bob.getAddress();
  const aliceAddr = await alice.getAddress();

  // Deploy ERC20 (MyToken) — mint 100M to bob (recipient)
  const MyToken = await ethers.getContractFactory("MyToken");
  const erc20 = await MyToken.connect(bob).deploy(bobAddr);
  await erc20.waitForDeployment();

  // fund Alice for tests
  await erc20.connect(bob).transfer(aliceAddr, 10_000n * 10n ** 18n);

  // Deploy ERC721 (MyNFT)
  const MyNFT = await ethers.getContractFactory("MyNFT");
  const erc721 = await MyNFT.connect(owner).deploy(ownerAddr);
  await erc721.waitForDeployment();

  // mint token to owner
  const mintTx = await erc721.connect(owner).mint(ownerAddr);
  const mintRc = await mintTx.wait();
  // tokenId = totalSupply in our simple impl; we can read from Transfer event
  const transferEv = mintRc!.logs.find((l: any) => l.fragment?.name === "Transfer");
  const tokenId: bigint = transferEv?.args?.tokenId ?? 1n;

  // Deploy MarketPlace
  const Market = await ethers.getContractFactory("MarketPlace");
  const market = await Market.connect(owner).deploy(AUCTION_DURATION_DAYS, REVEAL_DURATION_DAYS);
  await market.waitForDeployment();

  // Approvals for ERC20 spending by market
  await erc20.connect(bob).approve(await market.getAddress(), ethers.MaxUint256);
  await erc20.connect(alice).approve(await market.getAddress(), ethers.MaxUint256);

  return { owner, bob, alice, ownerAddr, bobAddr, aliceAddr, erc20, erc721, market, tokenId };
}

export async function approveNFTToMarket(erc721: Contract, market: Contract, owner: Signer, tokenId: bigint) {
  await erc721.connect(owner).approve(await market.getAddress(), tokenId);
}

/** increase blockchain time by N days and mine one block */
export async function fastForwardDays(days: bigint | number) {
  await time.increase(Number(days) * DAY_IN_SECONDS);
}
