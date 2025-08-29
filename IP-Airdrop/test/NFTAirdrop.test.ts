import { expect } from "chai";
import { ethers } from "hardhat";
import { MerkleTree } from "merkletreejs";
import keccak256 from "keccak256";

function leafFor(addr: string, amount: number): string {
  return ethers.keccak256(
    ethers.solidityPacked(["address", "uint256"], [addr, amount])
  );
}

function buildTree(entries: Array<[string, number]>) {
  const leaves = entries.map(([a, n]) => Buffer.from(leafFor(a, n).slice(2), "hex"));
  const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
  const root = "0x" + tree.getRoot().toString("hex");
  const getProofHex = (idx: number) => tree.getHexProof(leaves[idx]);
  return { tree, root, getProofHex };
}

describe("NFTAirdrop (full features)", () => {
  it("claim via Merkle proof (Alice 1, Bob 2, Charlie 3) → token IDs 1..6", async () => {
    const [owner, alice, bob, charlie] = await ethers.getSigners();
    const entries: Array<[string, number]> = [
      [alice.address, 1],
      [bob.address, 2],
      [charlie.address, 3],
    ];
    const { root, getProofHex } = buildTree(entries);

    const Factory = await ethers.getContractFactory("NFTAirdrop");
    const c = await Factory.deploy("MyNFT", "MNFT", "ipfs://base/", root, owner.address);
    await c.waitForDeployment();

    await expect(c.connect(alice).claim(getProofHex(0), 1)).to.emit(c, "Transfer");
    await expect(c.connect(bob).claim(getProofHex(1), 2)).to.emit(c, "Transfer");
    await expect(c.connect(charlie).claim(getProofHex(2), 3)).to.emit(c, "Transfer");

    expect(await c.ownerOf(1)).to.eq(alice.address);
    expect(await c.ownerOf(2)).to.eq(bob.address);
    expect(await c.ownerOf(3)).to.eq(bob.address);
    expect(await c.ownerOf(4)).to.eq(charlie.address);
    expect(await c.ownerOf(5)).to.eq(charlie.address);
    expect(await c.ownerOf(6)).to.eq(charlie.address);

    await expect(c.connect(alice).claim(getProofHex(0), 1))
      .to.be.revertedWith("Airdrop: deja reclame");

    await expect(c.connect(owner).claim(getProofHex(0), 1))
      .to.be.revertedWith("Airdrop: preuve invalide");

    await expect(c.connect(bob).claim([], 2))
      .to.be.revertedWith("Airdrop: preuve invalide");
  });

  it("owner whitelist + airdrop by batches, then balances reset to 0", async () => {
    const [owner, alice, bob, charlie] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("NFTAirdrop");
    const c = await Factory.deploy("MyNFT", "MNFT", "", ethers.ZeroHash, owner.address);
    await c.waitForDeployment();

    await expect(
      c.connect(alice).whitelist(alice.address, 1)
    ).to.be.revertedWithCustomError(c, "OwnableUnauthorizedAccount");

    await c.whitelist(alice.address, 1);
    await c.whitelist(bob.address, 2);
    await c.whitelist(charlie.address, 3);

    expect(await c.whitelistBalanceOf(alice.address)).to.eq(1);
    expect(await c.whitelistBalanceOf(bob.address)).to.eq(2);
    expect(await c.whitelistBalanceOf(charlie.address)).to.eq(3);

    await c.airdrop(0, 3);

    expect(await c.ownerOf(1)).to.eq(alice.address);
    expect(await c.ownerOf(2)).to.eq(bob.address);
    expect(await c.ownerOf(3)).to.eq(bob.address);
    expect(await c.ownerOf(4)).to.eq(charlie.address);
    expect(await c.ownerOf(5)).to.eq(charlie.address);
    expect(await c.ownerOf(6)).to.eq(charlie.address);

    expect(await c.whitelistBalanceOf(alice.address)).to.eq(0);
    expect(await c.whitelistBalanceOf(bob.address)).to.eq(0);
    expect(await c.whitelistBalanceOf(charlie.address)).to.eq(0);
  });

  it("claimsLocked bloque les claims si activé", async () => {
    const [owner, alice] = await ethers.getSigners();
    const entries: Array<[string, number]> = [[alice.address, 1]];
    const { root, getProofHex } = buildTree(entries);

    const Factory = await ethers.getContractFactory("NFTAirdrop");
    const c = await Factory.deploy("MyNFT", "MNFT", "", root, owner.address);
    await c.waitForDeployment();

    await c.setClaimsLocked(true);
    await expect(c.connect(alice).claim(getProofHex(0), 1))
      .to.be.revertedWith("CLAIMS_LOCKED");
  });
});
