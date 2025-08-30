import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

type Crowdfunding = Awaited<ReturnType<typeof ethers.getContractFactory>> extends any ? any : never;

const toBN = (n: number | bigint) => BigInt(n);

async function deployMockToken(owner: string) {
  const Mock = await ethers.getContractFactory("MockToken");
  const token = await Mock.deploy(owner);
  await token.waitForDeployment();
  return token;
}

async function deployCrowdfunding(owner: string) {
  const token = await deployMockToken(owner);
  const CF = await ethers.getContractFactory("Crowdfunding");
  const cf = await CF.deploy(owner, await token.getAddress());
  await cf.waitForDeployment();
  return { cf, token };
}

describe("Crowdfunding (Solidity port)", function () {
  it("constructor sets owner and token", async () => {
    const [owner] = await ethers.getSigners();
    const { cf, token } = await deployCrowdfunding(owner.address);

    expect(await cf.get_asset_count()).to.equal(0n);
    expect(await cf.get_token_address()).to.equal(await token.getAddress());
  });

  it("create_asset stores data + emits event", async () => {
    const [owner, creator] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    await time.setNextBlockTimestamp(start);

    const goal = 10_000n;
    const duration = 86_400n;
    const basePrice = 100n;
    const ipfsHash = [123n, 456n, 789n];

    await expect(cf.connect(creator).createAsset(goal, Number(duration), basePrice, ipfsHash))
      .to.emit(cf, "AssetCreated")
      .withArgs(
        0n,
        creator.address,
        goal,
        start,
        Number(duration),
        basePrice,
        BigInt(ipfsHash.length),
        ipfsHash
      );

    expect(await cf.get_asset_count()).to.equal(1n);
    const a = await cf.get_asset_data(0);
    expect(a.creator).to.equal(creator.address);
    expect(a.goal).to.equal(goal);
    expect(a.raised).to.equal(0n);
    expect(a.start_time).to.equal(start);
    expect(a.end_time).to.equal(start + duration);
    expect(a.base_price).to.equal(basePrice);
    expect(a.is_closed).to.equal(false);
    expect(a.ipfs_hash_len).to.equal(BigInt(ipfsHash.length));

    const stored = await cf.get_asset_ipfs_hash(0);
    expect(stored.map((x: bigint) => x)).to.deep.equal(ipfsHash);
  });

  it("create_asset: reverts on zero duration / goal / basePrice", async () => {
    const [owner, creator] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    await expect(cf.connect(creator).createAsset(1000n, 0, 100n, []))
      .to.be.revertedWith("DURATION_MUST_BE_POSITIVE");
    await expect(cf.connect(creator).createAsset(0n, 86400, 100n, []))
      .to.be.revertedWith("GOAL_MUST_BE_POSITIVE");
    await expect(cf.connect(creator).createAsset(1000n, 86400, 0n, []))
      .to.be.revertedWith("BASE_PRICE_MUST_BE_POSITIVE");
  });

  it("fund: success + event + state", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    // create asset
    const now = await time.latest();
    const start = now + 10n;
    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(10_000n, 86_400, 100n, []);

    // inside window
    await time.setNextBlockTimestamp(start + 100n);
    // discounted price = min 10% -> 90
    await expect(cf.connect(investor).fund(0, 90n))
      .to.emit(cf, "Funded")
      .withArgs(0n, investor.address, 90n, start + 100n);

    const a = await cf.get_asset_data(0);
    expect(a.raised).to.equal(90n);

    const inv = await cf.get_investor_data(0, investor.address);
    expect(inv.amount).to.equal(90n);
    expect(inv.timestamp).to.equal(start + 100n);
  });

  it("fund: reverts zero amount / before start / after end / insufficient funds", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;
    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(1000n, Number(duration), 100n, []);

    // zero
    await time.setNextBlockTimestamp(start + 1n);
    await expect(cf.connect(investor).fund(0, 0n)).to.be.revertedWith("AMOUNT_ZERO");

    // before start
    await time.setNextBlockTimestamp(start - 1n);
    await expect(cf.connect(investor).fund(0, 100n)).to.be.revertedWith("FUNDING_NOT_STARTED");

    // after end
    await time.setNextBlockTimestamp(start + duration + 1n);
    await expect(cf.connect(investor).fund(0, 100n)).to.be.revertedWith("FUNDING_ENDED");

    // insufficient (need >= 90)
    await time.setNextBlockTimestamp(start + 10n);
    await expect(cf.connect(investor).fund(0, 89n)).to.be.revertedWith("INSUFFICIENT_FUNDS");
  });

  it("close_funding: success path (goal met)", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;
    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(100n, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + 10n);
    await cf.connect(investor).fund(0, 100n); // >= 90 and reaches goal

    await time.setNextBlockTimestamp(start + duration + 1n);
    await expect(cf.connect(creator).close_funding(0))
      .to.emit(cf, "FundingClosed")
      .withArgs(0n, 100n, true);

    const a = await cf.get_asset_data(0);
    expect(a.is_closed).to.equal(true);
  });

  it("close_funding: goal not met → success=false", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;
    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(1000n, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + 10n);
    await cf.connect(investor).fund(0, 90n); // enough to pass, below goal

    await time.setNextBlockTimestamp(start + duration + 1n);
    const aBefore = await cf.get_asset_data(0);
    await expect(cf.connect(creator).close_funding(0))
      .to.emit(cf, "FundingClosed")
      .withArgs(0n, aBefore.raised, false);

    const a = await cf.get_asset_data(0);
    expect(a.is_closed).to.equal(true);
  });

  it("close_funding: reverts when not creator / before end", async () => {
    const [owner, creator, other] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;
    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(1000n, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + duration + 1n);
    await expect(cf.connect(other).close_funding(0)).to.be.revertedWith("NOT_CREATOR");

    await time.setNextBlockTimestamp(start + 1n);
    await expect(cf.connect(creator).close_funding(0)).to.be.revertedWith("FUNDING_NOT_ENDED");
  });

  it("withdraw_creator: transfers tokens + emits event", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf, token } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;
    const amount = 100n;

    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(amount, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + 10n);
    await cf.connect(investor).fund(0, amount);

    await time.setNextBlockTimestamp(start + duration + 1n);
    await cf.connect(creator).close_funding(0);

    // mint tokens to the CONTRACT so it can transfer to creator
    const cfAddr = await cf.getAddress();
    await token.mint(cfAddr, amount);

    const balBefore = await token.balanceOf(creator.address);
    await expect(cf.connect(creator).withdraw_creator(0))
      .to.emit(cf, "CreatorWithdrawal")
      .withArgs(0n, amount);

    const balAfter = await token.balanceOf(creator.address);
    expect(balAfter - balBefore).to.equal(amount);
  });

  it("withdraw_creator: reverts when goal not reached", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf, token } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;

    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(1000n, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + 10n);
    await cf.connect(investor).fund(0, 90n); // < goal

    await time.setNextBlockTimestamp(start + duration + 1n);
    await cf.connect(creator).close_funding(0);

    // même avec des tokens dispos, ça doit revert
    await token.mint(await cf.getAddress(), 90n);
    await expect(cf.connect(creator).withdraw_creator(0)).to.be.revertedWith("GOAL_NOT_REACHED");
  });

  it("withdraw_investor: refunds when goal not met", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf, token } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;
    const amt = 100n;

    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(1000n, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + 10n);
    await cf.connect(investor).fund(0, amt);

    await time.setNextBlockTimestamp(start + duration + 1n);
    await cf.connect(creator).close_funding(0);

    // provisionner le contrat
    await token.mint(await cf.getAddress(), amt);

    const before = await token.balanceOf(investor.address);
    await expect(cf.connect(investor).withdraw_investor(0))
      .to.emit(cf, "InvestorWithdrawal")
      .withArgs(0n, investor.address, amt);

    const after = await token.balanceOf(investor.address);
    expect(after - before).to.equal(amt);

    const inv = await cf.get_investor_data(0, investor.address);
    expect(inv.amount).to.equal(0n);
    expect(inv.timestamp).to.equal(0n);
  });

  it("withdraw_investor: reverts when goal reached", async () => {
    const [owner, creator, investor] = await ethers.getSigners();
    const { cf, token } = await deployCrowdfunding(owner.address);

    const now = await time.latest();
    const start = now + 10n;
    const duration = 100n;

    await time.setNextBlockTimestamp(start);
    await cf.connect(creator).createAsset(100n, Number(duration), 100n, []);

    await time.setNextBlockTimestamp(start + 10n);
    await cf.connect(investor).fund(0, 100n);

    await time.setNextBlockTimestamp(start + duration + 1n);
    await cf.connect(creator).close_funding(0);

    await token.mint(await cf.getAddress(), 100n);
    await expect(cf.connect(investor).withdraw_investor(0)).to.be.revertedWith("GOAL_REACHED");
  });

  it("set_token_address: only owner", async () => {
    const [owner, other] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    await expect(cf.connect(other).set_token_address(other.address))
      .to.be.revertedWith("NOT_CONTRACT_OWNER");

    await cf.connect(owner).set_token_address(other.address);
    expect(await cf.get_token_address()).to.equal(other.address);
  });

  it("getters sanity", async () => {
    const [owner, creator, investor, other] = await ethers.getSigners();
    const { cf } = await deployCrowdfunding(owner.address);

    expect(await cf.get_asset_count()).to.equal(0n);

    const now = await time.latest();
    const start = now + 10n;
    await time.setNextBlockTimestamp(start);
    const goal = 10_000n;
    const basePrice = 100n;
    const ipfs = [123n, 456n];
    await cf.connect(creator).createAsset(goal, 86_400, basePrice, ipfs);

    expect(await cf.get_asset_count()).to.equal(1n);

    const a = await cf.get_asset_data(0);
    expect(a.creator).to.equal(creator.address);
    expect(a.goal).to.equal(goal);
    expect(a.start_time).to.equal(start);

    const ipfsStored = await cf.get_asset_ipfs_hash(0);
    expect(ipfsStored.map((x: bigint) => x)).to.deep.equal(ipfs);

    const fundTime = start + 100n;
    await time.setNextBlockTimestamp(fundTime);
    await cf.connect(investor).fund(0, 100n);

    const inv = await cf.get_investor_data(0, investor.address);
    expect(inv.amount).to.equal(100n);
    expect(inv.timestamp).to.equal(fundTime);

    const invNone = await cf.get_investor_data(0, other.address);
    expect(invNone.amount).to.equal(0n);
    expect(invNone.timestamp).to.equal(0n);
  });
});
