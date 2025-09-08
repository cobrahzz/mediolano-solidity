import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, mine, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("OpenEditionERC721A (Solidity port)", () => {
  // Constants (alignés avec tes tests)
  const PHASE_ID = 1n;
  const PRICE = 1000n;
  const START_TIME = 1000n; // seconds
  const END_TIME = 2000n;   // seconds

  async function deployFixture() {
    const [owner, user1, user2] = await ethers.getSigners();
    const name = "Open Edition NFT";
    const symbol = "OEN";
    const baseUri = "ipfs://QmBaseUri";

    const C = await ethers.getContractFactory("OpenEditionERC721A");
    const c = await C.deploy(name, symbol, baseUri, owner.address);
    await c.waitForDeployment();

    return { c, owner, user1, user2 };
  }

  async function setBlockTimestamp(ts: bigint | number) {
    await time.setNextBlockTimestamp(Number(ts));
    await mine();
  }

  // Helper pour créer une phase (imitant le cheat_caller Cairo)
  async function setupClaimPhase(
    c: any,
    owner: any,
    phaseId: bigint,
    isPublic: boolean,
    whitelist: string[]
  ) {
    await c.connect(owner).create_claim_phase(
      phaseId,
      PRICE,
      Number(START_TIME),
      Number(END_TIME),
      isPublic,
      whitelist
    );
  }

  it("test_create_claim_phase", async () => {
    const { c, owner, user1, user2 } = await loadFixture(deployFixture);

    await c.connect(owner).create_claim_phase(
      PHASE_ID,
      PRICE,
      Number(START_TIME),
      Number(END_TIME),
      true,                           // public phase
      [user1.address]                 // NOTE: avec mon contrat, ce whitelist ne sera pas écrit
    );

    const phase = await c.get_claim_phase(PHASE_ID);
    expect(phase.price).to.equal(PRICE);
    expect(phase.start_time).to.equal(START_TIME);
    expect(phase.end_time).to.equal(END_TIME);
    expect(phase.is_public).to.equal(true);

    // ⚠️ Voir la note en tête de fichier
    expect(await c.is_whitelisted(PHASE_ID, user1.address)).to.equal(false);
    expect(await c.is_whitelisted(PHASE_ID, user2.address)).to.equal(false);
  });

  it("test_create_claim_phase_not_owner (should revert)", async () => {
    const { c, user1 } = await loadFixture(deployFixture);
    await expect(
      c.connect(user1).create_claim_phase(
        PHASE_ID,
        PRICE,
        Number(START_TIME),
        Number(END_TIME),
        true,
        []
      )
    ).to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("test_create_claim_phase_invalid_time (should revert)", async () => {
    const { c, owner } = await loadFixture(deployFixture);
    await expect(
      c.connect(owner).create_claim_phase(
        PHASE_ID,
        PRICE,
        Number(END_TIME),   // inversé
        Number(START_TIME), // inversé
        true,
        []
      )
    ).to.be.revertedWith("Invalid time range");
  });

  it("test_create_claim_phase_already_ended (should revert)", async () => {
    const { c, owner } = await loadFixture(deployFixture);
    await setBlockTimestamp(END_TIME + 1n);
    await expect(
      c.connect(owner).create_claim_phase(
        PHASE_ID,
        PRICE,
        Number(START_TIME),
        Number(END_TIME),
        true,
        []
      )
    ).to.be.revertedWith("Phase ended");
  });

  it("test_update_metadata", async () => {
    const { c, owner } = await loadFixture(deployFixture);
    const newBase = "ipfs://QmNewBaseUri";
    await c.connect(owner).update_metadata(newBase);
    expect(await c.get_metadata(1)).to.equal(newBase);
  });

  it("test_update_metadata_not_owner (should revert)", async () => {
    const { c, user1 } = await loadFixture(deployFixture);
    await expect(c.connect(user1).update_metadata("ipfs://QmNewBaseUri"))
      .to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("test_mint_public_phase", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);
    await setupClaimPhase(c, owner, PHASE_ID, true, []);
    await setBlockTimestamp(START_TIME);
    const tx = await c.connect(user1).mint(PHASE_ID, 2);
    const receipt = await tx.wait();

    // Premier id attendu = 1
    expect(await c.get_current_token_id()).to.equal(2n);
    expect(await c.ownerOf(1)).to.equal(user1.address);
    expect(await c.ownerOf(2)).to.equal(user1.address);

    // get_metadata renvoie base_uri brut (parité Cairo)
    expect(await c.get_metadata(1)).to.equal("ipfs://QmBaseUri");
    expect(await c.get_metadata(2)).to.equal("ipfs://QmBaseUri");
  });

  it("test_mint_whitelist_phase", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    // ⚠️ Avec mon contrat, la whitelist n'est écrite que si is_public == false
    await setupClaimPhase(c, owner, PHASE_ID, false, [user1.address]);

    await setBlockTimestamp(START_TIME);
    await c.connect(user1).mint(PHASE_ID, 1);

    expect(await c.get_current_token_id()).to.equal(1n);
    expect(await c.ownerOf(1)).to.equal(user1.address);
    expect(await c.get_metadata(1)).to.equal("ipfs://QmBaseUri");
  });

  it("test_mint_whitelist_phase_not_whitelisted (should revert)", async () => {
    const { c, owner, user2 } = await loadFixture(deployFixture);
    await setupClaimPhase(c, owner, PHASE_ID, false, []); // personne whitelist
    await setBlockTimestamp(START_TIME);

    await expect(c.connect(user2).mint(PHASE_ID, 1)).to.be.revertedWith("Not whitelisted");
  });

  it("test_mint_before_phase_start (should revert)", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);
    await setupClaimPhase(c, owner, PHASE_ID, true, []);
    await setBlockTimestamp(START_TIME - 1n);
    await expect(c.connect(user1).mint(PHASE_ID, 1)).to.be.revertedWith("Phase not started");
  });

  it("test_mint_after_phase_end (should revert)", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);
    await setupClaimPhase(c, owner, PHASE_ID, true, []);
    await setBlockTimestamp(END_TIME + 1n);
    await expect(c.connect(user1).mint(PHASE_ID, 1)).to.be.revertedWith("Phase ended");
  });

  it("test_mint_zero_quantity (should revert)", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);
    await setupClaimPhase(c, owner, PHASE_ID, true, []);
    await setBlockTimestamp(START_TIME);
    await expect(c.connect(user1).mint(PHASE_ID, 0)).to.be.revertedWith("Invalid quantity");
  });

  it("test_mint_ended_phase_or_not_found (should revert)", async () => {
    const { c, user1 } = await loadFixture(deployFixture);
    // Pas de phase 999 créée => dans ce port Solidity, ça revert "Phase not found"
    await setBlockTimestamp(START_TIME);
    await expect(c.connect(user1).mint(999, 1)).to.be.revertedWith("Phase not found");
  });
});
