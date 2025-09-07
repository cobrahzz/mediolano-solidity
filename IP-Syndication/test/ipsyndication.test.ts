import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, Signer } from "ethers";
import { MaxUint256 } from "ethers";

type Deployed = {
  ips: Contract;
  assetNFT: Contract;
  erc20: Contract;
  owner: Signer;
  bob: Signer;
  alice: Signer;
  mike: Signer;
  deployer: Signer;
};

async function deployAll(): Promise<Deployed> {
  const [deployer, owner, bob, alice, mike] = await ethers.getSigners();

  // AssetNFT
  const AssetNFT = await ethers.getContractFactory("AssetNFT", deployer);
  const assetNFT = await AssetNFT.deploy("uri/");
  await assetNFT.waitForDeployment();

  // IPSyndication
  const IPS = await ethers.getContractFactory("IPSyndication", deployer);
  const ips = await IPS.deploy(await assetNFT.getAddress());
  await ips.waitForDeployment();

  // ERC20 (MyToken) — mint initial supply to `owner`
  const MyToken = await ethers.getContractFactory("MyToken", deployer);
  const erc20 = await MyToken.deploy(await owner.getAddress());
  await erc20.waitForDeployment();

  // Fund & approve
  // owner: already has full supply, approve IPS
  await erc20.connect(owner).approve(await ips.getAddress(), MaxUint256);
  // fund alice & mike
  await erc20.connect(owner).transfer(await alice.getAddress(), 10_000n);
  await erc20.connect(owner).transfer(await mike.getAddress(), 10_000n);
  // approve IPS for alice & mike
  await erc20.connect(alice).approve(await ips.getAddress(), MaxUint256);
  await erc20.connect(mike).approve(await ips.getAddress(), MaxUint256);

  return { ips, assetNFT, erc20, owner, bob, alice, mike, deployer };
}

// Helpers for enums (must match order in Solidity)
const Status = {
  Pending: 0n,
  Active: 1n,
  Completed: 2n,
  Cancelled: 3n,
} as const;

const Mode = {
  Public: 0,
  Whitelist: 1,
} as const;

