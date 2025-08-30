import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("CollectiveIPAgreement", () => {
  async function deploy() {
    const [owner, user1, user2, resolver, other] = await ethers.getSigners();
    const URI = "ipfs://QmBaseUri";

    const Factory = await ethers.getContractFactory("CollectiveIPAgreement", owner);
    const c = await Factory.deploy(owner.address, URI, resolver.address);

    return { c, owner, user1, user2, resolver, other, URI };
  }

  async function registerIP(
    c: any,
    owner: any,
    user1: any,
    user2: any,
    tokenId: bigint | number = 1n,
    royaltyRate = 100, // 10%
  ) {
    const metadataUri = "ipfs://QmTest";
    const owners = [user1.address, user2.address];
    const shares = [500, 500];
    const expiry = 1735689600; // number OK (uint64)
    const terms = "Standard";

    await c.connect(owner).register_ip(tokenId, metadataUri, owners, shares, royaltyRate, expiry, terms);
    return { tokenId, metadataUri, owners, shares, royaltyRate, expiry, terms };
  }

  it("register_ip (happy path)", async () => {
    const { c, owner, user1, user2 } = await deploy();
    const { tokenId, metadataUri, owners, shares, royaltyRate, expiry, terms } =
      await registerIP(c, owner, user1, user2);

    const ip = await c.get_ip_metadata(tokenId);
    expect(ip.metadata_uri).to.equal(metadataUri);
    expect(ip.owner_count).to.equal(2);
    expect(ip.royalty_rate).to.equal(royaltyRate);
    expect(ip.expiry_date).to.equal(expiry);
    expect(ip.license_terms).to.equal(terms);

    expect(await c.get_owner(tokenId, 0)).to.equal(owners[0]);
    expect(await c.get_owner(tokenId, 1)).to.equal(owners[1]);
    expect(await c.get_ownership_share(tokenId, owners[0])).to.equal(shares[0]);
    expect(await c.get_ownership_share(tokenId, owners[1])).to.equal(shares[1]);

    expect(await c.get_total_supply(tokenId)).to.equal(1000);
  });

  it("register_ip: revert if not owner", async () => {
    const { c, user1, user2 } = await deploy();
    await expect(
      c.connect(user1).register_ip(1, "ipfs://x", [user1.address, user2.address], [500, 500], 100, 1, "t")
    ).to.be.revertedWithCustomError(c, "OwnableUnauthorizedAccount").withArgs(user1.address);
  });

  it("register_ip: invalid metadata URI", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await expect(
      c.connect(owner).register_ip(1, "", [user1.address, user2.address], [500, 500], 100, 1, "t")
    ).to.be.revertedWith("Invalid metadata URI");
  });

  it("register_ip: mismatched owners/shares", async () => {
    const { c, owner, user1 } = await deploy();
    await expect(
      c.connect(owner).register_ip(1, "ipfs://x", [owner.address, user1.address], [500], 100, 1, "t")
    ).to.be.revertedWith("Mismatched owners and shares");
  });

  it("register_ip: no owners", async () => {
    const { c, owner } = await deploy();
    await expect(
      c.connect(owner).register_ip(1, "ipfs://x", [], [], 100, 1, "t")
    ).to.be.revertedWith("At least one owner required");
  });

  it("register_ip: royalty rate > 100%", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await expect(
      c.connect(owner).register_ip(1, "ipfs://x", [user1.address, user2.address], [500, 500], 1001, 1, "t")
    ).to.be.revertedWith("Royalty rate exceeds 100%");
  });

  it("register_ip: shares sum must be 1000", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await expect(
      c.connect(owner).register_ip(1, "ipfs://x", [user1.address, user2.address], [400, 400], 100, 1, "t")
    ).to.be.revertedWith("Shares must sum to 100%");
  });

  it("distribute_royalties (events pour chaque copropriétaire)", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await registerIP(c, owner, user1, user2, 1n, 100); // 10%

    const totalAmount = 1000n;
    const royaltyAmount = (totalAmount * 100n) / 1000n; // 100
    const perOwner = (royaltyAmount * 500n) / 1000n;    // 50 (parts 50/50)

    const tx = await c.connect(owner).distribute_royalties(1, totalAmount);
    await expect(tx).to.emit(c, "RoyaltyDistributed").withArgs(1, perOwner, user1.address);
    await expect(tx).to.emit(c, "RoyaltyDistributed").withArgs(1, perOwner, user2.address);
  });

  it("distribute_royalties: revert not owner", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await registerIP(c, owner, user1, user2);
    await expect(
      c.connect(user1).distribute_royalties(1, 1000)
    ).to.be.revertedWithCustomError(c, "OwnableUnauthorizedAccount").withArgs(user1.address);
  });

  it("distribute_royalties: revert no IP data", async () => {
    const { c, owner } = await deploy();
    await expect(
      c.connect(owner).distribute_royalties(1, 1000)
    ).to.be.revertedWith("No IP data found");
  });

  it("create_proposal (happy path) + deadline exact", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await registerIP(c, owner, user1, user2);

    const before = await time.latest();
    const tx = await c.connect(user1).create_proposal(1, "Update license terms");
    await tx.wait();

    const p = await c.get_proposal(1);
    expect(p.proposer).to.equal(user1.address);
    expect(p.description).to.equal("Update license terms");
    expect(p.vote_count).to.equal(0);
    expect(p.executed).to.equal(false);
    // p.deadline == block.timestamp(tx) + 7 days
    const block = await ethers.provider.getBlock(tx.blockNumber!);
    expect(p.deadline).to.equal(Number(block!.timestamp) + 7 * 24 * 60 * 60);
  });

  it("create_proposal: revert not owner of token", async () => {
    const { c, owner, other } = await deploy();
    await registerIP(c, owner, other, owner); // owners: other & owner
    await expect(
      c.connect(other).create_proposal(999, "no ip data")
    ).to.be.revertedWith("Not an owner"); // pas enregistré => owner_count=0 => revert
  });

  it("vote: revert not owner", async () => {
    const { c, owner, user1, user2, other } = await deploy();
    await registerIP(c, owner, user1, user2);
    await c.connect(user1).create_proposal(1, "desc");
    await expect(
      c.connect(other).vote(1, 1, true)
    ).to.be.revertedWith("Not an owner");
  });

  it("vote: revert already voted", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await registerIP(c, owner, user1, user2);
    await c.connect(user1).create_proposal(1, "desc");
    await c.connect(user1).vote(1, 1, true);
    await expect(
      c.connect(user1).vote(1, 1, true)
    ).to.be.revertedWith("Already voted");
  });

  it("execute_proposal: revert before deadline", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await registerIP(c, owner, user1, user2);
    await c.connect(user1).create_proposal(1, "desc");
    await c.connect(user1).vote(1, 1, true);
    await expect(c.execute_proposal(1, 1)).to.be.revertedWith("Voting period not ended");
  });

  it("execute_proposal: needs >50% votes", async () => {
    const { c, owner, user1, user2 } = await deploy();
    await registerIP(c, owner, user1, user2); // 50/50
    await c.connect(user1).create_proposal(1, "desc");
    await c.connect(user1).vote(1, 1, true); // 500
    // avancer le temps au-delà de la deadline
    const p = await c.get_proposal(1);
    await time.increaseTo(Number(p.deadline) + 1);
    await expect(c.execute_proposal(1, 1)).to.be.revertedWith("Insufficient votes");
  });

  it("execute_proposal: success when vote_count > 500", async () => {
    const { c, owner, user1, user2 } = await deploy();
    // parts 600/400 pour passer >50%
    const metadataUri = "ipfs://QmTest";
    const owners = [user1.address, user2.address];
    const shares = [600, 400];
    await c.connect(owner).register_ip(1, metadataUri, owners, shares, 100, 1, "t");

    await c.connect(user1).create_proposal(1, "desc"); // user1 a 600
    await c.connect(user1).vote(1, 1, true);
    const p = await c.get_proposal(1);
    await time.increaseTo(Number(p.deadline) + 1);

    await expect(c.execute_proposal(1, 1))
      .to.emit(c, "ProposalExecuted")
      .withArgs(1, true);
  });

  it("resolve_dispute: only dispute_resolver", async () => {
    const { c, owner, user1, user2, resolver } = await deploy();
    await registerIP(c, owner, user1, user2);
    await expect(
      c.connect(user1).resolve_dispute(1, "x")
    ).to.be.revertedWith("Not dispute resolver");

    await expect(
      c.connect(resolver).resolve_dispute(1, "Dispute resolved")
    ).to.emit(c, "DisputeResolved").withArgs(1, resolver.address, "Dispute resolved");
  });

  it("set_dispute_resolver: only owner, then new resolver can call", async () => {
    const { c, owner, user1, user2, other } = await deploy();
    await registerIP(c, owner, user1, user2);

    await expect(
      c.connect(user1).set_dispute_resolver(other.address)
    ).to.be.revertedWithCustomError(c, "OwnableUnauthorizedAccount").withArgs(user1.address);

    await c.connect(owner).set_dispute_resolver(other.address);
    await expect(
      c.connect(other).resolve_dispute(1, "ok")
    ).to.emit(c, "DisputeResolved").withArgs(1, other.address, "ok");
  });
});
