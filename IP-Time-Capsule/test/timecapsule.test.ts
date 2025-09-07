// test/timeCapsule.test.ts
import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

// Helpers
const b32 = (x: bigint | number | string) =>
  ethers.zeroPadValue(ethers.toBeHex(x), 32); // bytes32

describe("TimeCapsule", () => {
  async function deploy() {
    const [owner, user1, user2, receiver] = await ethers.getSigners();

    const TimeCapsule = await ethers.getContractFactory("TimeCapsule");
    const name = "IpTimelock";
    const symbol = "ITL";
    const baseURI = "ipfs://QmBaseUri";
    const tc = await TimeCapsule.deploy(name, symbol, baseURI, owner.address);
    await tc.waitForDeployment();

    return { tc, owner, user1, user2, receiver };
  }

  it("mint + metadata hide/reveal", async () => {
    const { tc, owner, receiver } = await deploy();

    const now = await time.latest();
    const unvesting = BigInt(now) + 86_400n;
    const metadataHash = b32(0x123456789n);

    // mint (owner is msg.sender by default in tests)
    const tx = await tc.mint(receiver.address, metadataHash, Number(unvesting));
    const receipt = await tx.wait();
    const tokenId = receipt?.logs?.[0] ? await tc.totalSupply() : 1n; // safe fallback

    expect(tokenId).to.equal(1n);

    // before unvesting → hidden
    expect(await tc.getMetadata(1)).to.equal(ethers.ZeroHash);

    // after unvesting → revealed
    await time.increaseTo(unvesting + 1n);
    expect(await tc.getMetadata(1)).to.equal(metadataHash);
  });

  it("set_metadata BEFORE unvesting should revert", async () => {
    const { tc, owner, receiver } = await deploy();

    const now = await time.latest();
    const unvesting = BigInt(now) + 86_400n;
    const metadataHash = b32(0x123456789n);
    const newHash = b32(0x723459358n);

    await tc.connect(owner).mint(receiver.address, metadataHash, Number(unvesting));
    await expect(
      tc.connect(receiver).setMetadata(1, newHash)
    ).to.be.revertedWith("Not yet unvested");
  });

  it("set_metadata AFTER unvesting (by token owner)", async () => {
    const { tc, owner, receiver } = await deploy();

    const now = await time.latest();
    const unvesting = BigInt(now) + 86_400n;
    const metadataHash = b32(0x123456789n);
    const newHash = b32(0x723459358n);

    await tc.connect(owner).mint(receiver.address, metadataHash, Number(unvesting));

    await time.increaseTo(unvesting + 1n);
    await tc.connect(receiver).setMetadata(1, newHash);

    expect(await tc.getMetadata(1)).to.equal(newHash);
  });

  it("list_user_tokens (multi-users, ordering)", async () => {
    const { tc, owner, user2, receiver } = await deploy();

    const now = await time.latest();
    const base = BigInt(now) + 86_400n;

    // initially empty for receiver
    expect(await tc.listUserTokens(receiver.address)).to.deep.equal([]);

    // mint 3 to receiver
    const t1 = await tc.mint(receiver.address, b32(0x123456789n), Number(base));
    const t2 = await tc.mint(receiver.address, b32(0x12345678an), Number(base + 100n));
    const t3 = await tc.mint(receiver.address, b32(0x12345678bn), Number(base + 200n));
    await t1.wait(); await t2.wait(); await t3.wait();

    // mint 1 to user2
    await (await tc.mint(user2.address, b32(0x12345678cn), Number(base + 300n))).wait();

    const rTokens = await tc.listUserTokens(receiver.address);
    expect(rTokens.map(BigInt)).to.deep.equal([1n, 2n, 3n]);

    const u2Tokens = await tc.listUserTokens(user2.address);
    expect(u2Tokens.map(BigInt)).to.deep.equal([4n]);

    // non-existent owner
    const noTokens = await tc.listUserTokens("0x0000000000000000000000000000000000000999");
    expect(noTokens).to.deep.equal([]);
  });

  it("list_user_tokens edge cases (single → multiple, preserve order)", async () => {
    const { tc, owner, receiver } = await deploy();

    const now = await time.latest();
    const base = BigInt(now) + 86_400n;

    // single
    await (await tc.mint(receiver.address, b32(0x123456789n), Number(base))).wait();
    let tokens = await tc.listUserTokens(receiver.address);
    expect(tokens.map(BigInt)).to.deep.equal([1n]);

    // add two more
    await (await tc.mint(receiver.address, b32(0x12345678an), Number(base + 100n))).wait();
    await (await tc.mint(receiver.address, b32(0x12345678bn), Number(base + 200n))).wait();

    tokens = await tc.listUserTokens(receiver.address);
    expect(tokens.map(BigInt)).to.deep.equal([1n, 2n, 3n]);
  });
});
