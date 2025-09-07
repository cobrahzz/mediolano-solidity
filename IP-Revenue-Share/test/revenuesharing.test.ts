import { expect } from "chai";
import { ethers } from "hardhat";

const REV_FQN  = "src/IPRevenueSharingSuite.sol:IPRevenueSharing";
const NFT_FQN  = "src/IPRevenueSharingSuite.sol:Mediolano";
const ERC20_FQN = "src/IPRevenueSharingSuite.sol:MockERC20";

const toB32 = (s: string) => ethers.encodeBytes32String(s);

async function deployMockERC721(baseUri: string) {
  const NFT = await ethers.getContractFactory(NFT_FQN);
  const nft = await NFT.deploy(baseUri);
  await nft.waitForDeployment();
  return nft;
}

async function deployMockERC20(name: string, symbol: string, initial: bigint, recipient: string) {
  const T = await ethers.getContractFactory(ERC20_FQN);
  const t = await T.deploy(name, symbol, initial, recipient);
  await t.waitForDeployment();
  return t;
}

async function deployRevenue(owner: string) {
  const R = await ethers.getContractFactory(REV_FQN);
  const r = await R.deploy(owner);
  await r.waitForDeployment();
  return r;
}

describe("IPRevenueSharing suite (Solidity port 1:1)", () => {
  it("test_revenue_contract_deployed", async () => {
    const [owner] = await ethers.getSigners();
    const revenue = await deployRevenue(owner.address);

    // en Cairo ils passent l'adresse du contrat (pas une monnaie) -> retourne 0
    const bal = await revenue.get_contract_balance(await revenue.getAddress());
    expect(await revenue.getAddress()).to.properAddress;
    expect(bal).to.equal(0n);
  });

  it("test_create_ip_asset", async () => {
    const [owner, alex] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);
    const tokenId = 1n;

    await nft.connect(owner).mint(alex.address, tokenId);

    await revenue.connect(alex).create_ip_asset(
      await nft.getAddress(),
      tokenId,
      toB32("metadata_hash"),
      toB32("license_terms"),
      100n
    );

    const shares = await revenue.get_fractional_shares(await nft.getAddress(), tokenId, alex.address);
    expect(shares).to.equal(100n);

    const count = await revenue.get_fractional_owner_count(await nft.getAddress(), tokenId);
    expect(count).to.equal(1n);

    const first = await revenue.get_fractional_owner(await nft.getAddress(), tokenId, 0);
    expect(first).to.equal(alex.address);
  });

  it("test_create_ip_asset_not_owner (revert)", async () => {
    const [owner, alex] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);
    const tokenId = 1n;
    await nft.connect(owner).mint(owner.address, tokenId);

    await expect(
      revenue.connect(alex).create_ip_asset(
        await nft.getAddress(),
        tokenId,
        toB32("metadata_hash"),
        toB32("license_terms"),
        100n
      )
    ).to.be.revertedWith("Not Token Owner");
  });

  it("test_list_ip_asset", async () => {
    const [owner, alex] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);
    const erc20 = await deployMockERC20("TestToken", "TTK", 10000n, owner.address);

    const tokenId = 1n;
    await nft.connect(owner).mint(alex.address, tokenId);

    await revenue.connect(alex).create_ip_asset(
      await nft.getAddress(),
      tokenId,
      toB32("metadata"),
      toB32("license"),
      100n
    );

    await nft.connect(alex).approve(await revenue.getAddress(), tokenId);

    await revenue.connect(alex).list_ip_asset(
      await nft.getAddress(),
      tokenId,
      1000n,
      await erc20.getAddress()
    );

    expect(await nft.getApproved(tokenId)).to.equal(await revenue.getAddress());
    expect(await nft.ownerOf(tokenId)).to.equal(alex.address);
  });

  it("test_list_ip_asset_no_approval (revert)", async () => {
    const [owner, alex] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);
    const erc20 = await deployMockERC20("TestToken", "TTK", 10000n, owner.address);

    const tokenId = 1n;
    await nft.connect(owner).mint(alex.address, tokenId);

    await revenue.connect(alex).create_ip_asset(
      await nft.getAddress(),
      tokenId,
      toB32("metadata"),
      toB32("license"),
      100n
    );

    await expect(
      revenue.connect(alex).list_ip_asset(
        await nft.getAddress(),
        tokenId,
        1000n,
        await erc20.getAddress()
      )
    ).to.be.revertedWith("Not approved for marketplace");
  });

  it("test_add_fractional_owner", async () => {
    const [owner, alex, bob] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);

    const tokenId = 1n;
    await nft.connect(owner).mint(alex.address, tokenId);

    await revenue.connect(alex).create_ip_asset(
      await nft.getAddress(),
      tokenId,
      toB32("metadata"),
      toB32("license"),
      100n
    );

    await revenue.connect(alex).add_fractional_owner(
      await nft.getAddress(), tokenId, bob.address
    );

    const count = await revenue.get_fractional_owner_count(await nft.getAddress(), tokenId);
    expect(count).to.equal(2n);

    const second = await revenue.get_fractional_owner(await nft.getAddress(), tokenId, 1);
    expect(second).to.equal(bob.address);
  });

  it("test_claim_before_sale (revert)", async () => {
    const [owner, alex, bob] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);
    const erc20 = await deployMockERC20("TestToken", "TTK", 10000n, owner.address);

    const tokenId = 1n;
    await nft.connect(owner).mint(alex.address, tokenId);

    await revenue.connect(alex).create_ip_asset(
      await nft.getAddress(),
      tokenId,
      toB32("metadata"),
      toB32("license"),
      100n
    );

    await nft.connect(alex).approve(await revenue.getAddress(), tokenId);

    await revenue.connect(alex).list_ip_asset(
      await nft.getAddress(), tokenId, 1000n, await erc20.getAddress()
    );

    await revenue.connect(alex).add_fractional_owner(await nft.getAddress(), tokenId, bob.address);
    await revenue.connect(alex).update_fractional_shares(
      await nft.getAddress(), tokenId, bob.address, 50n
    );

    await expect(
      revenue.connect(bob).claim_royalty(await nft.getAddress(), tokenId)
    ).to.be.revertedWith("No revenue to claim");
  });

  it("test_full_flow_list_sell_claim", async () => {
    const [owner, alex, bob] = await ethers.getSigners();
    const nft = await deployMockERC721("https://mediolano_uri.com");
    const revenue = await deployRevenue(owner.address);
    const erc20 = await deployMockERC20("TestToken", "TTK", 10000n, owner.address);

    const tokenId = 1n;
    await nft.connect(owner).mint(alex.address, tokenId);

    await revenue.connect(alex).create_ip_asset(
      await nft.getAddress(),
      tokenId,
      toB32("metadata"),
      toB32("license"),
      100n
    );

    await nft.connect(alex).approve(await revenue.getAddress(), tokenId);

    await revenue.connect(alex).list_ip_asset(
      await nft.getAddress(), tokenId, 1000n, await erc20.getAddress()
    );

    // ajouter Bob et redistribuer 50 parts depuis Alex -> Bob
    await revenue.connect(alex).add_fractional_owner(await nft.getAddress(), tokenId, bob.address);
    await revenue.connect(alex).update_fractional_shares(
      await nft.getAddress(), tokenId, bob.address, 50n
    );

    // Approve le contrat de revenus pour transferFrom(owner, nft, 1000)
    await erc20.connect(owner).approve(await revenue.getAddress(), 1000n);
    // Déposer aussi 1000 directement sur le contrat de revenus (pour que claim puisse payer)
    await erc20.connect(owner).transfer(await revenue.getAddress(), 1000n);

    // Owner enregistre la vente (augmente accrued_revenue et transferFrom owner -> NFT)
    await revenue.connect(owner).record_sale_revenue(await nft.getAddress(), tokenId, 1000n);

    expect(await erc20.balanceOf(await revenue.getAddress())).to.equal(1000n);

    // Alex réclame (50%)
    await revenue.connect(alex).claim_royalty(await nft.getAddress(), tokenId);
    const alexClaimed = await revenue.get_claimed_revenue(await nft.getAddress(), tokenId, alex.address);
    expect(alexClaimed).to.equal(500n);

    // Bob réclame (50%)
    await revenue.connect(bob).claim_royalty(await nft.getAddress(), tokenId);
    const bobClaimed = await revenue.get_claimed_revenue(await nft.getAddress(), tokenId, bob.address);
    expect(bobClaimed).to.equal(500n);

    // plus rien dans le contrat
    expect(await erc20.balanceOf(await revenue.getAddress())).to.equal(0n);
  });
});
