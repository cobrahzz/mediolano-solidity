import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";

describe("IPLeasing (tests traduits Cairo -> TS)", function () {
  const TOKEN_ID = 1n;
  const AMOUNT = 100n;
  const LEASE_FEE = 10n;
  const DURATION = 86_400n; // 1 day
  const BASE_URI = "ipfs://QmBaseUri";
  const LICENSE_URI = "ipfs://QmLicenseTerms";

  let owner: any;
  let user1: any;
  let user2: any;
  let extra: any;

  let leasing: Contract;

  async function deploy() {
    [owner, user1, user2, extra] = await ethers.getSigners();
    const F = await ethers.getContractFactory("IPLeasing", owner);
    leasing = await F.deploy(await owner.getAddress(), BASE_URI);
    await leasing.waitForDeployment();
  }

  beforeEach(async () => {
    await deploy();
  });

  // helper pour retrouver l’adresse facilement
  const addr = (s: any) => s.address as string;

  // ========= tests =========

  it("cancel_lease_offer_no_offer -> revert(No active offer)", async () => {
    // owner tente d'annuler une offre inexistante
    await expect(leasing.connect(owner).cancel_lease_offer(TOKEN_ID))
      .to.be.revertedWith("No active offer");
  });

  it("start_lease_no_offer -> revert(No active offer)", async () => {
    await expect(leasing.connect(user1).start_lease(TOKEN_ID))
      .to.be.revertedWith("No active offer");
  });

  it("mint_ip_not_owner -> revert OwnableUnauthorizedAccount", async () => {
    // OZ v5 émet un custom error OwnableUnauthorizedAccount(address)
    await expect(
      leasing.connect(user1).mint_ip(addr(owner), TOKEN_ID, AMOUNT)
    )
      .to.be.revertedWithCustomError(leasing, "OwnableUnauthorizedAccount")
      .withArgs(addr(user1));
  });

  it("create_lease_offer_not_owner -> revert(Not token owner)", async () => {
    // user1 ne possède aucun token => échoue sur le check de propriété
    await expect(
      leasing.connect(user1).create_lease_offer(
        TOKEN_ID,
        AMOUNT,
        LEASE_FEE,
        Number(DURATION),
        LICENSE_URI
      )
    ).to.be.revertedWith("Not token owner");
  });

  it("renew_lease_no_lease -> revert(No active lease)", async () => {
    await expect(
      leasing.connect(user1).renew_lease(TOKEN_ID, Number(DURATION))
    ).to.be.revertedWith("No active lease");
  });

  // --- (optionnel) helpers si tu veux pousser plus loin les tests positifs ---
  // function mintTo(to: any, tokenId: bigint, amount: bigint) {
  //   return leasing.connect(owner).mint_ip(addr(to), tokenId, amount);
  // }
});
