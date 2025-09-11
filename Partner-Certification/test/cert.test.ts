import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("HelloStarknet (Solidity port of StarkNet tests)", () => {
  async function deployFixture() {
    const C = await ethers.getContractFactory("HelloStarknet");
    // Si ton contrat a un constructor avec args, passe-les ici: C.deploy(arg1, arg2, ...)
    const c = await C.deploy();
    await c.waitForDeployment();
    return { c };
  }

  it("test_increase_balance", async () => {
    const { c } = await loadFixture(deployFixture);

    const before = await c.get_balance();
    expect(before).to.equal(0n, "Invalid balance");

    await c.increase_balance(42);

    const after = await c.get_balance();
    expect(after).to.equal(42n, "Invalid balance");
  });

  it("test_cannot_increase_balance_with_zero_value (safe dispatcher analogue)", async () => {
    const { c } = await loadFixture(deployFixture);

    const before = await c.get_balance();
    expect(before).to.equal(0n, "Invalid balance");

    // Version "safe dispatcher": on s'attend à un revert précis
    await expect(c.increase_balance(0)).to.be.revertedWith("Amount cannot be 0");
  });
});
