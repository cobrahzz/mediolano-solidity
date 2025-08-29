// test/IPTokenization.cairo-converted.single.test.ts
import { expect } from "chai";
import { ethers } from "hardhat";
import type { IPNFT, IPTokenizer } from "../typechain-types";

/* Helpers */
const now = async () => (await ethers.provider.getBlock("latest"))!.timestamp;

function createTestAsset(
  owner: string,
  expiry: number
) {
  return {
    metadata_uri: "ipfs://QmTest",
    metadata_hash: "QmTest",
    owner,
    asset_type: 0,     // AssetType::Patent
    license_terms: 0,  // LicenseTerms::Standard
    expiry_date: expiry
  };
}

describe("Cairo → Hardhat (single file) – IPNFT & IPTokenizer", () => {
  /* =========================
     Bloc 1 (IPNFT uniquement)
     ========================= */

  function toBytes32(txt: string) {
    return ethers.keccak256(ethers.toUtf8Bytes(txt));
  }

  it("test_mint", async () => {
    // setup() : déploiement IPNFT avec OWNER, name, symbol, token_uri
    const [OWNER, USER] = await ethers.getSigners();
    const NFT = await ethers.getContractFactory("IPNFT");
    const nft = (await NFT.deploy(
      OWNER.address,                       // initialOwner
      "MEDIOLANO",
      "MDL",
      "https://example.com/token-metadata/1"
    )) as IPNFT;
    await nft.waitForDeployment();

    // start_cheat_caller_address(address, owner) → connect(OWNER)
    // Cairo récupère directement le retour de mint; en Solidity on fait d’abord un staticCall
    const predictedId = await nft.connect(OWNER).mint.staticCall(USER.address);
    expect(Number(predictedId)).to.eq(1, "First token should be ID 1");

    await nft.connect(OWNER).mint(USER.address);
    expect(await nft.ownerOf(1)).to.eq(USER.address, "Wrong token owner");
    // stop_cheat_caller_address : rien à faire (scoping du connect)
  });

  it("test_transfer_restriction", async () => {
    // setup() : redéploiement propre d’IPNFT
    const [OWNER, USER] = await ethers.getSigners();
    const NFT = await ethers.getContractFactory("IPNFT");
    const nft = (await NFT.deploy(
      OWNER.address,
      "MEDIOLANO",
      "MDL",
      "https://example.com/token-metadata/1"
    )) as IPNFT;
    await nft.waitForDeployment();

    const other_user = ethers.Wallet.createRandom().address;

    // start_cheat_caller_address(address, user) → connect(USER)
    // Dans le test Cairo, aucun mint n’a été fait avant : transferFrom(1) doit juste panic.
    await expect(
      nft.connect(USER).transferFrom(USER.address, other_user, 1)
    ).to.be.reverted; // #[should_panic] sans message précis
  });

  /* =========================
     Bloc 2 (IPTokenizer + IPNFT)
     ========================= */

    it("test_bulk_tokenize", async () => {
    const [OWNER, USER] = await ethers.getSigners();

    // Deploy IPNFT
    const NFT = await ethers.getContractFactory("IPNFT");
    const nft = await NFT.deploy(
        OWNER.address,
        "MEDIOLANO",
        "MDL",
        "https://example.com/token-metadata/1"
    );
    await nft.waitForDeployment();

    // Deploy IPTokenizer
    const TOK = await ethers.getContractFactory("IPTokenizer");
    const tok = await TOK.deploy(
        OWNER.address,
        await nft.getAddress(),
        "https://example.com/token-metadata/1"
    );
    await tok.waitForDeployment();

    // 🔑 Donner la propriété de l’IPNFT au Tokenizer pour qu’il puisse minter
    await nft.connect(OWNER).transferOwnership(await tok.getAddress());

    const t0 = (await ethers.provider.getBlock("latest"))!.timestamp;
    const assets = [
        {
        metadata_uri: "ipfs://QmTest",
        metadata_hash: "QmTest",
        owner: USER.address,
        asset_type: 0,     // Patent
        license_terms: 0,  // Standard
        expiry_date: t0 + 3600
        },
        {
        metadata_uri: "ipfs://QmTest",
        metadata_hash: "QmTest",
        owner: USER.address,
        asset_type: 0,
        license_terms: 0,
        expiry_date: t0 + 7200
        },
    ];

    // Comme en Cairo: on lit d’abord la valeur de retour
    const retIds = await tok.connect(OWNER).bulk_tokenize.staticCall(assets);
    expect(retIds.length).to.eq(2, "Should mint 2 tokens");

    // Puis on exécute vraiment la tx (optionnel)
    await tok.connect(OWNER).bulk_tokenize(assets);
    });

});
