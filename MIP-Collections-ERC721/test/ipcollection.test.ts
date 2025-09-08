// test/ipcollection.test.ts
import { expect } from "chai";
import { ethers } from "hardhat";

type Log = {
  topics: string[];
  data: string;
  address: string;
};

async function deployIPCollection() {
  const [owner, user1, user2, other] = await ethers.getSigners();
  const IPCollection = await ethers.getContractFactory("IPCollection");
  const ip = await IPCollection.deploy();
  await ip.waitForDeployment();
  const ipAddr = await ip.getAddress();
  return { ip, ipAddr, owner, user1, user2, other };
}

function findEvent<T extends string>(
  iface: any,
  receipt: any,
  name: T
): ReturnType<typeof iface.parseLog> | undefined {
  for (const log of receipt.logs as Log[]) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed?.name === name) return parsed;
    } catch {
      // ignore non-matching logs
    }
  }
  return undefined;
}

describe("IPCollection / IPNft", () => {
  it("create_collection", async () => {
    const { ip, owner } = await deployIPCollection();

    const tx = await ip.connect(owner).create_collection(
      "My Collection",
      "MC",
      "ipfs://QmMyCollection"
    );
    const rc = await tx.wait();
    const ev = findEvent(ip.interface, rc, "CollectionCreated");
    expect(ev, "CollectionCreated not found").to.be.ok;

    const collectionId: bigint = ev!.args.collection_id;
    expect(collectionId).to.eq(1n);

    const col = await ip.get_collection(collectionId);
    expect(col.name).to.eq("My Collection");
    expect(col.symbol).to.eq("MC");
    expect(col.baseURI).to.eq("ipfs://QmMyCollection");
    expect(col.owner).to.eq(await owner.getAddress());
    expect(col.isActive).to.eq(true);
  });

  it("create multiple collections", async () => {
    const { ip, owner } = await deployIPCollection();

    const rc1 = await (await ip.connect(owner).create_collection("Collection 1", "C1", "ipfs://Qm1")).wait();
    const ev1 = findEvent(ip.interface, rc1, "CollectionCreated");
    const id1: bigint = ev1!.args.collection_id;
    expect(id1).to.eq(1n);

    const rc2 = await (await ip.connect(owner).create_collection("Collection 2", "C2", "ipfs://Qm2")).wait();
    const ev2 = findEvent(ip.interface, rc2, "CollectionCreated");
    const id2: bigint = ev2!.args.collection_id;
    expect(id2).to.eq(2n);
  });

  it("mint token (by collection owner)", async () => {
    const { ip, owner, user1 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test Collection", "TST", "ipfs://QmCollectionBaseUri/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const tx = await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://QmCollectionBaseUri/0");
    const mintRc = await tx.wait();
    const ev = findEvent(ip.interface, mintRc, "TokenMinted");
    const tokenId: bigint = ev!.args.token_id;
    expect(tokenId).to.eq(0n);

    const tokenKey = `${id.toString()}:${tokenId.toString()}`;
    const token = await ip.get_token(tokenKey);
    expect(token.collectionId).to.eq(id);
    expect(token.tokenId).to.eq(tokenId);
    expect(token.owner).to.eq(await user1.getAddress());
    expect(token.metadataURI).to.eq("ipfs://QmCollectionBaseUri/0");
  });

  it("revert: mint not owner", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://base/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    await expect(
      ip.connect(user1).mint(id, await user2.getAddress(), "ipfs://base/0")
    ).to.be.revertedWith("only owner");
  });

  it("revert: mint to zero address", async () => {
    const { ip, owner } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://base/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    await expect(
      ip.connect(owner).mint(id, ethers.ZeroAddress, "ipfs://base/0")
    ).to.be.revertedWith("zero recipient");
  });

  it("batch mint tokens", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://QmCollectionBaseUri/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const recipients = [await user1.getAddress(), await user2.getAddress()];
    const uris = ["ipfs://QmCollectionBaseUri/0", "ipfs://QmCollectionBaseUri/1"];

    const tx = await ip.connect(owner).batch_mint(id, recipients, uris);
    const brc = await tx.wait();
    const bev = findEvent(ip.interface, brc, "TokenMintedBatch");
    const tokenIds: bigint[] = bev!.args.token_ids;

    expect(tokenIds.length).to.eq(2);
    expect(tokenIds[0]).to.eq(0n);
    expect(tokenIds[1]).to.eq(1n);

    const t0 = await ip.get_token(`${id}:${tokenIds[0]}`);
    const t1 = await ip.get_token(`${id}:${tokenIds[1]}`);
    expect(t0.owner).to.eq(recipients[0]);
    expect(t1.owner).to.eq(recipients[1]);
    expect(t0.metadataURI).to.eq("ipfs://QmCollectionBaseUri/0");
    expect(t1.metadataURI).to.eq("ipfs://QmCollectionBaseUri/1");
  });

  it("revert: batch mint empty recipients", async () => {
    const { ip, owner } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://base/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    await expect(
      ip.connect(owner).batch_mint(id, [], [])
    ).to.be.revertedWith("empty recipients");
  });

  it("revert: batch mint zero recipient", async () => {
    const { ip, owner } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://base/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    await expect(
      ip.connect(owner).batch_mint(id, [ethers.ZeroAddress], ["ipfs://base/0"])
    ).to.be.revertedWith("zero recipient");
  });

  it("burn token (by owner)", async () => {
    const { ip, owner, user1 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://base/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const mrc = await (await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://base/0")).wait();
    const tokenId: bigint = findEvent(ip.interface, mrc, "TokenMinted")!.args.token_id;

    const key = `${id}:${tokenId}`;
    await expect(ip.connect(user1).burn(key)).to.emit(ip, "TokenBurned");
  });

  it("revert: burn not token owner", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://base/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const mrc = await (await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://base/0")).wait();
    const tokenId: bigint = findEvent(ip.interface, mrc, "TokenMinted")!.args.token_id;

    await expect(
      ip.connect(user2).burn(`${id}:${tokenId}`)
    ).to.be.revertedWith("not token owner");
  });

  it("transfer_token success (requires prior approve to collection contract)", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    // mint to user1
    const mrc = await (await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://Qm/0")).wait();
    const tokenId: bigint = findEvent(ip.interface, mrc, "TokenMinted")!.args.token_id;

    // fetch IPNft address
    const col = await ip.get_collection(id);
    const ipNft = await ethers.getContractAt("IPNft", col.ipNft);

    // approve IPCollection for this token
    await ipNft.connect(user1).approve(await ip.getAddress(), tokenId);

    // perform transfer via IPCollection
    await expect(
      ip.connect(user1).transfer_token(await user1.getAddress(), await user2.getAddress(), `${id}:${tokenId}`)
    ).to.emit(ip, "TokenTransferred");

    // check new owner
    const token = await ip.get_token(`${id}:${tokenId}`);
    expect(token.owner).to.eq(await user2.getAddress());
  });

  it("revert: transfer_token not approved", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const mrc = await (await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://Qm/0")).wait();
    const tokenId: bigint = findEvent(ip.interface, mrc, "TokenMinted")!.args.token_id;

    await expect(
      ip.connect(user1).transfer_token(await user1.getAddress(), await user2.getAddress(), `${id}:${tokenId}`)
    ).to.be.revertedWith("contract not approved");
  });

  it("revert: transfer_token inactive/nonexistent collection", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const mrc = await (await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://Qm/0")).wait();
    const tokenId: bigint = findEvent(ip.interface, mrc, "TokenMinted")!.args.token_id;

    // use wrong collection id
    const wrong = (id + 1n).toString() + ":" + tokenId.toString();

    await expect(
      ip.connect(user1).transfer_token(await user1.getAddress(), await user2.getAddress(), wrong)
    ).to.be.revertedWith("collection inactive");
  });

  it("list_user_collections empty", async () => {
    const { ip, user2 } = await deployIPCollection();
    const cols: bigint[] = await ip.list_user_collections(await user2.getAddress());
    expect(cols.length).to.eq(0);
  });

  it("batch_transfer_tokens success", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    // batch mint two tokens to user1
    const recipients = [await user1.getAddress(), await user1.getAddress()];
    const uris = ["ipfs://Qm/0", "ipfs://Qm/1"];
    const brc = await (await ip.connect(owner).batch_mint(id, recipients, uris)).wait();
    const bev = findEvent(ip.interface, brc, "TokenMintedBatch");
    const tokenIds: bigint[] = bev!.args.token_ids;

    // approve both tokens to IPCollection
    const col = await ip.get_collection(id);
    const ipNft = await ethers.getContractAt("IPNft", col.ipNft);
    await ipNft.connect(user1).approve(await ip.getAddress(), tokenIds[0]);
    await ipNft.connect(user1).approve(await ip.getAddress(), tokenIds[1]);

    const keys = [`${id}:${tokenIds[0]}`, `${id}:${tokenIds[1]}`];

    await expect(
      ip.connect(user1).batch_transfer(await user1.getAddress(), await user2.getAddress(), keys)
    ).to.emit(ip, "TokenTransferredBatch");

    const t0 = await ip.get_token(keys[0]);
    const t1 = await ip.get_token(keys[1]);
    expect(t0.owner).to.eq(await user2.getAddress());
    expect(t1.owner).to.eq(await user2.getAddress());
  });

  it("revert: batch_transfer inactive collection", async () => {
    const { ip, owner, user1, user2 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const mrc = await (await ip.connect(owner).batch_mint(id, [await user1.getAddress()], ["ipfs://Qm/0"])).wait();
    const bev = findEvent(ip.interface, mrc, "TokenMintedBatch");
    const tokenId: bigint = bev!.args.token_ids[0];

    const wrong = `${id + 1n}:${tokenId}`;
    await expect(
      ip.connect(user1).batch_transfer(await user1.getAddress(), await user2.getAddress(), [wrong])
    ).to.be.revertedWith("collection inactive");
  });

  it("verification functions", async () => {
    const { ip, owner, user1 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    const mrc = await (await ip.connect(owner).mint(id, await user1.getAddress(), "ipfs://Qm/0")).wait();
    const tokenId: bigint = findEvent(ip.interface, mrc, "TokenMinted")!.args.token_id;

    expect(await ip.is_valid_collection(id)).to.eq(true);
    expect(await ip.is_collection_owner(id, await owner.getAddress())).to.eq(true);
    expect(await ip.is_valid_token(`${id}:${tokenId}`)).to.eq(true);
  });

  it("list_user_tokens_per_collection", async () => {
    const { ip, owner, user1 } = await deployIPCollection();

    const rc = await (await ip.connect(owner).create_collection("Test", "TST", "ipfs://Qm/")).wait();
    const id: bigint = findEvent(ip.interface, rc, "CollectionCreated")!.args.collection_id;

    await (await ip.connect(owner).batch_mint(
      id,
      [await user1.getAddress(), await user1.getAddress(), await user1.getAddress()],
      ["ipfs://Qm/0", "ipfs://Qm/1", "ipfs://Qm/2"]
    )).wait();

    const tokens: bigint[] = await ip.list_user_tokens_per_collection(id, await user1.getAddress());
    expect(tokens.length).to.eq(3);
    expect(tokens[0]).to.eq(0n);
    expect(tokens[1]).to.eq(1n);
    expect(tokens[2]).to.eq(2n);
  });
});
