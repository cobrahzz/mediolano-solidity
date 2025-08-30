import { expect } from "chai";
import { ethers, network } from "hardhat";
import { Contract, Signer } from "ethers";

// Helpers time
const increaseTime = async (secs: number | bigint) => {
  await network.provider.send("evm_increaseTime", [Number(secs)]);
  await network.provider.send("evm_mine");
};
const now = async (): Promise<number> => {
  const b = await ethers.provider.getBlock("latest");
  return Number(b!.timestamp);
};

// Enums mirror (doivent matcher l’ordre dans les contrats)
enum PaymentSchedule { Monthly, Quarterly, SemiAnnually, Annually, Custom }
enum ExclusivityType { Exclusive, NonExclusive }
enum FranchiseSaleStatus { Pending, Approved, Rejected, Completed }
enum PaymentModelKind { OneTime, RoyaltyBased }

type RoyaltyFees = {
  royaltyPercent: number;               // uint8
  paymentSchedule: number;             // enum
  customInterval: bigint;              // uint64
  hasCustomInterval: boolean;
  lastPaymentId: number;               // uint32
  maxMissedPayments: number;           // uint32
};

type FranchiseTerms = {
  kind: number;             // PaymentModelKind
  paymentToken: string;     // address
  franchiseFee: bigint;
  licenseStart: bigint;     // uint64
  licenseEnd: bigint;       // uint64
  exclusivity: number;      // ExclusivityType
  territoryId: bigint;

  oneTimeFee: bigint;       // if OneTime
  royaltyFees: RoyaltyFees; // if RoyaltyBased
};

// Signers
let owner: Signer, franchisee: Signer, buyer: Signer, someone: Signer;

const ONE_E18 = 10n ** 18n;

async function deployMocks() {
  const [o, f, b, s] = await ethers.getSigners();
  owner = o; franchisee = f; buyer = b; someone = s;

  const ERC20 = await ethers.getContractFactory("MockERC20", owner);
  const erc20 = await ERC20.deploy("DummyERC20", "DUMMY", 0n);
  await erc20.waitForDeployment();

  const ERC721 = await ethers.getContractFactory("MockERC721", owner);
  const erc721 = await ERC721.deploy("DummyBaseURI/");
  await erc721.waitForDeployment();

  // Mint l’IP NFT au owner
  await (await erc721.connect(owner).mint(await owner.getAddress(), 1n)).wait();

  return { erc20, erc721 };
}

function oneTimeTerms(
  token: string,
  franchiseFee: bigint,
  oneTimeFee: bigint,
  licenseStart: number,
  licenseEnd: number,
  territoryId: bigint = 0n,
  exclusivity: ExclusivityType = ExclusivityType.NonExclusive
): FranchiseTerms {
  return {
    kind: PaymentModelKind.OneTime,
    paymentToken: token,
    franchiseFee,
    licenseStart: BigInt(licenseStart),
    licenseEnd: BigInt(licenseEnd),
    exclusivity,
    territoryId,
    oneTimeFee,
    royaltyFees: {
      royaltyPercent: 0,
      paymentSchedule: PaymentSchedule.Monthly,
      customInterval: 0n,
      hasCustomInterval: false,
      lastPaymentId: 0,
      maxMissedPayments: 0
    }
  };
}

function royaltyTerms(
  token: string,
  franchiseFee: bigint,
  royaltyPercent: number,
  schedule: PaymentSchedule,
  maxMissedPayments: number,
  licenseStart: number,
  licenseEnd: number,
  territoryId: bigint = 0n
): FranchiseTerms {
  return {
    kind: PaymentModelKind.RoyaltyBased,
    paymentToken: token,
    franchiseFee,
    licenseStart: BigInt(licenseStart),
    licenseEnd: BigInt(licenseEnd),
    exclusivity: ExclusivityType.NonExclusive,
    territoryId,
    oneTimeFee: 0n,
    royaltyFees: {
      royaltyPercent,
      paymentSchedule: schedule,
      customInterval: 0n,
      hasCustomInterval: false,
      lastPaymentId: 0,
      maxMissedPayments
    }
  };
}

async function deployManager(
  ipNftId: bigint,
  ipNftAddress: string,
  defaultFranchiseFee: bigint,
  preferredTerms: FranchiseTerms
) {
  const Manager = await ethers.getContractFactory("IPFranchiseManager", owner);
  const mgr = await Manager.deploy(
    await owner.getAddress(),
    ipNftId,
    ipNftAddress,
    defaultFranchiseFee,
    preferredTerms
  );
  await mgr.waitForDeployment();
  return mgr;
}

async function linkIP(mgr: Contract, erc721: Contract) {
  // setApprovalForAll(manager, true)
  await (await erc721.connect(owner).setApprovalForAll(await mgr.getAddress(), true)).wait();
  // link_ip_asset (owner)
  await (await mgr.connect(owner).link_ip_asset()).wait();
}

