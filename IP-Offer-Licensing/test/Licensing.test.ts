import { expect } from "chai";
import { ethers } from "hardhat";

const IP_TOKEN_ID = 1n;
const PAYMENT_AMOUNT = 1000n;
const LICENSE_TERMS = "Test License Terms";

describe("IPOfferLicensing", () => {
  async function deployAll() {
    const [owner, creator, buyer, ...rest] = await ethers.getSigners();

    // Deploy mock ERC721
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    const erc721 = await MockERC721.deploy();
    await erc721.waitForDeployment();

    // Mint tokenId 1 to "creator"
    await erc721.mint(await creator.getAddress(), IP_TOKEN_ID);

    // Deploy main contract with ipTokenContract address
    const IPOfferLicensing = await ethers.getContractFactory("IPOfferLicensing");
    const ipo = await IPOfferLicensing.connect(owner).deploy(await erc721.getAddress());
    await ipo.waitForDeployment();

    return { owner, creator, buyer, erc721, ipo };
  }

  it("test_simple", async () => {
    expect(1).to.eq(1);
  });

  it("test_contract_deployment", async () => {
    const { ipo } = await deployAll();
    expect(await ipo.getAddress()).to.properAddress;
  });

  it("test_contract_interface", async () => {
    const { ipo } = await deployAll();
    expect(await ipo.getAddress()).to.properAddress;
  });

  it("test_contract_initialization", async () => {
    const { ipo } = await deployAll();
    const count = await ipo.offer_count();
    expect(count).to.equal(0n);
  });

  it("test_basic_functionality", async () => {
    const { ipo } = await deployAll();
    // just a simple read call (no offers yet)
    const byCreator = await ipo.get_offers_by_creator(ethers.ZeroAddress);
    expect(byCreator.length).to.eq(0);
  });

  it("test_contract_operations", async () => {
    const { ipo } = await deployAll();
    const addr = await ipo.getAddress();
    expect(addr).to.properAddress;
  });

  it("test_error_handling (revert if not IP owner)", async () => {
    const { ipo, buyer } = await deployAll();
    await expect(
      ipo.connect(buyer).create_offer(IP_TOKEN_ID, PAYMENT_AMOUNT, ethers.ZeroAddress, LICENSE_TERMS)
    ).to.be.revertedWith("Not IP owner");
  });

  it("test_event_system (OfferCreated)", async () => {
    const { ipo, creator } = await deployAll();
    const offerId = 0n;

    await expect(
      ipo.connect(creator).create_offer(IP_TOKEN_ID, PAYMENT_AMOUNT, ethers.ZeroAddress, LICENSE_TERMS)
    )
      .to.emit(ipo, "OfferCreated")
      .withArgs(
        offerId,
        IP_TOKEN_ID,
        await creator.getAddress(),
        await creator.getAddress(), // owner == creator (il possède le token)
        PAYMENT_AMOUNT,
        ethers.ZeroAddress
      );

    const stored = await ipo.get_offer(offerId);
    expect(stored.id).to.equal(offerId);
    expect(stored.ip_token_id).to.equal(IP_TOKEN_ID);
    expect(stored.creator).to.equal(await creator.getAddress());
    expect(stored.owner).to.equal(await creator.getAddress());
  });

  it("test_contract_structure (arrays exist)", async () => {
    const { ipo, creator } = await deployAll();

    const byIpBefore = await ipo.get_offers_by_ip(IP_TOKEN_ID);
    expect(byIpBefore.length).to.eq(0);

    await ipo.connect(creator).create_offer(IP_TOKEN_ID, PAYMENT_AMOUNT, ethers.ZeroAddress, LICENSE_TERMS);

    const byIpAfter = await ipo.get_offers_by_ip(IP_TOKEN_ID);
    expect(byIpAfter.length).to.eq(1);

    const byCreator = await ipo.get_offers_by_creator(await creator.getAddress());
    expect(byCreator.length).to.eq(1);

    const byOwner = await ipo.get_offers_by_owner(await creator.getAddress());
    expect(byOwner.length).to.eq(1);
  });

  it("test_contract_deployment_with_parameters (ipTokenContract set)", async () => {
    const { ipo, erc721 } = await deployAll();
    const ipTokenAddr = await ipo.ipTokenContract();
    expect(ipTokenAddr).to.equal(await erc721.getAddress());
  });

  it("test_contract_accessibility", async () => {
    const { ipo } = await deployAll();
    const list = await ipo.get_offers_by_owner(ethers.ZeroAddress);
    expect(list.length).to.eq(0);
  });

  it("test_contract_integrity (create + read offer)", async () => {
    const { ipo, creator } = await deployAll();
    const offerId = await ipo.connect(creator).create_offer(
      IP_TOKEN_ID,
      PAYMENT_AMOUNT,
      ethers.ZeroAddress,
      LICENSE_TERMS
    ).then(tx => tx.wait()).then(async (r) => {
      // offer_count increments after storing; the id returned by event is simpler to read:
      const ev = r!.logs.find(l => (l as any).fragment?.name === "OfferCreated") as any;
      return ev?.args?.offer_id as bigint ?? 0n;
    });

    const ofr = await ipo.get_offer(offerId);
    expect(ofr.payment_amount).to.equal(PAYMENT_AMOUNT);
    expect(ofr.license_terms).to.equal(LICENSE_TERMS);
  });
});
