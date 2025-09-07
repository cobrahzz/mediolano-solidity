import { expect } from "chai";
import { ethers } from "hardhat";

const FQN = "src/IPSponsorship.sol:IPSponsorship";

// helper: Cairo felt252 string → uint256 (bytes32)
const toU256 = (s: string) => BigInt(ethers.encodeBytes32String(s));

// time helpers
async function setNextBlockTimestamp(ts: number) {
  await ethers.provider.send("evm_setNextBlockTimestamp", [ts]);
  await ethers.provider.send("evm_mine", []);
}

describe("IPSponsorship (Cairo → Solidity port tests)", () => {
  async function deploy() {
    const [admin, ipAuthor, sponsor1, sponsor2] = await ethers.getSigners();
    const C = await ethers.getContractFactory(FQN);
    const c = await C.deploy(admin.address);
    await c.waitForDeployment();
    return { c, admin, ipAuthor, sponsor1, sponsor2 };
  }

  it("test_deploy", async () => {
    await deploy();
  });

  it("test_register_ip", async () => {
    const { c, ipAuthor } = await deploy();

    const metadata = toU256("ipfs://metadata_hash");
    const license = toU256("standard_license_v1");

    const tx = await c.connect(ipAuthor).register_ip(metadata, license);
    const receipt = await tx.wait();
    // function returns ip_id; grab via static call for assertion
    const ip_id = await c.connect(ipAuthor).register_ip.staticCall(metadata, license).catch(() => 2n) - 1n; // not ideal
    // plus fiable: relire détails de l’IP 1
    const [owner, returned_metadata, returned_license, active] = await c.get_ip_details(1n);

    expect(owner).to.equal(ipAuthor.address);
    expect(returned_metadata).to.equal(metadata);
    expect(returned_license).to.equal(license);
    expect(active).to.equal(true);
  });

  it("test_update_ip_metadata", async () => {
    const { c, ipAuthor } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("original_metadata"), toU256("license_v1"));
    await c.connect(ipAuthor).update_ip_metadata(ip_id, toU256("updated_metadata"));

    const [, returned_metadata] = await c.get_ip_details(ip_id);
    expect(returned_metadata).to.equal(toU256("updated_metadata"));
  });

  it("test_update_ip_metadata_unauthorized (revert)", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    await expect(
      c.connect(sponsor1).update_ip_metadata(ip_id, toU256("new_metadata"))
    ).to.be.revertedWith("Only IP owner can update");
  });

  it("test_create_sponsorship_offer", async () => {
    const { c, ipAuthor } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));

    const min = 100n, max = 1000n, duration = 3600;
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, min, max, duration, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, min, max, duration, ethers.ZeroAddress);

    expect(offer_id).to.equal(1n);

    const [ret_ip, ret_min, ret_max, ret_dur, author, active, specific] =
      await c.get_sponsorship_offer(offer_id);

    expect(ret_ip).to.equal(ip_id);
    expect(ret_min).to.equal(min);
    expect(ret_max).to.equal(max);
    expect(ret_dur).to.equal(duration);
    expect(author).to.equal(ipAuthor.address);
    expect(active).to.equal(true);
    expect(specific).to.equal(ethers.ZeroAddress);
  });

  it("test_create_specific_sponsor_offer", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, sponsor1.address);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, sponsor1.address);

    const [, , , , , , specific] = await c.get_sponsorship_offer(offer_id);
    expect(specific).to.equal(sponsor1.address);
  });

  it("test_create_offer_unauthorized (revert)", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    await expect(
      c.connect(sponsor1).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress)
    ).to.be.revertedWith("Only IP owner can create offers");
  });

  it("test_create_offer_invalid_price_range (revert)", async () => {
    const { c, ipAuthor } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    await expect(
      c.connect(ipAuthor).create_sponsorship_offer(ip_id, 1000n, 100n, 3600, ethers.ZeroAddress)
    ).to.be.revertedWith("Invalid price range");
  });

  it("test_sponsor_ip", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(sponsor1).sponsor_ip(offer_id, 500n);

    const [sponsors, amounts] = await c.get_sponsorship_bids(offer_id);
    expect(sponsors.length).to.equal(1);
    expect(sponsors[0]).to.equal(sponsor1.address);
    expect(amounts[0]).to.equal(500n);
  });

  it("test_sponsor_ip_bid_too_low (revert)", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;
    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await expect(
      c.connect(sponsor1).sponsor_ip(offer_id, 50n)
    ).to.be.revertedWith("Bid below minimum price");
  });

  it("test_sponsor_ip_bid_too_high (revert)", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;
    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await expect(
      c.connect(sponsor1).sponsor_ip(offer_id, 1500n)
    ).to.be.revertedWith("Bid above maximum price");
  });

  it("test_sponsor_ip_specific_sponsor_unauthorized (revert)", async () => {
    const { c, ipAuthor, sponsor1, sponsor2 } = await deploy();
    const ip_id = 1n;
    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, sponsor1.address);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, sponsor1.address);

    await expect(
      c.connect(sponsor2).sponsor_ip(offer_id, 500n)
    ).to.be.revertedWith("Not authorized to sponsor");
  });

  it("test_accept_sponsorship", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(sponsor1).sponsor_ip(offer_id, 500n);

    await setNextBlockTimestamp(1000);
    await c.connect(ipAuthor).accept_sponsorship(offer_id, sponsor1.address);

    const [, , , , , active] = await c.get_sponsorship_offer(offer_id);
    expect(active).to.equal(false);

    const userLicenses = await c.get_user_licenses(sponsor1.address);
    expect(userLicenses.length).to.equal(1);
    const license_id = userLicenses[0];

    expect(await c.is_license_valid(license_id)).to.equal(true);
  });

  it("test_accept_sponsorship_unauthorized (revert)", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(sponsor1).sponsor_ip(offer_id, 500n);

    await expect(
      c.connect(sponsor1).accept_sponsorship(offer_id, sponsor1.address)
    ).to.be.revertedWith("Only offer author can accept");
  });

  it("test_cancel_sponsorship_offer", async () => {
    const { c, ipAuthor } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(ipAuthor).cancel_sponsorship_offer(offer_id);

    const [, , , , , active] = await c.get_sponsorship_offer(offer_id);
    expect(active).to.equal(false);
  });

  it("test_update_sponsorship_offer", async () => {
    const { c, ipAuthor } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(ipAuthor).update_sponsorship_offer(offer_id, 200n, 2000n);

    const [, retMin, retMax] = await c.get_sponsorship_offer(offer_id);
    expect(retMin).to.equal(200n);
    expect(retMax).to.equal(2000n);
  });

  it("test_transfer_license", async () => {
    const { c, ipAuthor, sponsor1, sponsor2 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(sponsor1).sponsor_ip(offer_id, 500n);
    await setNextBlockTimestamp(1000);
    await c.connect(ipAuthor).accept_sponsorship(offer_id, sponsor1.address);

    const userLicenses = await c.get_user_licenses(sponsor1.address);
    const license_id = userLicenses[0];

    await c.connect(sponsor1).transfer_license(license_id, sponsor2.address);

    const newLicenses = await c.get_user_licenses(sponsor2.address);
    expect(newLicenses.length).to.equal(1);
    expect(newLicenses[0]).to.equal(license_id);
  });

  it("test_revoke_license", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(sponsor1).sponsor_ip(offer_id, 500n);
    await setNextBlockTimestamp(1000);
    await c.connect(ipAuthor).accept_sponsorship(offer_id, sponsor1.address);

    const userLicenses = await c.get_user_licenses(sponsor1.address);
    const license_id = userLicenses[0];

    await c.connect(ipAuthor).revoke_license(license_id);
    expect(await c.is_license_valid(license_id)).to.equal(false);
  });

  it("test_get_active_offers", async () => {
    const { c, ipAuthor } = await deploy();

    const ip1 = await c.connect(ipAuthor).register_ip.staticCall(toU256("metadata1"), toU256("license1"));
    await c.connect(ipAuthor).register_ip(toU256("metadata1"), toU256("license1"));

    const ip2 = await c.connect(ipAuthor).register_ip.staticCall(toU256("metadata2"), toU256("license2"));
    await c.connect(ipAuthor).register_ip(toU256("metadata2"), toU256("license2"));

    const offer1 = await c.connect(ipAuthor).create_sponsorship_offer.staticCall(ip1, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip1, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(ipAuthor).create_sponsorship_offer(ip2, 200n, 2000n, 7200, ethers.ZeroAddress);

    let active = await c.get_active_offers();
    expect(active.length).to.equal(2);

    await c.connect(ipAuthor).cancel_sponsorship_offer(offer1);
    active = await c.get_active_offers();
    expect(active.length).to.equal(1);
  });

  it("test_multiple_bids_on_offer", async () => {
    const { c, ipAuthor, sponsor1, sponsor2 } = await deploy();
    const ip_id = 1n;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, 3600, ethers.ZeroAddress);

    await c.connect(sponsor1).sponsor_ip(offer_id, 300n);
    await c.connect(sponsor2).sponsor_ip(offer_id, 600n);

    const [sponsors, amounts] = await c.get_sponsorship_bids(offer_id);
    expect(sponsors.length).to.equal(2);
    expect(sponsors[0]).to.equal(sponsor1.address);
    expect(amounts[0]).to.equal(300n);
    expect(sponsors[1]).to.equal(sponsor2.address);
    expect(amounts[1]).to.equal(600n);
  });

  it("test_license_expiry", async () => {
    const { c, ipAuthor, sponsor1 } = await deploy();
    const ip_id = 1n;
    const duration = 3600;

    await c.connect(ipAuthor).register_ip(toU256("metadata"), toU256("license"));
    const offer_id = await c.connect(ipAuthor).create_sponsorship_offer
      .staticCall(ip_id, 100n, 1000n, duration, ethers.ZeroAddress);
    await c.connect(ipAuthor).create_sponsorship_offer(ip_id, 100n, 1000n, duration, ethers.ZeroAddress);

    await c.connect(sponsor1).sponsor_ip(offer_id, 500n);
    await setNextBlockTimestamp(1000);
    await c.connect(ipAuthor).accept_sponsorship(offer_id, sponsor1.address);

    const license_id = (await c.get_user_licenses(sponsor1.address))[0];

    expect(await c.is_license_valid(license_id)).to.equal(true);

    await setNextBlockTimestamp(1000 + duration + 1);
    expect(await c.is_license_valid(license_id)).to.equal(false);
  });
});
