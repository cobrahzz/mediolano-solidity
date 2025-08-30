import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const TOKEN_ID = 1n;
const AMOUNT = 100n;
const LEASE_FEE = 10n;
const DURATION = 86400; // 1 day
const TERMS = "ipfs://QmLicenseTerms";

async function deploy() {
  const [owner, user1, user2, extra] = await ethers.getSigners();
  const IPLeasing = await ethers.getContractFactory("IPLeasing", owner);
  const leasing = await IPLeasing.deploy(owner.address, "ipfs://QmBaseUri");
  await leasing.waitForDeployment();
  return { leasing, owner, user1, user2, extra };
}

async function setupOffer(leasing: any, owner: any) {
  await leasing.connect(owner).mint_ip(owner.address, TOKEN_ID, AMOUNT);
  await leasing.connect(owner).create_lease_offer(TOKEN_ID, AMOUNT, LEASE_FEE, DURATION, TERMS);
}

describe("IPLeasing – full suite", () => {
  // ------------------------
  // Reverts (traduction 1:1)
  // ------------------------
  it("cancel_lease_offer: No active offer", async () => {
    const { leasing, owner } = await deploy();
    await expect(leasing.connect(owner).cancel_lease_offer(TOKEN_ID))
      .to.be.revertedWith("No active offer");
  });

  it("start_lease: No active offer", async () => {
    const { leasing, user1 } = await deploy();
    await expect(leasing.connect(user1).start_lease(TOKEN_ID))
      .to.be.revertedWith("No active offer");
  });

  it("mint_ip: onlyOwner", async () => {
    const { leasing, user1 } = await deploy();
    await expect(
      leasing.connect(user1).mint_ip(await leasing.getAddress(), TOKEN_ID, AMOUNT)
    )
      .to.be.revertedWithCustomError(leasing, "OwnableUnauthorizedAccount")
      .withArgs(user1.address);
  });

  it("create_lease_offer: Not token owner", async () => {
    const { leasing, user1 } = await deploy();
    await expect(
      leasing.connect(user1).create_lease_offer(TOKEN_ID, AMOUNT, LEASE_FEE, DURATION, TERMS)
    ).to.be.revertedWith("Not token owner");
  });

  it("renew_lease: No active lease", async () => {
    const { leasing, user1 } = await deploy();
    await expect(leasing.connect(user1).renew_lease(TOKEN_ID, DURATION))
      .to.be.revertedWith("No active lease");
  });

  // ------------------------
  // Offers (create / cancel)
  // ------------------------
  it("create_lease_offer success (escrow owner -> contract)", async () => {
    const { leasing, owner } = await deploy();

    await leasing.connect(owner).mint_ip(owner.address, TOKEN_ID, AMOUNT);
    expect(await leasing.balanceOf(owner.address, TOKEN_ID)).to.eq(AMOUNT);

    await expect(
      leasing.connect(owner).create_lease_offer(TOKEN_ID, AMOUNT, LEASE_FEE, DURATION, TERMS)
    ).to.emit(leasing, "LeaseOfferCreated");

    const leasingAddr = await leasing.getAddress();
    expect(await leasing.balanceOf(owner.address, TOKEN_ID)).to.eq(0);
    expect(await leasing.balanceOf(leasingAddr, TOKEN_ID)).to.eq(AMOUNT);

    const offer = await leasing.get_lease_offer(TOKEN_ID);
    expect(offer.owner).to.eq(owner.address);
    expect(offer.amount).to.eq(AMOUNT);
    expect(offer.is_active).to.eq(true);
  });

  it("cancel_lease_offer success (escrow contract -> owner)", async () => {
    const { leasing, owner } = await deploy();
    await setupOffer(leasing, owner);

    await expect(leasing.connect(owner).cancel_lease_offer(TOKEN_ID))
      .to.emit(leasing, "LeaseOfferCancelled");

    const leasingAddr = await leasing.getAddress();
    expect(await leasing.balanceOf(leasingAddr, TOKEN_ID)).to.eq(0);
    expect(await leasing.balanceOf(owner.address, TOKEN_ID)).to.eq(AMOUNT);

    const offer = await leasing.get_lease_offer(TOKEN_ID);
    expect(offer.is_active).to.eq(false);
  });

  // ------------------------
  // Leases (start / renew / expire / terminate) + blocage transferts
  // ------------------------
  it("start_lease success (contract -> lessee, offer inactive)", async () => {
    const { leasing, owner, user1: lessee } = await deploy();
    await setupOffer(leasing, owner);

    const leasingAddr = await leasing.getAddress();

    await expect(leasing.connect(lessee).start_lease(TOKEN_ID))
      .to.emit(leasing, "LeaseStarted");

    expect(await leasing.balanceOf(leasingAddr, TOKEN_ID)).to.eq(0);
    expect(await leasing.balanceOf(lessee.address, TOKEN_ID)).to.eq(AMOUNT);

    const lease = await leasing.get_lease(TOKEN_ID);
    expect(lease.lessee).to.eq(lessee.address);
    expect(lease.is_active).to.eq(true);

    const offer = await leasing.get_lease_offer(TOKEN_ID);
    expect(offer.is_active).to.eq(false);
  });

  it("blocks transfer of leased token (lessee -> other)", async () => {
    const { leasing, owner, user1: lessee, user2: other } = await deploy();
    await setupOffer(leasing, owner);
    await leasing.connect(lessee).start_lease(TOKEN_ID);

    await expect(
      leasing.connect(lessee).safeTransferFrom(lessee.address, other.address, TOKEN_ID, AMOUNT, "0x")
    ).to.be.revertedWith("Leased IP cannot be transferred");
  });

  it("renew_lease success (extends end_time)", async () => {
    const { leasing, owner, user1: lessee } = await deploy();
    await setupOffer(leasing, owner);
    await leasing.connect(lessee).start_lease(TOKEN_ID);

    const before = await leasing.get_lease(TOKEN_ID);
    await expect(leasing.connect(lessee).renew_lease(TOKEN_ID, 120)).to.emit(leasing, "LeaseRenewed");
    const after = await leasing.get_lease(TOKEN_ID);
    expect(after.end_time).to.equal(before.end_time + 120n);
  });

  it("expire_lease success (lessee -> owner)", async () => {
    const { leasing, owner, user1: lessee } = await deploy();
    await setupOffer(leasing, owner);
    await leasing.connect(lessee).start_lease(TOKEN_ID);

    const lease = await leasing.get_lease(TOKEN_ID);
    await time.increaseTo(Number(lease.end_time) + 1);

    await expect(leasing.connect(owner).expire_lease(TOKEN_ID)).to.emit(leasing, "LeaseExpired");

    const state = await leasing.get_lease(TOKEN_ID);
    expect(state.is_active).to.eq(false);
    expect(await leasing.balanceOf(owner.address, TOKEN_ID)).to.eq(AMOUNT);
  });

  it("terminate_lease success (owner only, lessee -> owner)", async () => {
    const { leasing, owner, user1: lessee } = await deploy();
    await setupOffer(leasing, owner);
    await leasing.connect(lessee).start_lease(TOKEN_ID);

    await expect(leasing.connect(owner).terminate_lease(TOKEN_ID, "breach"))
      .to.emit(leasing, "LeaseTerminated");

    const state = await leasing.get_lease(TOKEN_ID);
    expect(state.is_active).to.eq(false);
    expect(await leasing.balanceOf(owner.address, TOKEN_ID)).to.eq(AMOUNT);
  });

  // ------------------------
  // Views (indexation filtrée)
  // ------------------------
  it("active leases by owner / lessee reflect live state", async () => {
    const { leasing, owner, user1: lessee } = await deploy();

    await leasing.connect(owner).mint_ip(owner.address, TOKEN_ID, AMOUNT);
    await leasing.connect(owner).create_lease_offer(TOKEN_ID, AMOUNT, LEASE_FEE, DURATION, TERMS);

    expect(await leasing.get_active_leases_by_owner(owner.address)).to.deep.eq([]);
    expect(await leasing.get_active_leases_by_lessee(lessee.address)).to.deep.eq([]);

    await leasing.connect(lessee).start_lease(TOKEN_ID);

    expect(await leasing.get_active_leases_by_owner(owner.address)).to.deep.eq([TOKEN_ID]);
    expect(await leasing.get_active_leases_by_lessee(lessee.address)).to.deep.eq([TOKEN_ID]);

    const lease = await leasing.get_lease(TOKEN_ID);
    await time.increaseTo(Number(lease.end_time) + 1);
    await leasing.connect(owner).expire_lease(TOKEN_ID);

    expect(await leasing.get_active_leases_by_owner(owner.address)).to.deep.eq([]);
    expect(await leasing.get_active_leases_by_lessee(lessee.address)).to.deep.eq([]);
  });
});
