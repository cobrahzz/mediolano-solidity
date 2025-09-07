import { expect } from "chai";
import { ethers } from "hardhat";

function computeOrderId(tokenId: bigint, orderCount: bigint, creator: string): string {
  // keccak256(abi.encodePacked(tokenId, orderCount, creator))
  return ethers.solidityPackedKeccak256(
    ["uint256", "uint256", "address"],
    [tokenId, orderCount, creator]
  );
}

describe("IPNegotiationEscrow", () => {
  async function deployFixture() {
    const [seller, buyer, other] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("ERC20Mock");
    const token = await Token.deploy();
    await token.waitForDeployment();

    const Escrow = await ethers.getContractFactory("IPNegotiationEscrow");
    const escrow = await Escrow.deploy(await token.getAddress());
    await escrow.waitForDeployment();

    return { seller, buyer, other, token, escrow };
  }

  it("sanity: ERC20 interface/mint/approve works", async () => {
    const { buyer, token, escrow } = await deployFixture();

    await token.mint(buyer.address, 1_000n);
    expect(await token.balanceOf(buyer.address)).to.equal(1_000n);

    await token.connect(buyer).approve(await escrow.getAddress(), 500n);
    expect(await token.allowance(buyer.address, await escrow.getAddress())).to.equal(500n);
  });

  it("create_order: must be called by creator & emits OrderCreated with deterministic id", async () => {
    const { seller, buyer, escrow } = await deployFixture();
    const tokenId = 1n;
    const price = 100n;

    await expect(
      escrow.connect(buyer).create_order(seller.address, price, tokenId)
    ).to.be.revertedWith("Only creator can create order");

    const countBefore: bigint = await escrow.order_count();
    const expectedId = computeOrderId(tokenId, countBefore, seller.address);

    await expect(escrow.connect(seller).create_order(seller.address, price, tokenId))
      .to.emit(escrow, "OrderCreated")
      .withArgs(expectedId, seller.address, price, tokenId);

    const fromToken = await escrow.get_order_by_token_id(tokenId);
    expect(fromToken.id).to.equal(expectedId);

    const fetched = await escrow.get_order(expectedId);
    expect(fetched.creator).to.equal(seller.address);
    expect(fetched.price).to.equal(price);
    expect(fetched.token_id).to.equal(tokenId);
    expect(fetched.fulfilled).to.equal(false);
  });

  it("create_order: rejects when active order already exists for token", async () => {
    const { seller, escrow } = await deployFixture();
    const tokenId = 7n;
    const price = 50n;

    await escrow.connect(seller).create_order(seller.address, price, tokenId);

    await expect(
      escrow.connect(seller).create_order(seller.address, price, tokenId)
    ).to.be.revertedWith("Token already has active order");
  });

  it("deposit_funds: only non-creator; requires allowance; updates state & emits", async () => {
    const { seller, buyer, token, escrow } = await deployFixture();
    const tokenId = 21n;
    const price = 1_000n;

    await escrow.connect(seller).create_order(seller.address, price, tokenId);
    const order = await escrow.get_order_by_token_id(tokenId);

    await token.mint(buyer.address, price);
    // seller cannot deposit (creator)
    await expect(escrow.connect(seller).deposit_funds(order.id)).to.be.revertedWith(
      "Creator cannot buy own IP"
    );

    // without approve -> fail
    await expect(escrow.connect(buyer).deposit_funds(order.id)).to.be.revertedWith(
      "ERC20 transfer failed"
    );

    // approve then deposit
    await token.connect(buyer).approve(await escrow.getAddress(), price);
    await expect(escrow.connect(buyer).deposit_funds(order.id))
      .to.emit(escrow, "FundsDeposited")
      .withArgs(order.id, buyer.address, price);

    expect(await escrow.is_deposited(order.id)).to.equal(true);
    expect(await escrow.get_order_buyer(order.id)).to.equal(buyer.address);
    expect(await token.balanceOf(await escrow.getAddress())).to.equal(price);

    // double deposit blocked
    await expect(escrow.connect(buyer).deposit_funds(order.id)).to.be.revertedWith(
      "Already deposited"
    );
  });

  it("fulfill_order: only creator; requires deposit; pays seller; marks fulfilled; emits", async () => {
    const { seller, buyer, token, escrow } = await deployFixture();
    const tokenId = 99n;
    const price = 1_234n;

    await escrow.connect(seller).create_order(seller.address, price, tokenId);
    const order = await escrow.get_order_by_token_id(tokenId);

    // cannot fulfill without deposit
    await expect(escrow.connect(seller).fulfill_order(order.id)).to.be.revertedWith("No deposit");

    // prepare deposit
    await token.mint(buyer.address, price);
    await token.connect(buyer).approve(await escrow.getAddress(), price);
    await escrow.connect(buyer).deposit_funds(order.id);

    // non-creator cannot fulfill
    await expect(escrow.connect(buyer).fulfill_order(order.id)).to.be.revertedWith(
      "Only creator can fulfill order"
    );

    const sellerBefore = await token.balanceOf(seller.address);

    await expect(escrow.connect(seller).fulfill_order(order.id))
      .to.emit(escrow, "OrderFulfilled")
      .withArgs(order.id, seller.address, buyer.address, tokenId, price);

    const sellerAfter = await token.balanceOf(seller.address);
    expect(sellerAfter - sellerBefore).to.equal(price);

    const updated = await escrow.get_order(order.id);
    expect(updated.fulfilled).to.equal(true);
    // escrow balance back to 0 after paying seller
    expect(await token.balanceOf(await escrow.getAddress())).to.equal(0n);

    // cannot fulfill twice
    await expect(escrow.connect(seller).fulfill_order(order.id)).to.be.revertedWith(
      "Order already fulfilled"
    );
  });

  it("cancel_order: only creator; marks fulfilled; blocks further deposit", async () => {
    const { seller, buyer, token, escrow } = await deployFixture();
    const tokenId = 123n;
    const price = 777n;

    await escrow.connect(seller).create_order(seller.address, price, tokenId);
    const order = await escrow.get_order_by_token_id(tokenId);

    await expect(escrow.connect(buyer).cancel_order(order.id)).to.be.revertedWith(
      "Only creator can cancel order"
    );

    await expect(escrow.connect(seller).cancel_order(order.id))
      .to.emit(escrow, "OrderCancelled")
      .withArgs(order.id);

    const cancelled = await escrow.get_order(order.id);
    expect(cancelled.fulfilled).to.equal(true);

    // deposit now fails since "already fulfilled"
    await token.mint(buyer.address, price);
    await token.connect(buyer).approve(await escrow.getAddress(), price);
    await expect(escrow.connect(buyer).deposit_funds(order.id)).to.be.revertedWith(
      "Order already fulfilled"
    );
  });

  it("hash uniqueness (keccak): different (tokenId|creator|count) => different order ids", async () => {
    const { seller, other, escrow } = await deployFixture();

    const tokenId1 = 1n;
    const tokenId2 = 2n;
    const price = 1n;

    // order_count starts at 0
    const c0: bigint = await escrow.order_count();
    const e1 = computeOrderId(tokenId1, c0, seller.address);
    await escrow.connect(seller).create_order(seller.address, price, tokenId1);
    const o1 = await escrow.get_order_by_token_id(tokenId1);
    expect(o1.id).to.equal(e1);

    const c1: bigint = await escrow.order_count(); // now 1
    const e2 = computeOrderId(tokenId2, c1, seller.address);
    await escrow.connect(seller).create_order(seller.address, price, tokenId2);
    const o2 = await escrow.get_order_by_token_id(tokenId2);
    expect(o2.id).to.equal(e2);

    expect(o1.id).to.not.equal(o2.id);

    const c2: bigint = await escrow.order_count(); // now 2
    const e3 = computeOrderId(3n, c2, other.address);
    await escrow.connect(other).create_order(other.address, price, 3n);
    const o3 = await escrow.get_order_by_token_id(3n);
    expect(o3.id).to.equal(e3);

    expect(o3.id).to.not.equal(o2.id);
    expect(o3.id).to.not.equal(o1.id);
  });
});
