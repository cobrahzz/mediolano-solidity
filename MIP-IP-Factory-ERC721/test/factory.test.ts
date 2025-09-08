import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("MIP (Solidity port)", () => {
  async function deployFixture() {
    const [owner, user1, user2] = await ethers.getSigners();
    const MIP = await ethers.getContractFactory("MIP");
    const mip = await MIP.deploy(owner.address);
    await mip.waitForDeployment();

    const address = await mip.getAddress();
    return { mip, address, owner, user1, user2 };
  }

  // Helpers (aliases façon "dispatchers" StarkNet)
  const erc721 = (mip: any) => mip;
  const erc721Metadata = (mip: any) => mip;
  const erc721Enumerable = (mip: any) => mip;
  const ownable = (mip: any) => mip;
  const counter = (mip: any) => mip;
  const imip = (mip: any) => mip;

  it("test_contract_deployment", async () => {
    const { mip, owner } = await loadFixture(deployFixture);

    // owner() set correctement
    expect(await ownable(mip).owner()).to.eq(owner.address);

    // counter starts at 0
    expect(await counter(mip).current()).to.eq(0n);

    // ERC721 metadata
    expect(await erc721Metadata(mip).name()).to.eq("MIP Protocol");
    expect(await erc721Metadata(mip).symbol()).to.eq("MIP");

    // total supply starts at 0
    expect(await erc721Enumerable(mip).total_supply()).to.eq(0n);
  });

  it("test_mint_item", async () => {
    const { mip, user1 } = await loadFixture(deployFixture);

    // Mint first token
    const tx = await imip(mip).mint_item(user1.address, "ipfs://QmTest123");
    const receipt = await tx.wait();
    // Return value is accessible via callStatic; simpler: query state after mint
    const tokenId = 1n;
    expect(await erc721(mip).owner_of(tokenId)).to.eq(user1.address);

    // Balance
    expect(await erc721(mip).balance_of(user1.address)).to.eq(1n);

    // Counter
    expect(await (mip as any).current()).to.eq(1n);

    // Total supply
    expect(await (mip as any).total_supply()).to.eq(1n);
  });

  it("test_mint_multiple_items", async () => {
    const { mip, user1, user2 } = await loadFixture(deployFixture);

    const id1 = 1n;
    const id2 = 2n;

    await imip(mip).mint_item(user1.address, "ipfs://QmTest1");
    await imip(mip).mint_item(user2.address, "ipfs://QmTest2");

    // Balances
    expect(await erc721(mip).balance_of(user1.address)).to.eq(1n);
    expect(await erc721(mip).balance_of(user2.address)).to.eq(1n);

    // Counter
    expect(await counter(mip).current()).to.eq(2n);

    // Total supply
    expect(await erc721Enumerable(mip).total_supply()).to.eq(2n);

    // Ownership
    expect(await erc721(mip).owner_of(id1)).to.eq(user1.address);
    expect(await erc721(mip).owner_of(id2)).to.eq(user2.address);
  });

  it("test_transfer_from", async () => {
    const { mip, user1, user2 } = await loadFixture(deployFixture);

    const tokenId = 1n;
    await imip(mip).mint_item(user1.address, "ipfs://QmTest");

    // Appeler transfer_from en tant que propriétaire actuel (user1)
    await (erc721(mip) as any)
      .connect(user1)
      .transfer_from(user1.address, user2.address, tokenId);

    // Nouvelle propriété
    expect(await erc721(mip).owner_of(tokenId)).to.eq(user2.address);

    // Balances
    expect(await erc721(mip).balance_of(user1.address)).to.eq(0n);
    expect(await erc721(mip).balance_of(user2.address)).to.eq(1n);
  });

  it("test_counter_operations", async () => {
    const { mip } = await loadFixture(deployFixture);

    // initial
    expect(await counter(mip).current()).to.eq(0n);

    // increment
    await counter(mip).increment();
    expect(await counter(mip).current()).to.eq(1n);

    // decrement
    await counter(mip).decrement();
    expect(await counter(mip).current()).to.eq(0n);
  });

  it("test_ownership_transfer", async () => {
    const { mip, owner, user1 } = await loadFixture(deployFixture);

    expect(await ownable(mip).owner()).to.eq(owner.address);

    // transfer_ownership appelé par l’owner
    await (ownable(mip) as any).connect(owner).transfer_ownership(user1.address);

    expect(await ownable(mip).owner()).to.eq(user1.address);
  });

  it("test_erc721_enumerable", async () => {
    const { mip, user1, user2 } = await loadFixture(deployFixture);

    await imip(mip).mint_item(user1.address, "ipfs://QmTest1"); // id 1
    await imip(mip).mint_item(user2.address, "ipfs://QmTest2"); // id 2
    await imip(mip).mint_item(user1.address, "ipfs://QmTest3"); // id 3

    // total supply
    expect(await (mip as any).total_supply()).to.eq(3n);

    // token by index (0->1, 1->2, 2->3)
    expect(await (mip as any).token_by_index(0)).to.eq(1n);
    expect(await (mip as any).token_by_index(1)).to.eq(2n);
    expect(await (mip as any).token_by_index(2)).to.eq(3n);

    // token of owner by index
    expect(await (mip as any).token_of_owner_by_index(user1.address, 0)).to.eq(1n);
    expect(await (mip as any).token_of_owner_by_index(user1.address, 1)).to.eq(3n);
    expect(await (mip as any).token_of_owner_by_index(user2.address, 0)).to.eq(2n);
  });
});