async function addTerritory(mgr: Contract, name = "Lagos") {
  await (await mgr.connect(owner).add_franchise_territory(name)).wait();
}

async function createDirectAgreement(mgr: Contract, terms: FranchiseTerms) {
  await (await mgr.connect(owner).create_direct_franchise_agreement(await franchisee.getAddress(), terms)).wait();
  const total = await mgr.get_total_franchise_agreements();
  const agreementId = total - 1n;
  const addr = await mgr.get_franchise_agreement_address(agreementId);
  const agreement = await ethers.getContractAt("IPFranchisingAgreement", addr, owner);
  return { agreement, agreementId };
}

describe("IP Franchise – parity tests (Cairo ➜ Solidity)", () => {
  it("initialization successful", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const preferred = oneTimeTerms(
      await erc20.getAddress(),
      500n,
      20000n,
      nowTs + 3600,
      nowTs + 2 * 365 * 24 * 60 * 60,
      0n
    );
    const mgr = await deployManager(1n, await erc721.getAddress(), 500n, preferred);

    expect(await mgr.get_ip_nft_id()).to.eq(1n);
    expect(await mgr.get_ip_nft_address()).to.eq(await erc721.getAddress());
    expect(await mgr.get_default_franchise_fee()).to.eq(500n);

    const pref = await mgr.get_preferred_payment_model();
    expect(pref.kind).to.eq(PaymentModelKind.OneTime);
    expect(pref.oneTimeFee).to.eq(20000n);
  });

  it("link / unlink IP NFT", async () => {
    const { erc20: _, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(
      1n,
      await erc721.getAddress(),
      500n,
      oneTimeTerms(ethers.ZeroAddress, 0n, 0n, nowTs + 3600, nowTs + 10 * 365 * 24 * 60 * 60)
    );

    await linkIP(mgr, erc721);
    expect(await mgr.is_ip_asset_linked()).to.eq(true);
    expect(await erc721.ownerOf(1n)).to.eq(await mgr.getAddress());

    await (await mgr.connect(owner).unlink_ip_asset()).wait();
    expect(await mgr.is_ip_asset_linked()).to.eq(false);
    expect(await erc721.ownerOf(1n)).to.eq(await owner.getAddress());
  });

  it("add / deactivate territories", async () => {
    const { erc20: _, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(
      1n,
      await erc721.getAddress(),
      500n,
      oneTimeTerms(ethers.ZeroAddress, 0n, 0n, nowTs + 3600, nowTs + 10 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);

    await addTerritory(mgr, "Lagos");
    const t0 = await mgr.get_territory_info(0n);
    expect(t0.name).to.eq("Lagos");
    expect(t0.active).to.eq(true);
    expect(t0.hasExclusiveAgreement).to.eq(false);

    await (await mgr.connect(owner).deactivate_franchise_territory(0n)).wait();
    const t0b = await mgr.get_territory_info(0n);
    expect(t0b.active).to.eq(false);
  });

  it("activate agreement – one-time fee", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(
      1n, await erc721.getAddress(), 500n,
      oneTimeTerms(await erc20.getAddress(), 200n, 1000n, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);

    const terms = oneTimeTerms(await erc20.getAddress(), 100n, 1000n, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60);
    const { agreement } = await createDirectAgreement(mgr, terms);

    const activationFee = await agreement.get_activation_fee(); // 100 + 1000
    // mint/approve depuis FRANCHISEE
    await (await erc20.connect(owner).mint(await franchisee.getAddress(), activationFee)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), activationFee)).wait();

    await (await agreement.connect(franchisee).activate_franchise()).wait();
    expect(await agreement.is_active()).to.eq(true);

    const bal = await erc20.balanceOf(await mgr.getAddress());
    expect(bal).to.eq(activationFee);
  });

  it("activate agreement – royalty model", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(
      1n, await erc721.getAddress(), 500n,
      oneTimeTerms(await erc20.getAddress(), 0n, 0n, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);

    const terms = royaltyTerms(
      await erc20.getAddress(), 100n, /*rf*/ 10, PaymentSchedule.Monthly, 5,
      nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60
    );
    const { agreement } = await createDirectAgreement(mgr, terms);

    const activationFee = await agreement.get_activation_fee(); // franchise_fee only (100)
    await (await erc20.connect(owner).mint(await franchisee.getAddress(), activationFee)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), activationFee)).wait();

    await (await agreement.connect(franchisee).activate_franchise()).wait();
    expect(await agreement.is_active()).to.eq(true);

    const bal = await erc20.balanceOf(await mgr.getAddress());
    expect(bal).to.eq(activationFee);
  });

  it("create + approve + reject sale request (manager path)", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(1n, await erc721.getAddress(), 0n,
      oneTimeTerms(await erc20.getAddress(), 0n, 0n, nowTs + 3600, nowTs + 4 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);
    const terms = royaltyTerms(await erc20.getAddress(), 10n, 10, PaymentSchedule.Monthly, 5, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60);
    const { agreement, agreementId } = await createDirectAgreement(mgr, terms);

    // activer
    const actFee = await agreement.get_activation_fee();
    await (await erc20.connect(owner).mint(await franchisee.getAddress(), actFee)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), actFee)).wait();
    await (await agreement.connect(franchisee).activate_franchise()).wait();

    // create sale request (franchisee)
    await (await agreement.connect(franchisee).create_sale_request(await buyer.getAddress(), 5000n)).wait();
    const saleReq = await agreement.get_sale_request();
    expect(saleReq[0]).to.eq(true); // exists

    // approve sale (owner → via manager)
    await (await mgr.connect(owner).approve_franchise_sale(agreementId)).wait();

    // reject est mutual exclusif; on réinitialise une nouvelle vente pour tester le rejet
    await (await agreement.connect(franchisee).create_sale_request(await buyer.getAddress(), 6000n)).wait();
    await (await mgr.connect(owner).reject_franchise_sale(agreementId)).wait();
    const saleReq2 = await agreement.get_sale_request();
    expect(saleReq2[1].status).to.eq(FranchiseSaleStatus.Rejected);
  });

  it("finalize sale request (buyer pays 20/80 split)", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(1n, await erc721.getAddress(), 0n,
      oneTimeTerms(await erc20.getAddress(), 0n, 0n, nowTs + 3600, nowTs + 4 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);
    const terms = royaltyTerms(await erc20.getAddress(), 10n, 10, PaymentSchedule.Monthly, 5, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60);
    const { agreement, agreementId } = await createDirectAgreement(mgr, terms);

    // activer
    const actFee = await agreement.get_activation_fee();
    await (await erc20.connect(owner).mint(await franchisee.getAddress(), actFee)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), actFee)).wait();
    await (await agreement.connect(franchisee).activate_franchise()).wait();

    // create + approve
    const price = 5000n * ONE_E18 / ONE_E18; // sans décimales
    await (await agreement.connect(franchisee).create_sale_request(await buyer.getAddress(), price)).wait();
    await (await mgr.connect(owner).approve_franchise_sale(agreementId)).wait();

    // buyer paie
    await (await erc20.connect(owner).mint(await buyer.getAddress(), price)).wait();
    await (await erc20.connect(buyer).approve(await agreement.getAddress(), price)).wait();
    await (await agreement.connect(buyer).finalize_franchise_sale()).wait();

    const saleReq = await agreement.get_sale_request();
    expect(saleReq[1].status).to.eq(FranchiseSaleStatus.Completed);
    expect(await agreement.get_franchisee()).to.eq(await buyer.getAddress());
  });

  it("royalty payment path (1 mois)", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(1n, await erc721.getAddress(), 0n,
      oneTimeTerms(await erc20.getAddress(), 0n, 0n, nowTs + 3600, nowTs + 4 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);
    const terms = royaltyTerms(await erc20.getAddress(), 100n, 10, PaymentSchedule.Monthly, 5, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60);
    const { agreement } = await createDirectAgreement(mgr, terms);

    // activer
    const actFee = await agreement.get_activation_fee();
    await (await erc20.connect(owner).mint(await franchisee.getAddress(), actFee)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), actFee)).wait();
    await (await agreement.connect(franchisee).activate_franchise()).wait();

    // avance temps: > start + 31 jours
    await increaseTime(31 * 24 * 60 * 60);

    const missed = await agreement.get_total_missed_payments();
    expect(missed).to.eq(1);

    const revenue = 10_000_000n;
    const expectedRoyalty = revenue * 10n / 100n;

    await (await erc20.connect(owner).mint(await franchisee.getAddress(), expectedRoyalty)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), expectedRoyalty)).wait();

    await (await agreement.connect(franchisee).make_royalty_payments([revenue])).wait();

    const bal = await erc20.balanceOf(await mgr.getAddress());
    expect(bal).to.eq(actFee + expectedRoyalty);

    const termsAfter = await agreement.get_franchise_terms();
    expect(termsAfter.royaltyFees.lastPaymentId).to.eq(1);

    const p = await agreement.get_royalty_payment_info(1);
    expect(p.reportedRevenue).to.eq(revenue);
    expect(p.royaltyPaid).to.eq(expectedRoyalty);
  });

  it("revoke after 5 missed months, then reinstate after paying arrears", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(1n, await erc721.getAddress(), 0n,
      oneTimeTerms(await erc20.getAddress(), 0n, 0n, nowTs + 3600, nowTs + 4 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);
    const terms = royaltyTerms(await erc20.getAddress(), 100n, 10, PaymentSchedule.Monthly, 5, nowTs + 3600, nowTs + 2 * 365 * 24 * 60 * 60);
    const { agreement, agreementId } = await createDirectAgreement(mgr, terms);

    const actFee = await agreement.get_activation_fee();
    await (await erc20.connect(owner).mint(await franchisee.getAddress(), actFee)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), actFee)).wait();
    await (await agreement.connect(franchisee).activate_franchise()).wait();

    // avancer 5 mois + 1 jour
    await increaseTime(5 * 30 * 24 * 60 * 60 + 24 * 60 * 60);

    expect(await agreement.get_total_missed_payments()).to.eq(5);
    await (await mgr.connect(owner).revoke_franchise_license(agreementId)).wait();
    expect(await agreement.is_revoked()).to.eq(true);

    // payer 5 mois d’un coup
    const revs = [10_000_000n, 20_000_000n, 30_000_000n, 40_000_000n, 50_000_000n];
    const totalRev = revs.reduce((a, b) => a + b, 0n);
    const royalty = totalRev * 10n / 100n;

    await (await erc20.connect(owner).mint(await franchisee.getAddress(), royalty)).wait();
    await (await erc20.connect(franchisee).approve(await agreement.getAddress(), royalty)).wait();
    await (await agreement.connect(franchisee).make_royalty_payments(revs)).wait();

    expect(await agreement.get_total_missed_payments()).to.eq(0);

    await (await mgr.connect(owner).reinstate_franchise_license(agreementId)).wait();
    expect(await agreement.is_revoked()).to.eq(false);

    const bal = await erc20.balanceOf(await mgr.getAddress());
    expect(bal).to.eq(actFee + royalty);
  });

  it("applications: apply / approve / reject / revise / accept revision / create from application", async () => {
    const { erc20, erc721 } = await deployMocks();
    const nowTs = await now();
    const mgr = await deployManager(1n, await erc721.getAddress(), 500n,
      oneTimeTerms(await erc20.getAddress(), 20000n, 0n, nowTs + 3600, nowTs + 4 * 365 * 24 * 60 * 60)
    );
    await linkIP(mgr, erc721);
    await addTerritory(mgr);

    const baseTerms = oneTimeTerms(await erc20.getAddress(), 100n, 1000n, nowTs + 3600, nowTs + 365 * 24 * 60 * 60);
    // apply en tant que franchisee
    await (await mgr.connect(franchisee).apply_for_franchise(baseTerms)).wait();
    const appCount = await mgr.get_total_franchise_applications();
    const appId = appCount - 1n;
    let ver = await mgr.get_franchise_application_version(appId);
    let app = await mgr.get_franchise_application(appId, ver);
    expect(app.franchisee).to.eq(await franchisee.getAddress());

    // revise par owner
    const revisedByOwner = { ...baseTerms, kind: PaymentModelKind.OneTime, oneTimeFee: 1_000_000n, franchiseFee: 40_000n };
    await (await mgr.connect(owner).revise_franchise_application(appId, revisedByOwner)).wait();
    ver = await mgr.get_franchise_application_version(appId);
    app = await mgr.get_franchise_application(appId, ver);
    expect(app.status).to.eq(1); // Revised

    // revise par franchisee
    const revisedByFranch = { ...baseTerms, kind: PaymentModelKind.OneTime, oneTimeFee: 50_000n, franchiseFee: 40n };
    await (await mgr.connect(franchisee).revise_franchise_application(appId, revisedByFranch)).wait();
    const ver2 = await mgr.get_franchise_application_version(appId);
    expect(Number(ver2)).to.eq(Number(ver) + 1);

    // accept revision par franchisee
    await (await mgr.connect(franchisee).accept_franchise_application_revision(appId)).wait();
    const ver3 = await mgr.get_franchise_application_version(appId);
    const app3 = await mgr.get_franchise_application(appId, ver3);
    // ApplicationStatus.RevisionAccepted = 2
    expect(app3.status).to.eq(2);

    // approve + create from application
    await (await mgr.connect(owner).approve_franchise_application(appId)).wait();
    await (await mgr.connect(owner).create_franchise_agreement_from_application(appId)).wait();

    const total = await mgr.get_total_franchise_agreements();
    expect(total).to.eq(1n);
    const lastId = total - 1n;
    const addr = await mgr.get_franchise_agreement_address(lastId);
    const ag = await ethers.getContractAt("IPFranchisingAgreement", addr, owner);
    expect(await ag.get_agreement_id()).to.eq(lastId);
    expect(await ag.is_active()).to.eq(false);
  });
});
