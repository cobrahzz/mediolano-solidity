// tests/ipcrowdfunding.test.js
// ESM + Hardhat >=2.26
import { expect } from "chai";
import hre from "hardhat";
const { ethers, network } = hre;

// --- helpers temps (toujours avancer, jamais revenir en arrière) ---
async function nextBlockAt(ts) {
  await network.provider.send("evm_setNextBlockTimestamp", [Math.floor(ts)]);
  await network.provider.send("evm_mine");
}
async function nowOnChain() {
  return (await ethers.provider.getBlock("latest")).timestamp;
}

describe("IPCrowdfunding — parité avec Cairo", function () {
  let owner, alice, bob, token, ipc;

  beforeEach(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory("MockERC20");
    token = await Mock.deploy();
    await token.waitForDeployment();

    const IPC = await ethers.getContractFactory("IPCrowdfunding");
    ipc = await IPC.deploy(owner.address, await token.getAddress());
    await ipc.waitForDeployment();

    // Campagne de base (id=1)
    await ipc.connect(owner).create_campaign("C1", "D1", 1000n, 3600);
  });

  it("create_campaign sets fields like in Cairo test", async () => {
    const c = await ipc.get_campaign(1);
    expect(c.title).to.equal("C1");
    expect(c.description).to.equal("D1");
    expect(c.goalAmount).to.equal(1000n);
    expect(c.creator).to.equal(owner.address);
    expect(Number(c.endTime)).to.equal(Number(c.startTime) + 3600);
  });

  it("contribute enregistre la contribution et augmente raisedAmount", async () => {
    await token.mint(alice.address, 1234n);
    await token.connect(alice).approve(await ipc.getAddress(), 1234n);

    await expect(ipc.connect(alice).contribute(1, 1234n))
      .to.emit(ipc, "ContributionMade").withArgs(1n, alice.address, 1234n);

    const c = await ipc.get_campaign(1);
    expect(c.raisedAmount).to.equal(1234n);

    const list = await ipc.get_contributions(1);
    expect(list.length).to.equal(1);
    expect(list[0].contributor).to.equal(alice.address);
    expect(list[0].amount).to.equal(1234n);
  });

  it("withdraw_funds seulement par le creator après goal atteint", async () => {
    await token.mint(alice.address, 700n);
    await token.mint(bob.address, 400n);
    await token.connect(alice).approve(await ipc.getAddress(), 700n);
    await token.connect(bob).approve(await ipc.getAddress(), 400n);

    await ipc.connect(alice).contribute(1, 700n);
    await ipc.connect(bob).contribute(1, 400n);

    const before = await token.balanceOf(owner.address);
    await expect(ipc.connect(owner).withdraw_funds(1))
      .to.emit(ipc, "FundsWithdrawn").withArgs(1n);
    const after = await token.balanceOf(owner.address);
    expect(after - before).to.equal(1100n);

    const c = await ipc.get_campaign(1);
    expect(c.completed).to.equal(true);
  });

  it("refund_contributions si goal non atteint et fin dépassée", async () => {
    // Nouvelle campagne courte (id=2) basée sur le temps chaîne
    const t0 = (await nowOnChain()) + 1;
    await nextBlockAt(t0);
    await ipc.connect(owner).create_campaign("C2", "D2", 1000n, 100); // end = t0+100

    await token.mint(alice.address, 300n);
    await token.connect(alice).approve(await ipc.getAddress(), 300n);
    await ipc.connect(alice).contribute(2, 300n);

    await nextBlockAt(t0 + 101); // dépasse fin

    const balBefore = await token.balanceOf(alice.address);
    await ipc.refund_contributions(2);
    const balAfter = await token.balanceOf(alice.address);
    expect(balAfter - balBefore).to.equal(300n);

    const c = await ipc.get_campaign(2);
    expect(c.refunded).to.equal(true);
  });

  it("reverts alignés avec les asserts Cairo", async () => {
    // a) Withdraw avant goal
    await expect(ipc.connect(owner).withdraw_funds(1))
      .to.be.revertedWith("Goal not reached");

    // b) Contribution après fin
    const c1 = await ipc.get_campaign(1);
    await nextBlockAt(Number(c1.endTime) + 1);
    await token.mint(alice.address, 10n);
    await token.connect(alice).approve(await ipc.getAddress(), 10n);
    await expect(ipc.connect(alice).contribute(1, 10n))
      .to.be.revertedWith("Campaign ended");

    // c) Not the creator : nouvelle campagne (pas de retour arrière)
    const t1 = (await nowOnChain()) + 1;
    await nextBlockAt(t1);
    await ipc.connect(owner).create_campaign("C3", "D3", 1000n, 3600); // id=2

    await token.mint(alice.address, 1000n);
    await token.connect(alice).approve(await ipc.getAddress(), 1000n);
    await ipc.connect(alice).contribute(2, 1000n); // atteint le goal

    await expect(ipc.connect(bob).withdraw_funds(2))
      .to.be.revertedWith("Not the creator");
  });
});
