import { expect } from "chai";
import { ethers } from "hardhat";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";

describe("MIPListing", () => {
  async function deployAll() {
    const [owner, lister, someoneElse] = await ethers.getSigners();

    // Marketplace mock
    const MarketplaceMock = await ethers.getContractFactory("MarketplaceMock");
    const marketplace = await MarketplaceMock.deploy();
    await marketplace.waitForDeployment();

    // ERC721 mock
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    const nft = await MockERC721.deploy("Mock", "MOCK");
    await nft.waitForDeployment();

    // MIPListing
    const MIPListing = await ethers.getContractFactory("MIPListing");
    const listing = await MIPListing.deploy(owner.address, await marketplace.getAddress());
    await listing.waitForDeployment();

    return {
      owner,
      lister,
      someoneElse,
      marketplace,
      nft,
      listing,
    };
  }

  it("onlyOwner: update_ip_marketplace_address", async () => {
    const { listing, owner, someoneElse } = await deployAll();

    await expect(
      listing.connect(someoneElse).update_ip_marketplace_address(await someoneElse.getAddress())
    ).to.be.revertedWithCustomError(listing, "OwnableUnauthorizedAccount");

    await expect(listing.connect(owner).update_ip_marketplace_address(await someoneElse.getAddress()))
      .to.emit(listing, "IPMarketplaceUpdated")
      .withArgs(await someoneElse.getAddress(), anyValue);
  });

  it("revert: assetContractAddress == 0", async () => {
    const { listing, lister } = await deployAll();

    await expect(
      listing.connect(lister).create_listing(
        ethers.ZeroAddress,
        1n,
        0n,
        0n,
        1n,
        ethers.ZeroAddress,
        0n,
        0n
      )
    ).to.be.revertedWith("invalid ip asset");
  });

  it("revert: INVALID_IP_ASSET (token inexistant)", async () => {
    const { listing, nft, lister } = await deployAll();

    await expect(
      listing.connect(lister).create_listing(
        await nft.getAddress(),
        999n, // non minté
        0n,
        0n,
        1n,
        ethers.ZeroAddress,
        0n,
        0n
      )
    ).to.be.revertedWith("invalid ip asset");
  });

  it("revert: NOT_OWNER", async () => {
    const { listing, nft, lister, someoneElse } = await deployAll();

    // Mint au lister
    await nft.connect(lister).mint(await lister.getAddress(), 1n);

    await expect(
      listing.connect(someoneElse).create_listing(
        await nft.getAddress(),
        1n,
        0n,
        0n,
        1n,
        ethers.ZeroAddress,
        0n,
        0n
      )
    ).to.be.revertedWith("Caller not asset owner");
  });

  it("revert: NOT_APPROVED (isApprovedForAll == false)", async () => {
    const { listing, nft, lister } = await deployAll();

    await nft.connect(lister).mint(await lister.getAddress(), 1n);

    await expect(
      listing.connect(lister).create_listing(
        await nft.getAddress(),
        1n,
        0n,
        0n,
        1n,
        ethers.ZeroAddress,
        0n,
        0n
      )
    ).to.be.revertedWith("ip asset not approved by owner");
  });

  it("happy path: create_listing forward vers marketplace + event", async () => {
    const { listing, nft, lister, marketplace } = await deployAll();

    // Mint & approval
    await nft.connect(lister).mint(await lister.getAddress(), 1n);
    await nft.connect(lister).setApprovalForAll(await listing.getAddress(), true);

    const startTime = 1000n;
    const secondsUntilEndTime = 3600n;
    const quantityToList = 1n;
    const currency = ethers.ZeroAddress;
    const buyout = 12345n;
    const tokenType = 0n;

    // Appel
    await expect(
      listing.connect(lister).create_listing(
        await nft.getAddress(),
        1n,
        startTime,
        secondsUntilEndTime,
        quantityToList,
        currency,
        buyout,
        tokenType
      )
    )
      .to.emit(listing, "ListingCreated")
      .withArgs(1n, await lister.getAddress(), anyValue);

    // Vérifications côté mock marketplace
    expect(await marketplace.createListingCalled()).to.eq(true);
    expect(await marketplace.lastAssetContract()).to.eq(await nft.getAddress());
    expect(await marketplace.lastTokenId()).to.eq(1n);
    expect(await marketplace.lastStartTime()).to.eq(startTime);
    expect(await marketplace.lastSecondsUntilEndTime()).to.eq(secondsUntilEndTime);
    expect(await marketplace.lastQuantityToList()).to.eq(quantityToList);
    expect(await marketplace.lastCurrencyToAccept()).to.eq(currency);
    expect(await marketplace.lastBuyoutPricePerToken()).to.eq(buyout);
    expect(await marketplace.lastTokenTypeOfListing()).to.eq(tokenType);
  });
});