describe("IPSyndication (converted from Cairo tests)", () => {
  it("test_register_ip_price_is_zero", async () => {
    const { ips, erc20 } = await deployAll();
    await expect(
      ips.register_ip(
        0n,
        "flawless",
        "description",
        "flawless/",
        1n, // licensing_terms (felt -> uint256)
        Mode.Public,
        await erc20.getAddress()
      )
    ).to.be.revertedWith("Price can not be zero");
  });

  it("test_register_ip_price_invalid_currency_address", async () => {
    const { ips } = await deployAll();
    await expect(
      ips.register_ip(
        100n,
        "flawless",
        "description",
        "flawless/",
        1n,
        Mode.Public,
        ethers.ZeroAddress
      )
    ).to.be.revertedWith("Invalid currency address");
  });

  it("test_register_ip_price_ok", async () => {
    const { ips, erc20, bob } = await deployAll();
    const price = 100n;
    const name = "flawless";
    const description = "description";
    const uri = "flawless/";
    const licensingTerms = 123n;

    const tx = await ips
      .connect(bob)
      .register_ip(price, name, description, uri, licensingTerms, Mode.Public, await erc20.getAddress());
    const rc = await tx.wait();
    // ip_id = 1
    const ip_id = 1n;

    const meta = await ips.get_ip_metadata(ip_id);
    expect(meta.ip_id).to.equal(ip_id);
    expect(meta.owner).to.equal(await bob.getAddress());
    expect(meta.price).to.equal(price);
    expect(meta.description).to.equal(description);
    expect(meta.uri).to.equal(uri);
    expect(meta.licensing_terms).to.equal(licensingTerms);
    expect(meta.token_id).to.equal(ip_id);

    const details = await ips.get_syndication_details(ip_id);
    expect(details.ip_id).to.equal(ip_id);
    expect(details.mode).to.equal(Mode.Public);
    expect(details.status).to.equal(Status.Pending);
    expect(details.total_raised).to.equal(0n);
    expect(details.participant_count).to.equal(0n);
    expect(details.currency_address).to.equal(await erc20.getAddress());
  });

  it("test_activate_syndication_not_ip_owner", async () => {
    const { ips, erc20, bob, deployer } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;

    const details = await ips.get_syndication_details(ip_id);
    expect(details.status).to.equal(Status.Pending);

    await expect(ips.connect(deployer).activate_syndication(ip_id)).to.be.revertedWith("Not IP owner");
  });

  it("test_activate_syndication_ok", async () => {
    const { ips, erc20, bob } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;

    expect((await ips.get_syndication_details(ip_id)).status).to.equal(Status.Pending);

    await ips.connect(bob).activate_syndication(ip_id);
    expect((await ips.get_syndication_details(ip_id)).status).to.equal(Status.Active);
  });

  it("test_activate_syndication_when_active", async () => {
    const { ips, erc20, bob } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;

    await ips.connect(bob).activate_syndication(ip_id);
    expect((await ips.get_syndication_details(ip_id)).status).to.equal(Status.Active);

    await expect(ips.connect(bob).activate_syndication(ip_id)).to.be.revertedWith("Syndication is active");
  });

  it("test_deposit_non_active", async () => {
    const { ips, erc20 } = await deployAll();
    await ips.register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await expect(ips.deposit(ip_id, 100n)).to.be.revertedWith("Syndication not active");
  });

  it("test_deposit_amount_is_zero", async () => {
    const { ips, erc20, bob } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);
    await expect(ips.deposit(ip_id, 0n)).to.be.revertedWith("Amount can not be zero");
  });

  it("test_deposit_insufficient_balance", async () => {
    const { ips, erc20, bob, deployer } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    // deployer has 0 tokens
    await expect(ips.connect(deployer).deposit(ip_id, 100n)).to.be.revertedWith("Insufficient balance");
  });

  it("test_deposit_for_whitelist_mode", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Whitelist, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await expect(ips.connect(owner).deposit(ip_id, 100n)).to.be.revertedWith("Address not whitelisted");
  });

  it("test_deposit_when_completed", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, 100n);
    await expect(ips.connect(owner).deposit(ip_id, 100n)).to.be.revertedWith("Syndication not active");
  });

  it("test_deposit_ok_public_mode", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    const deposit = 100n;

    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    const ownerBalBefore = await erc20.balanceOf(await owner.getAddress());

    await ips.connect(owner).deposit(ip_id, deposit);

    const participants = await ips.get_all_participants(ip_id);
    expect(participants.length).to.equal(1);
    expect(participants[0]).to.equal(await owner.getAddress());

    const details = await ips.get_syndication_details(ip_id);
    expect(details.total_raised).to.equal(deposit);
    expect(details.participant_count).to.equal(1n);

    const pd = await ips.get_participant_details(ip_id, await owner.getAddress());
    expect(pd.amount_deposited).to.equal(deposit);
    expect(pd.minted).to.equal(false);
    expect(pd.amount_refunded).to.equal(0n);

    const ownerBalAfter = await erc20.balanceOf(await owner.getAddress());
    const ipsBal = await erc20.balanceOf(await ips.getAddress());
    expect(ipsBal).to.equal(deposit);
    expect(ownerBalBefore - ownerBalAfter).to.equal(deposit);
  });

  it("test_deposit_ok_whitelist_mode", async () => {
    const { ips, erc20, bob, alice } = await deployAll();
    const deposit = 100n;

    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Whitelist, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);
    await ips.connect(bob).update_whitelist(ip_id, await alice.getAddress(), true);

    const aliceBefore = await erc20.balanceOf(await alice.getAddress());
    await ips.connect(alice).deposit(ip_id, deposit);
    const aliceAfter = await erc20.balanceOf(await alice.getAddress());

    const parts = await ips.get_all_participants(ip_id);
    expect(parts.length).to.equal(1);
    expect(parts[0]).to.equal(await alice.getAddress());

    const details = await ips.get_syndication_details(ip_id);
    expect(details.total_raised).to.equal(deposit);
    expect(details.participant_count).to.equal(1n);

    const pd = await ips.get_participant_details(ip_id, await alice.getAddress());
    expect(pd.amount_deposited).to.equal(deposit);
    expect(pd.minted).to.equal(false);
    expect(pd.amount_refunded).to.equal(0n);

    const ipsBal = await erc20.balanceOf(await ips.getAddress());
    expect(ipsBal).to.equal(deposit);
    expect(aliceBefore - aliceAfter).to.equal(deposit);
  });

  it("test_deposit_with_excess_deposit", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    const price = 100n;
    const deposit = 200n;
    const expected = 100n;

    await ips
      .connect(bob)
      .register_ip(price, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    const ownerBefore = await erc20.balanceOf(await owner.getAddress());
    await ips.connect(owner).deposit(ip_id, deposit);

    const parts = await ips.get_all_participants(ip_id);
    expect(parts[0]).to.equal(await owner.getAddress());

    const details = await ips.get_syndication_details(ip_id);
    expect(details.total_raised).to.equal(expected);
    expect(details.participant_count).to.equal(1n);

    const pd = await ips.get_participant_details(ip_id, await owner.getAddress());
    expect(pd.amount_deposited).to.equal(expected);
    expect(pd.minted).to.equal(false);
    expect(pd.amount_refunded).to.equal(0n);

    const ownerAfter = await erc20.balanceOf(await owner.getAddress());
    const ipsBal = await erc20.balanceOf(await ips.getAddress());
    expect(ipsBal).to.equal(expected);
    expect(ownerBefore - ownerAfter).to.equal(expected);
  });

  it("test_get_participant_count", async () => {
    const { ips, erc20, bob, owner, alice } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, 100n);
    await ips.connect(alice).deposit(ip_id, 100n);

    expect(await ips.get_participant_count(ip_id)).to.equal(2n);
  });

  it("test_get_all_participants", async () => {
    const { ips, erc20, bob, owner, alice } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, 100n);
    await ips.connect(alice).deposit(ip_id, 100n);

    const parts = await ips.get_all_participants(ip_id);
    expect(parts.length).to.equal(2);
    expect(parts[0]).to.equal(await owner.getAddress());
    expect(parts[1]).to.equal(await alice.getAddress());
  });

  it("test_update_whitelist_non_owner", async () => {
    const { ips, erc20, bob, deployer, alice } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Whitelist, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await expect(
      ips.connect(deployer).update_whitelist(ip_id, await alice.getAddress(), true)
    ).to.be.revertedWith("Not IP owner");
  });

  it("test_update_whitelist_syndication_non_active", async () => {
    const { ips, erc20, bob, alice } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Whitelist, await erc20.getAddress());
    const ip_id = 1n;

    await expect(
      ips.connect(bob).update_whitelist(ip_id, await alice.getAddress(), true)
    ).to.be.revertedWith("Syndication not active");
  });

  it("test_update_whitelist_not_in_whitelist_mode", async () => {
    const { ips, erc20, bob, alice } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await expect(
      ips.connect(bob).update_whitelist(ip_id, await alice.getAddress(), true)
    ).to.be.revertedWith("Not in whitelist mode");
  });

  it("test_update_whitelist_ok", async () => {
    const { ips, erc20, bob, alice, owner } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Whitelist, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(bob).update_whitelist(ip_id, await alice.getAddress(), true);

    expect(await ips.is_whitelisted(ip_id, await alice.getAddress())).to.equal(true);
    expect(await ips.is_whitelisted(ip_id, await owner.getAddress())).to.equal(false);
  });

  it("test_cancel_syndication_non_owner", async () => {
    const { ips, erc20, bob, deployer } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await expect(ips.connect(deployer).cancel_syndication(ip_id)).to.be.revertedWith("Not IP owner");
  });

  it("test_cancel_syndication_when_completed", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, 100n);
    await expect(ips.connect(bob).cancel_syndication(ip_id)).to.be.revertedWith("Syn: completed or cancelled");
  });

  it("test_cancel_syndication_ok", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    const deposit = 500n;
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, deposit);

    const ownerBefore = await erc20.balanceOf(await owner.getAddress());
    await ips.connect(bob).cancel_syndication(ip_id);
    const ownerAfter = await erc20.balanceOf(await owner.getAddress());

    expect(ownerAfter - ownerBefore).to.equal(deposit);
    expect(await erc20.balanceOf(await ips.getAddress())).to.equal(0n);
    expect((await ips.get_syndication_details(ip_id)).status).to.equal(Status.Cancelled);
  });

  it("test_mint_asset_non_competed_syn", async () => {
    const { ips, erc20, bob, owner } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(1000n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, 500n);
    await expect(ips.connect(owner).mint_asset(ip_id)).to.be.revertedWith("Syndication not completed");
  });

  it("test_mint_asset_non_participant", async () => {
    const { ips, erc20, bob, owner, alice } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(owner).deposit(ip_id, 100n);
    await expect(ips.connect(alice).mint_asset(ip_id)).to.be.revertedWith("Not Syndication Participant");
  });

  it("test_mint_asset_already_minted", async () => {
    const { ips, erc20, bob, mike } = await deployAll();
    await ips
      .connect(bob)
      .register_ip(100n, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    await ips.connect(mike).deposit(ip_id, 100n);

    await ips.connect(mike).mint_asset(ip_id);
    await expect(ips.connect(mike).mint_asset(ip_id)).to.be.revertedWith("Already minted");
  });

  it("test_mint_asset_ok", async () => {
    const { ips, erc20, assetNFT, bob, mike, alice, owner } = await deployAll();

    const price = 100_000_000n;
    await ips
      .connect(bob)
      .register_ip(price, "flawless", "description", "flawless/", 1n, Mode.Public, await erc20.getAddress());
    const ip_id = 1n;
    await ips.connect(bob).activate_syndication(ip_id);

    const dep1 = 568n;
    const dep2 = 536n;

    await ips.connect(mike).deposit(ip_id, dep1);
    await ips.connect(mike).deposit(ip_id, dep2);
    await ips.connect(alice).deposit(ip_id, 10_000n);
    await ips.connect(owner).deposit(ip_id, price); // completes

    await ips.connect(mike).mint_asset(ip_id);

    const nft = assetNFT.connect(mike);
    const bal = await nft.balanceOf(await (await mike.getAddress()), ip_id);
    expect(bal).to.equal(dep1 + dep2);
  });
});
