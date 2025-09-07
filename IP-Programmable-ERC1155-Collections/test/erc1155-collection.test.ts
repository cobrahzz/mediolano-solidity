import { expect } from "chai";
import { ethers } from "hardhat";

const IMPL_FQN   = "src/ERC1155Collections.sol:ERC1155Collection";
const IMPLV2_FQN = "src/ERC1155Collections.sol:ERC1155CollectionV2";
const FACT_FQN   = "src/ERC1155Collections.sol:ERC1155CollectionsFactory";

describe("ERC1155 Collections (Factory + UUPS upgrade + V2 batch_mint)", () => {
  const BASE_URI = "ipfs://base";
  const TOKEN_ID  = 1n;
  const TOKEN_ID2 = 2n;
  const VAL1 = 10n;
  const VAL2 = 7n;

  async function deployFactoryWithImpl() {
    const [deployer] = await ethers.getSigners();

    const Impl = await ethers.getContractFactory(IMPL_FQN);
    const impl = await Impl.deploy();
    await impl.waitForDeployment();

    const Factory = await ethers.getContractFactory(FACT_FQN);
    const factory = await Factory.deploy(deployer.address, await impl.getAddress());
    await factory.waitForDeployment();

    return { deployer, impl, factory };
  }

  async function deployCollection(factory: any, recipient: string, ids: bigint[], values: bigint[]) {
    // on prédit l'adresse retournée par la fonction de factory
    const predicted = await factory
      .getFunction("deploy_erc1155_collection")
      .staticCall(BASE_URI, recipient, ids, values);

    const tx = await factory.deploy_erc1155_collection(BASE_URI, recipient, ids, values);
    await tx.wait();

    const Coll = await ethers.getContractFactory(IMPL_FQN);
    return Coll.attach(predicted);
  }

  /* ---------------------------------------------------------------------- */
  /*                            Tests côté Factory                          */
  /* ---------------------------------------------------------------------- */
  it("Factory: owner + erc1155_collections_class_hash (déploiement)", async () => {
    const [deployer] = await ethers.getSigners();

    const Impl = await ethers.getContractFactory(IMPL_FQN);
    const impl = await Impl.deploy(); await impl.waitForDeployment();

    const Factory = await ethers.getContractFactory(FACT_FQN);
    const factory = await Factory.deploy(deployer.address, await impl.getAddress());
    await factory.waitForDeployment();

    expect(await factory.owner()).to.equal(deployer.address);
    expect(await factory.erc1155_collections_class_hash()).to.equal(await impl.getAddress());
  });

  it("Factory: update_erc1155_collections_class_hash (revert si not owner)", async () => {
    const [deployer, notOwner] = await ethers.getSigners();

    const Impl = await ethers.getContractFactory(IMPL_FQN);
    const impl = await Impl.deploy(); await impl.waitForDeployment();

    const ImplV2 = await ethers.getContractFactory(IMPLV2_FQN);
    const implV2 = await ImplV2.deploy(); await implV2.waitForDeployment();

    const Factory = await ethers.getContractFactory(FACT_FQN);
    const factory = await Factory.deploy(deployer.address, await impl.getAddress());
    await factory.waitForDeployment();

    await expect(
      factory.connect(notOwner).update_erc1155_collections_class_hash(await implV2.getAddress())
    ).to.be.revertedWith("Only owner");
  });

  it("Factory: update_erc1155_collections_class_hash (owner OK)", async () => {
    const [deployer] = await ethers.getSigners();

    const Impl = await ethers.getContractFactory(IMPL_FQN);
    const impl = await Impl.deploy(); await impl.waitForDeployment();

    const ImplV2 = await ethers.getContractFactory(IMPLV2_FQN);
    const implV2 = await ImplV2.deploy(); await implV2.waitForDeployment();

    const Factory = await ethers.getContractFactory(FACT_FQN);
    const factory = await Factory.deploy(deployer.address, await impl.getAddress());
    await factory.waitForDeployment();

    await factory.update_erc1155_collections_class_hash(await implV2.getAddress());
    expect(await factory.erc1155_collections_class_hash()).to.equal(await implV2.getAddress());
  });

  it("Factory: deploy_erc1155_collection (init + balances + class_hash)", async () => {
    const [deployer, recipient] = await ethers.getSigners();
    const { impl, factory } = await deployFactoryWithImpl();

    const coll = await deployCollection(factory, recipient.address, [TOKEN_ID], [VAL1]);

    expect(await coll.owner()).to.equal(deployer.address);
    expect(await coll.class_hash()).to.equal(await impl.getAddress());

    const res: bigint[] = await coll.balance_of_batch([recipient.address], [TOKEN_ID]);
    expect(res[0]).to.equal(VAL1);
    expect(await coll.uri(TOKEN_ID)).to.equal(BASE_URI);
  });

  /* ---------------------------------------------------------------------- */
  /*                       Tests côté Collection (+ V2)                     */
  /* ---------------------------------------------------------------------- */
  it("Collection: upgrade_not_owner → revert", async () => {
    const [, alice] = await ethers.getSigners();
    const { impl, factory } = await deployFactoryWithImpl();
    const coll = await deployCollection(factory, alice.address, [TOKEN_ID], [VAL1]);

    const ImplV2 = await ethers.getContractFactory(IMPLV2_FQN);
    const implV2 = await ImplV2.deploy(); await implV2.waitForDeployment();

    await expect(coll.connect(alice).upgrade(await implV2.getAddress()))
      .to.be.revertedWith("Only owner");

    // class_hash reste sur V1
    expect(await coll.class_hash()).to.equal(await impl.getAddress());
  });

  it("Collection: upgrade par l'owner → class_hash mis à jour", async () => {
    const [deployer, alice] = await ethers.getSigners();
    const { factory } = await deployFactoryWithImpl();
    const coll = await deployCollection(factory, alice.address, [TOKEN_ID], [VAL1]);

    const ImplV2 = await ethers.getContractFactory(IMPLV2_FQN);
    const implV2 = await ImplV2.deploy(); await implV2.waitForDeployment();

    await coll.connect(deployer).upgrade(await implV2.getAddress());
    expect(await coll.class_hash()).to.equal(await implV2.getAddress());
  });

  it("Collection: mint_not_owner → revert", async () => {
    const [, alice, receiver] = await ethers.getSigners();
    const { factory } = await deployFactoryWithImpl();
    const coll = await deployCollection(factory, alice.address, [TOKEN_ID], [VAL1]);

    await expect(coll.connect(alice).mint(receiver.address, TOKEN_ID2, VAL2))
      .to.be.revertedWith("Only owner");
  });

  it("Collection: mint par owner", async () => {
    const [deployer, alice] = await ethers.getSigners();
    const { factory } = await deployFactoryWithImpl();
    const coll = await deployCollection(factory, alice.address, [TOKEN_ID], [VAL1]);

    await coll.connect(deployer).mint(alice.address, TOKEN_ID2, VAL2);
    expect(await coll.balance_of(alice.address, TOKEN_ID2)).to.equal(VAL2);
  });

  it("Collection V2: batch_mint après upgrade", async () => {
    const [deployer, alice] = await ethers.getSigners();
    const { factory } = await deployFactoryWithImpl();
    const collV1 = await deployCollection(factory, alice.address, [TOKEN_ID], [VAL1]);

    const ImplV2 = await ethers.getContractFactory(IMPLV2_FQN);
    const implV2 = await ImplV2.deploy(); await implV2.waitForDeployment();

    await collV1.connect(deployer).upgrade(await implV2.getAddress());

    // attacher l'ABI V2 pour accéder à batch_mint
    const collV2 = (await ethers.getContractFactory(IMPLV2_FQN)).attach(await collV1.getAddress());

    await collV2.connect(deployer).batch_mint(alice.address, [TOKEN_ID2], [VAL2]);
    const res: bigint[] = await collV2.balance_of_batch([alice.address], [TOKEN_ID2]);
    expect(res[0]).to.equal(VAL2);
  });
});
