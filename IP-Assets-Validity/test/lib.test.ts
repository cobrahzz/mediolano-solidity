import { expect } from "chai";
import { ethers } from "hardhat";

describe("VisibilityManagement", () => {
  it("set/get par (token, assetId, owner=msg.sender) et event", async () => {
    const [owner, alice, bob] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("VisibilityManagement");
    const c = await Factory.deploy();
    await c.waitForDeployment();

    const token = ethers.Wallet.createRandom().address; // adresse fictive
    const assetId = 42n;

    // défaut = 0
    expect(await c.getVisibility(token, assetId, alice.address)).to.eq(0);
    expect(await c.getVisibility(token, assetId, bob.address)).to.eq(0);

    // Alice -> 1
    await expect(c.connect(alice).setVisibility(token, assetId, 1))
      .to.emit(c, "VisibilityChanged")
      .withArgs(token, assetId, alice.address, 1);

    expect(await c.getVisibility(token, assetId, alice.address)).to.eq(1);
    expect(await c.getVisibility(token, assetId, bob.address)).to.eq(0);

    // Bob -> 0 (reste 0)
    await expect(c.connect(bob).setVisibility(token, assetId, 0))
      .to.emit(c, "VisibilityChanged")
      .withArgs(token, assetId, bob.address, 0);

    expect(await c.getVisibility(token, assetId, bob.address)).to.eq(0);

    // Alice remet 0
    await expect(c.connect(alice).setVisibility(token, assetId, 0))
      .to.emit(c, "VisibilityChanged")
      .withArgs(token, assetId, alice.address, 0);

    expect(await c.getVisibility(token, assetId, alice.address)).to.eq(0);
  });

  it("revert si status invalide (≠ 0/1)", async () => {
    const [_, alice] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("VisibilityManagement");
    const c = await Factory.deploy();
    await c.waitForDeployment();

    const token = ethers.Wallet.createRandom().address;
    const assetId = 1n;

    await expect(
      c.connect(alice).setVisibility(token, assetId, 2)
    ).to.be.revertedWith("Invalid visibility status");
  });

  it("les assetIds sont indépendants", async () => {
    const [_, alice] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("VisibilityManagement");
    const c = await Factory.deploy();
    await c.waitForDeployment();

    const token = ethers.Wallet.createRandom().address;
    const id1 = 100n;
    const id2 = 101n;

    await c.connect(alice).setVisibility(token, id1, 1);
    expect(await c.getVisibility(token, id1, alice.address)).to.eq(1);
    expect(await c.getVisibility(token, id2, alice.address)).to.eq(0);
  });
});
