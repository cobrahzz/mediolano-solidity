import { expect } from "chai";
import { ethers } from "hardhat";

async function deploy() {
  const [deployer, owner, user1, user2, coCreator] = await ethers.getSigners();
  const IPCollection = await ethers.getContractFactory("IPCollection");
  const ip = await IPCollection.deploy(owner.address);
  await ip.waitForDeployment();
  return { ip, deployer, owner, user1, user2, coCreator };
}

async function now() {
  const b = await ethers.provider.getBlock("latest");
  return b!.timestamp;
}

async function setTime(t: number) {
  await ethers.provider.send("evm_setNextBlockTimestamp", [t]);
  await ethers.provider.send("evm_mine", []);
}

describe("IPCollection – full feature set (Solidity port)", function () {
  it("register type + read it", async () => {
    const { ip, owner } = await deploy();
    const tId = ethers.encodeBytes32String("ART");
    const deadline = (await now()) + 3600;

    await ip.connect(owner).registerContributionType(tId, 50, deadline, 2);
    const t = await ip.getContributionType(tId);
    expect(t.typeId).to.equal(tId);
    expect(t.minQualityScore).to.equal(50);
    expect(t.submissionDeadline).to.equal(deadline);
    expect(t.maxSupply).to.equal(2n);
  });

  it("submit -> verify -> mint (happy path)", async () => {
    const { ip, owner, user1 } = await deploy();
    const tId = ethers.encodeBytes32String("ART");
    const deadline = (await now()) + 3600;

    await ip.connect(owner).registerContributionType(tId, 50, deadline, 10);

    await ip.connect(user1).submitContribution("ipfs://x", "meta", tId);
    const id = await ip.getContributionsCount();

    await ip.connect(owner).verifyContribution(id, true, 80);
    await ip.connect(owner).mintNFT(id, user1.address);

    const c = await ip.getContribution(id);
    expect(c.minted).to.eq(true);
    expect(c.verified).to.eq(true);
  });

  it("verify: only verifiers + quality score threshold", async () => {
    const { ip, owner, user1, user2 } = await deploy();
    const tId = ethers.encodeBytes32String("PHOTO");
    const deadline = (await now()) + 3600;
    await ip.connect(owner).registerContributionType(tId, 60, deadline, 10);
    await ip.connect(user1).submitContribution("ipfs://y", "meta", tId);
    const id = await ip.getContributionsCount();

    await expect(ip.connect(user2).verifyContribution(id, true, 80)).to.be.revertedWith("Not authorized");
    await expect(ip.connect(owner).verifyContribution(id, true, 50)).to.be.revertedWith("Quality score too low");
    await ip.connect(owner).verifyContribution(id, true, 60); // ok
  });

  it("mint: must be verified and not minted", async () => {
    const { ip, owner, user1 } = await deploy();
    const tId = ethers.encodeBytes32String("MUSIC");
    const deadline = (await now()) + 3600;
    await ip.connect(owner).registerContributionType(tId, 10, deadline, 10);
    await ip.connect(user1).submitContribution("ipfs://z", "meta", tId);
    const id = await ip.getContributionsCount();

    await expect(ip.connect(owner).mintNFT(id, user1.address)).to.be.revertedWith("Not verified");
    await ip.connect(owner).verifyContribution(id, true, 10);
    await ip.connect(owner).mintNFT(id, user1.address);
    await expect(ip.connect(owner).mintNFT(id, user1.address)).to.be.revertedWith("Already minted");
  });

  it("batch submit + event + contributor list", async () => {
    const { ip, owner, user1 } = await deploy();
    const tId = ethers.encodeBytes32String("BATCH");
    const deadline = (await now()) + 3600;
    await ip.connect(owner).registerContributionType(tId, 1, deadline, 10);

    const assets = ["ipfs://a", "ipfs://b", "ipfs://c"];
    const metas = ["m1", "m2", "m3"];
    const types = [tId, tId, tId];

    await expect(ip.connect(user1).batchSubmitContributions(assets, metas, types))
      .to.emit(ip, "BatchSubmitted")
      .withArgs(assets.length, user1.address);

    const list = await ip.getContributorContributions(user1.address);
    expect(list.length).to.eq(3);
  });

  it("batch submit: length mismatch", async () => {
    const { ip, owner, user1 } = await deploy();
    const tId = ethers.encodeBytes32String("LEN");
    const deadline = (await now()) + 3600;
    await ip.connect(owner).registerContributionType(tId, 1, deadline, 10);

    await expect(
      ip.connect(user1).batchSubmitContributions(["a", "b"], ["m1"], [tId, tId])
    ).to.be.revertedWith("Length mismatch");
  });

  it("deadline + max supply checks", async () => {
    const { ip, owner, user1 } = await deploy();
    const tId = ethers.encodeBytes32String("TIME");
    const start = await now();
    await ip.connect(owner).registerContributionType(tId, 1, start + 10, 1);

    await ip.connect(user1).submitContribution("ipfs://1", "m", tId); // ok
    await expect(ip.connect(user1).submitContribution("ipfs://2", "m", tId)).to.be.revertedWith("Max supply reached");

    await setTime(start + 11);
    await expect(ip.connect(user1).submitContribution("ipfs://late", "m", tId)).to.be.revertedWith("Deadline passed");
  });

  it("marketplace listing / price / unlist", async () => {
    const { ip, owner, user1 } = await deploy();
    const tId = ethers.encodeBytes32String("MKT");
    const deadline = (await now()) + 3600;
    await ip.connect(owner).registerContributionType(tId, 1, deadline, 10);
    await ip.connect(user1).submitContribution("ipfs://m", "meta", tId);
    const id = await ip.getContributionsCount();
    await ip.connect(owner).verifyContribution(id, true, 10);
    await ip.connect(owner).mintNFT(id, user1.address);

    await ip.connect(user1).listContribution(id, 1234);
    let c = await ip.getContribution(id);
    expect(c.listed).to.eq(true);
    expect(c.price).to.eq(1234);

    await ip.connect(user1).updatePrice(id, 5555);
    c = await ip.getContribution(id);
    expect(c.price).to.eq(5555);

    await ip.connect(user1).unlistContribution(id);
    c = await ip.getContribution(id);
    expect(c.listed).to.eq(false);
    expect(c.price).to.eq(0);
  });

  it("co-creator + can list, and validations", async () => {
    const { ip, owner, user1, coCreator } = await deploy();
    const tId = ethers.encodeBytes32String("CO");
    const deadline = (await now()) + 3600;
    await ip.connect(owner).registerContributionType(tId, 1, deadline, 10);
    await ip.connect(user1).submitContribution("ipfs://c", "meta", tId);
    const id = await ip.getContributionsCount();
    await ip.connect(owner).verifyContribution(id, true, 10);
    await ip.connect(owner).mintNFT(id, user1.address);

    await expect(ip.connect(user1).addCoCreator(id, coCreator.address, 150)).to.be.revertedWith("Invalid royalty");
    await ip.connect(user1).addCoCreator(id, coCreator.address, 20);
    await expect(ip.connect(user1).addCoCreator(id, coCreator.address, 10)).to.be.revertedWith("Co-creator exists");

    await ip.connect(coCreator).listContribution(id, 999); // co-créateur autorisé
    const c = await ip.getContribution(id);
    expect(c.listed).to.eq(true);
    expect(c.price).to.eq(999);
  });

  it("owner can add/remove verifiers", async () => {
    const { ip, owner, user2 } = await deploy();
    await expect(ip.connect(user2).addVerifier(user2.address)).to.be.revertedWith("Only owner");

    await ip.connect(owner).addVerifier(user2.address);
    expect(await ip.isVerifier(user2.address)).to.eq(true);

    await ip.connect(owner).removeVerifier(user2.address);
    expect(await ip.isVerifier(user2.address)).to.eq(false);
  });
});
