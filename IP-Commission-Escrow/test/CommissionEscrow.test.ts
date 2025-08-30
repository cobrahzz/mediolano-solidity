import { expect } from "chai";
import { ethers } from "hardhat";

const b32 = (s: string) => ethers.encodeBytes32String(s);
const E18 = 18;
const toUnit = (v: string) => ethers.parseUnits(v, E18);

async function deployToken() {
  const MockToken = await ethers.getContractFactory("MockToken");
  const token = await MockToken.deploy("MockToken", "MKT", 18);
  await token.waitForDeployment();
  return token;
}

async function deployEscrow(tokenAddr: string) {
  const Escrow = await ethers.getContractFactory("IPCommissionEscrow");
  const escrow = await Escrow.deploy(tokenAddr);
  await escrow.waitForDeployment();
  return escrow;
}

describe("IPCommissionEscrow", () => {
  it("create_order", async () => {
    const [creator, supplier] = await ethers.getSigners();
    const token = await deployToken();
    const escrow = await deployEscrow(await token.getAddress());

    const amount = toUnit("100");
    await (await escrow
      .connect(creator)
      .create_order(amount, await supplier.getAddress(), "ipfs_hash", "MIT")).wait();

    const orderId = await escrow.order_count();
    const details = await escrow.get_order_details(orderId);
    const [orderCreator, orderSupplier, orderAmount, orderState, art, lic] = details;

    expect(orderCreator).to.equal(await creator.getAddress());
    expect(orderSupplier).to.equal(await supplier.getAddress());
    expect(orderAmount).to.equal(amount);
    expect(orderState).to.equal(b32("NotPaid"));
    expect(art).to.equal("ipfs_hash");
    expect(lic).to.equal("MIT");
  });

  it("pay_order", async () => {
    const [creator, supplier] = await ethers.getSigners();
    const token = await deployToken();
    const escrow = await deployEscrow(await token.getAddress());

    const initialSupply = toUnit("1000");
    const amount = toUnit("100");

    await (await token.connect(creator).mint(await creator.getAddress(), initialSupply)).wait();

    await (await escrow
      .connect(creator)
      .create_order(amount, await supplier.getAddress(), "ipfs_hash", "MIT")).wait();
    const orderId = await escrow.order_count();

    await (await token.connect(creator).approve(await escrow.getAddress(), amount)).wait();
    await (await escrow.connect(creator).pay_order(orderId)).wait();

    const [, , orderAmount, orderState, art, lic] = await escrow.get_order_details(orderId);
    expect(orderAmount).to.equal(amount);
    expect(orderState).to.equal(b32("Paid"));
    expect(art).to.equal("ipfs_hash");
    expect(lic).to.equal("MIT");
  });

  it("complete_order", async () => {
    const [creator, supplier] = await ethers.getSigners();
    const token = await deployToken();
    const escrow = await deployEscrow(await token.getAddress());

    const initialSupply = toUnit("1000");
    const amount = toUnit("100");

    await (await token.connect(creator).mint(await creator.getAddress(), initialSupply)).wait();

    await (await escrow
      .connect(creator)
      .create_order(amount, await supplier.getAddress(), "ipfs_hash", "MIT")).wait();
    const orderId = await escrow.order_count();

    await (await token.connect(creator).approve(await escrow.getAddress(), amount)).wait();
    await (await escrow.connect(creator).pay_order(orderId)).wait();

    const balBefore = await token.balanceOf(await supplier.getAddress());
    await (await escrow.connect(creator).complete_order(orderId)).wait();
    const balAfter = await token.balanceOf(await supplier.getAddress());

    const [, , orderAmount, orderState] = await escrow.get_order_details(orderId);
    expect(orderAmount).to.equal(amount);
    expect(orderState).to.equal(b32("Completed"));
    expect(balAfter - balBefore).to.equal(amount);
  });

  it("cancel_order", async () => {
    const [creator, supplier] = await ethers.getSigners();
    const token = await deployToken();
    const escrow = await deployEscrow(await token.getAddress());

    const amount = toUnit("100");

    await (await escrow
      .connect(creator)
      .create_order(amount, await supplier.getAddress(), "ipfs_hash", "MIT")).wait();
    const orderId = await escrow.order_count();

    await (await escrow.connect(creator).cancel_order(orderId)).wait();

    const [, , orderAmount, orderState, art, lic] = await escrow.get_order_details(orderId);
    expect(orderAmount).to.equal(amount);
    expect(orderState).to.equal(b32("Cancelled"));
    expect(art).to.equal("ipfs_hash");
    expect(lic).to.equal("MIT");
  });
});
