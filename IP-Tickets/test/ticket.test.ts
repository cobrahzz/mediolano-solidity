import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

async function deployMockERC20(owner: any) {
  const MockERC20 = await ethers.getContractFactory("MockERC20", owner);
  const erc20 = await MockERC20.deploy(owner.address);
  await erc20.waitForDeployment();
  return erc20;
}

async function deployIPTicketService(erc20Address: string, owner: any) {
  const IPTicketService = await ethers.getContractFactory("IPTicketService", owner);
  const ticketService = await IPTicketService.deploy(
    "IP Tickets",
    "IPT",
    erc20Address,
    "https://example.com/"
  );
  await ticketService.waitForDeployment();
  return ticketService;
}

async function setup() {
  const [owner, minter] = await ethers.getSigners();

  const erc20 = await deployMockERC20(owner);
  const ticketService = await deployIPTicketService(await erc20.getAddress(), owner);

  // créditer le minter et approuver le service
  await erc20.connect(owner).transfer(minter.address, ethers.parseUnits("1000000", 18));
  await erc20.connect(minter).approve(await ticketService.getAddress(), ethers.MaxUint256);

  return { ticketService, erc20, owner, minter };
}

describe("IPTicketService (single file tests)", () => {
  it("create_ip_asset: succès + event", async () => {
    const { ticketService, owner } = await setup();
    const price = ethers.parseUnits("100", 18);
    const maxSupply = 5n;
    const now = await time.latest();
    const expiration = now + 1_000n;
    const royalty = 500n; // 5%
    const metadata = "ip://metadata";

    await expect(
      ticketService
        .connect(owner)
        .create_ip_asset(price, maxSupply, expiration, royalty, metadata)
    )
      .to.emit(ticketService, "IPAssetCreated")
      .withArgs(1n, owner.address, price, maxSupply, expiration, royalty, metadata);
  });

  it("mint_ticket: succès (ownerOf + has_valid_ticket + event)", async () => {
    const { ticketService, owner, minter } = await setup();
    const price = ethers.parseUnits("100", 18);
    const maxSupply = 2n;
    const now = await time.latest();
    const expiration = now + 1_000n;
    const royalty = 500n;
    const metadata = "ip://metadata";

    await ticketService
      .connect(owner)
      .create_ip_asset(price, maxSupply, expiration, royalty, metadata);

    await expect(ticketService.connect(minter).mint_ticket(1n))
      .to.emit(ticketService, "TicketMinted")
      .withArgs(1n, 1n, minter.address);

    expect(await ticketService.ownerOf(1n)).to.equal(minter.address);
    expect(await ticketService.has_valid_ticket(minter.address, 1n)).to.equal(true);
  });

  it("mint_ticket: dépasse la supply -> revert", async () => {
    const { ticketService, owner, minter } = await setup();
    const price = ethers.parseUnits("100", 18);
    const maxSupply = 1n;
    const now = await time.latest();
    const expiration = now + 1_000n;
    const royalty = 500n;

    await ticketService
      .connect(owner)
      .create_ip_asset(price, maxSupply, expiration, royalty, "ip://metadata");

    await ticketService.connect(minter).mint_ticket(1n);
    await expect(ticketService.connect(minter).mint_ticket(1n)).to.be.revertedWith(
      "Max supply reached"
    );
  });

  it("mint_ticket: allowance insuffisante -> revert", async () => {
    const { ticketService, erc20, owner, minter } = await setup();
    const price = ethers.parseUnits("100", 18);
    const now = await time.latest();
    const expiration = now + 1_000n;

    await ticketService
      .connect(owner)
      .create_ip_asset(price, 1n, expiration, 500n, "ip://metadata");

    // révoquer l'approval pour simuler l'insuffisance
    await erc20.connect(minter).approve(await ticketService.getAddress(), 0);

    // selon votre implémentation ERC20, ce revert peut être une custom error.
    await expect(ticketService.connect(minter).mint_ticket(1n)).to.be.revertedWith(
      "ERC20: insufficient allowance"
    );
  });

  it("has_valid_ticket: expiré => false", async () => {
    const { ticketService, owner, minter } = await setup();
    const price = ethers.parseUnits("100", 18);
    const now = await time.latest();
    const expiration = now + 100n;

    await ticketService
      .connect(owner)
      .create_ip_asset(price, 1n, expiration, 500n, "ip://metadata");

    await ticketService.connect(minter).mint_ticket(1n);

    await time.increaseTo(Number(expiration + 1n));

    expect(await ticketService.has_valid_ticket(minter.address, 1n)).to.equal(false);
  });

  it("royaltyInfo: 5% du salePrice + receiver = owner", async () => {
    const { ticketService, owner, minter } = await setup();
    const price = ethers.parseUnits("100", 18);
    const now = await time.latest();
    const expiration = now + 1_000n;
    const royalty = 500n; // 5%

    await ticketService
      .connect(owner)
      .create_ip_asset(price, 1n, expiration, royalty, "ip://metadata");

    await ticketService.connect(minter).mint_ticket(1n);

    const salePrice = ethers.parseUnits("1000", 18);
    const [receiver, amount] = await ticketService.royaltyInfo(1n, salePrice);
    expect(receiver).to.equal(owner.address);
    expect(amount).to.equal((salePrice * 5n) / 100n);
  });

  it("deux IP assets et 2 tickets pour le même minter", async () => {
    const { ticketService, owner, minter } = await setup();
    const now = await time.latest();
    const expiration = now + 1_000n;

    await ticketService
      .connect(owner)
      .create_ip_asset(ethers.parseUnits("100", 18), 2n, expiration, 500n, "ip://metadata1");
    await ticketService
      .connect(owner)
      .create_ip_asset(ethers.parseUnits("200", 18), 2n, expiration, 500n, "ip://metadata2");

    await ticketService.connect(minter).mint_ticket(1n);
    await ticketService.connect(minter).mint_ticket(2n);

    expect(await ticketService.ownerOf(1n)).to.equal(minter.address);
    expect(await ticketService.ownerOf(2n)).to.equal(minter.address);
    expect(await ticketService.has_valid_ticket(minter.address, 1n)).to.equal(true);
    expect(await ticketService.has_valid_ticket(minter.address, 2n)).to.equal(true);
  });
});
