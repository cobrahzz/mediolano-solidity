import { expect } from "chai";
import { ethers } from "hardhat";

async function deployIPCollection() {
  const [deployer, owner, user1, user2] = await ethers.getSigners();
  const IPCollection = await ethers.getContractFactory("IPCollection", deployer);
  const ip = await IPCollection.deploy(
    "IP Collection",
    "IPC",
    "ipfs://QmBaseUri",
    owner.address
  );
  await ip.waitForDeployment();
  return { ip, owner, user1, user2 };
}

describe("IPCollection", () => {
  it("create_collection + get_collection + list_user_collections", async () => {
    const { ip, owner } = await deployIPCollection();
    const colId = await ip.connect(owner).create_collection.staticCall("My", "MC", "ipfs://Base/");
    await (await ip.connect(owner).create_collection("My", "MC", "ipfs://Base/")).wait();

    expect(colId).to.equal(1n);
    const col = await ip.get_collection(colId);
    expect(col.name).to.equal("My");
    expect(col.symbol).to.equal("MC");
    expect(col.base_uri).to.equal("ipfs://Base/");
    expect(col.owner).to.equal(owner.address);
    expect(col.is_active).to.equal(true);

    const myCols: bigint[] = await ip.list_user_collections(owner.address);
    expect(myCols.length).to.equal(1);
    expect(myCols[0]).to.equal(colId);
  });

  it("mint -> get_token -> list_user_tokens", async () => {
    const { ip, owner, user1 } = await deployIPCollection();

    const colId = await ip.connect(owner).create_collection.staticCall("T", "T", "ipfs://Qm/");
    await (await ip.connect(owner).create_collection("T", "T", "ipfs://Qm/")).wait();

    const nextId = await ip.connect(owner).mint.staticCall(colId, user1.address);
    await (await ip.connect(owner).mint(colId, user1.address)).wait();
    expect(nextId).to.equal(1n);

    const token = await ip.get_token(nextId);
    expect(token.collection_id).to.equal(colId);
    expect(token.token_id).to.equal(nextId);
    expect(token.owner).to.equal(user1.address);
    expect(token.metadata_uri).to.equal("ipfs://Qm/1.json");

    const userTokens: bigint[] = await ip.list_user_tokens(user1.address);
    expect(userTokens.length).to.equal(1);
    expect(userTokens[0]).to.equal(nextId);
  });

  it("mint: only owner", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();
    const colId = await ip.connect(owner).create_collection.staticCall("T", "T", "ipfs://B/");
    await (await ip.connect(owner).create_collection("T", "T", "ipfs://B/")).wait();

    await expect(ip.connect(user1).mint(colId, user2.address))
      .to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("mint: zero address", async () => {
    const { ip, owner } = await deployIPCollection();
    const colId = await ip.connect(owner).create_collection.staticCall("T", "T", "ipfs://B/");
    await (await ip.connect(owner).create_collection("T", "T", "ipfs://B/")).wait();

    await expect(ip.connect(owner).mint(colId, ethers.ZeroAddress))
      .to.be.revertedWith("Recipient is zero address");
  });

  it("burn: not owner nor approved", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();
    const colId = await ip.connect(owner).create_collection.staticCall("T", "T", "ipfs://B/");
    await (await ip.connect(owner).create_collection("T", "T", "ipfs://B/")).wait();

    const tid = await ip.connect(owner).mint.staticCall(colId, user1.address);
    await (await ip.connect(owner).mint(colId, user1.address)).wait();

    await expect(ip.connect(user2).burn(tid))
      .to.be.revertedWith("ERC721: caller is not token owner or approved");
  });

  it("transfer_token: requires approval to contract", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();
    const colId = await ip.connect(owner).create_collection.staticCall("T", "T", "ipfs://B/");
    await (await ip.connect(owner).create_collection("T", "T", "ipfs://B/")).wait();

    const tid = await ip.connect(owner).mint.staticCall(colId, user1.address);
    await (await ip.connect(owner).mint(colId, user1.address)).wait();

    await expect(ip.connect(user1).transfer_token(user1.address, user2.address, tid))
      .to.be.revertedWith("Contract not approved");
  });

  it("list_all_tokens + list_collection_tokens", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const ca = await ip.connect(owner).create_collection.staticCall("A", "A", "ipfs://A/");
    await (await ip.connect(owner).create_collection("A", "A", "ipfs://A/")).wait();

    const cb = await ip.connect(owner).create_collection.staticCall("B", "B", "ipfs://B/");
    await (await ip.connect(owner).create_collection("B", "B", "ipfs://B/")).wait();

    const t1 = await ip.connect(owner).mint.staticCall(ca, user1.address);
    await (await ip.connect(owner).mint(ca, user1.address)).wait();

    const t2 = await ip.connect(owner).mint.staticCall(ca, user2.address);
    await (await ip.connect(owner).mint(ca, user2.address)).wait();

    const t3 = await ip.connect(owner).mint.staticCall(cb, user1.address);
    await (await ip.connect(owner).mint(cb, user1.address)).wait();

    const all: bigint[] = await ip.list_all_tokens();
    expect(all).to.deep.equal([t1, t2, t3]);

    const caTokens: bigint[] = await ip.list_collection_tokens(ca);
    expect(caTokens).to.deep.equal([t1, t2]);

    const cbTokens: bigint[] = await ip.list_collection_tokens(cb);
    expect(cbTokens).to.deep.equal([t3]);

    const none: bigint[] = await ip.list_collection_tokens(999n);
    expect(none.length).to.equal(0);
  });
});
