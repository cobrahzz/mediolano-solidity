import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("IPMarketplace::list_item", () => {
  it("lists an item and stores the full Listing struct", async () => {
    const [deployer, user] = await ethers.getSigners();

    // 1) Deploy marketplace (1% fee => 100 bps)
    const Marketplace = await ethers.getContractFactory("IPMarketplace");
    const marketplace = await Marketplace.deploy(100);
    await marketplace.waitForDeployment();

    // 2) Deploy mocks
    const ERC721 = await ethers.getContractFactory("MockERC721");
    const nft = await ERC721.deploy("MIP", "MIP");
    await nft.waitForDeployment();

    const ERC20 = await ethers.getContractFactory("MockERC20");
    const currency = await ERC20.deploy("STRK", "STRK");
    await currency.waitForDeployment();

    // 3) Mint NFT to user (tokenId = 1)
    const tokenId = 1n;
    await nft.connect(deployer).mintTo(user.address, tokenId);

    // 4) Approve marketplace for transfers (like isApprovedForAll in Cairo test)
    await nft.connect(user).setApprovalForAll(await marketplace.getAddress(), true);

    // 5) Prepare inputs (bytes32 hashes derived from strings)
    const mintUrl = "QmfVMAmNM1kDEBYrC2TPzQDoCRFH6F5tE1e9Mr4FkkR5Xr";
    const licenseUrl = "bafkreibryabifvypyx7gleiqztaj3fkkyalqiaahn3ewvmrm6zoi3bnqdu";

    const metadataHash = ethers.keccak256(ethers.toUtf8Bytes(mintUrl));
    const licenseHash = ethers.keccak256(ethers.toUtf8Bytes(licenseUrl));

    // Structs
    const usage_rights = {
      commercial_use: true,
      modifications_allowed: true,
      attribution_required: true,
      geographic_restrictions: ethers.toBeHex(1, 32), // bytes32
      usage_duration: 2,
      sublicensing_allowed: true,
      industry_restrictions: ethers.toBeHex(3, 32), // bytes32
    };

    const derivative_rights = {
      allowed: true,
      royalty_share: 4,
      requires_approval: true,
      max_derivatives: 5,
    };

    const price = 1000n;

    // 6) Fix the block timestamp to 10 like in your cairo test
    await time.setNextBlockTimestamp(10);

    // 7) Call list_item
    await expect(
      marketplace.connect(user).list_item(
        await nft.getAddress(),
        tokenId,
        price,
        await currency.getAddress(),
        metadataHash,
        licenseHash,
        usage_rights,
        derivative_rights
      )
    ).to.emit(marketplace, "ItemListed");

    // 8) Read listing back and assert fields
    const listing = await marketplace.get_listing(await nft.getAddress(), tokenId);

    expect(listing.seller).to.equal(user.address);
    expect(listing.nft_contract).to.equal(await nft.getAddress());
    expect(listing.price).to.equal(price);
    expect(listing.currency).to.equal(await currency.getAddress());
    expect(listing.active).to.equal(true);

    // metadata
    expect(listing.metadata.ipfs_hash).to.equal(metadataHash);
    expect(listing.metadata.license_terms).to.equal(licenseHash);
    expect(listing.metadata.creator).to.equal(user.address);
    expect(listing.metadata.creation_date).to.equal(10);
    expect(listing.metadata.last_updated).to.equal(10);
    expect(listing.metadata.version).to.equal(1);
    expect(listing.metadata.content_type).to.equal(ethers.ZeroHash);
    expect(listing.metadata.derivative_of).to.equal(0);

    // rights
    expect(listing.royalty_percentage).to.equal(250);
    expect(listing.usage_rights.commercial_use).to.equal(true);
    expect(listing.usage_rights.modifications_allowed).to.equal(true);
    expect(listing.usage_rights.attribution_required).to.equal(true);
    expect(listing.usage_rights.geographic_restrictions).to.equal(ethers.toBeHex(1, 32));
    expect(listing.usage_rights.usage_duration).to.equal(2);
    expect(listing.usage_rights.sublicensing_allowed).to.equal(true);
    expect(listing.usage_rights.industry_restrictions).to.equal(ethers.toBeHex(3, 32));

    expect(listing.derivative_rights.allowed).to.equal(true);
    expect(listing.derivative_rights.royalty_share).to.equal(4);
    expect(listing.derivative_rights.requires_approval).to.equal(true);
    expect(listing.derivative_rights.max_derivatives).to.equal(5);

    expect(listing.minimum_purchase_duration).to.equal(0);
    expect(listing.bulk_discount_rate).to.equal(0);
  });
});
