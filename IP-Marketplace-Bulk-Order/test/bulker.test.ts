import { expect } from "chai";
import { ethers } from "hardhat";

describe("HelloStarknet", () => {
  it("increaseBalance(42) met à jour et lit bien la balance", async () => {
    const Hello = await ethers.getContractFactory("HelloStarknet");
    const hello = await Hello.deploy();
    await hello.waitForDeployment();

    const before = await hello.getBalance();
    expect(before).to.equal(0n);

    const tx = await hello.increaseBalance(42);
    await tx.wait();

    const after = await hello.getBalance();
    expect(after).to.equal(42n);
  });

  it("revert si increaseBalance(0)", async () => {
    const Hello = await ethers.getContractFactory("HelloStarknet");
    const hello = await Hello.deploy();
    await hello.waitForDeployment();

    await expect(hello.increaseBalance(0)).to.be.revertedWith("Amount cannot be 0");

    // la balance reste 0
    expect(await hello.getBalance()).to.equal(0n);
  });
});
