import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

// Helpers to build the Solidity structs easily
const personalInfo = (
  username: string,
  name_: string,
  bio: string,
  location: string,
  email: string,
  phone: string,
  org: string,
  website: string
) => ({
  username,
  name_,
  bio,
  location,
  email,
  phone,
  org,
  website,
});

const socialLinks = (
  x_handle: string,
  linkedin: string,
  instagram: string,
  tiktok: string,
  facebook: string,
  discord: string,
  youtube: string,
  github: string
) => ({
  x_handle,
  linkedin,
  instagram,
  tiktok,
  facebook,
  discord,
  youtube,
  github,
});

const profileSettings = (
  display_public_profile: boolean,
  email_notifications: boolean,
  marketplace_profile: boolean
) => ({
  display_public_profile,
  email_notifications,
  marketplace_profile,
});

function samplePersonalInfo() {
  return personalInfo(
    "alice_dev",
    "Alice Developer",
    "Full-stack developer passionate about blockchain",
    "San Francisco, CA",
    "alice@example.com",
    "+1-555-0123",
    "TechCorp Inc.",
    "https://alice.dev"
  );
}

function sampleSocialLinks() {
  return socialLinks(
    "@alice_dev",
    "linkedin.com/in/alice-dev",
    "@alice.codes",
    "@alice_codes",
    "alice.developer",
    "alice_dev#1234",
    "@AliceDev",
    "github.com/alice-dev"
  );
}

function sampleSettings() {
  return profileSettings(true, true, true);
}

describe("UserPublicProfile (Cairo → Solidity)", () => {
  async function deployFixture() {
    const [deployer, user1, user2] = await ethers.getSigners();
    const C = await ethers.getContractFactory("UserPublicProfile");
    const c = await C.deploy();
    await c.waitForDeployment();
    return { c, deployer, user1, user2 };
  }

  it("test_register_profile", async () => {
    const { c, user1, deployer } = await loadFixture(deployFixture);

    // register as user1 (caller = user1)
    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      sampleSettings()
    );

    // is_profile_registered
    expect(await c.is_profile_registered(user1.address)).to.equal(true);

    // profile_count
    expect(await c.get_profile_count()).to.equal(1);

    // get_username (public profile → callable by anyone, e.g. deployer)
    expect(await c.connect(deployer).get_username(user1.address)).to.equal("alice_dev");

    // is_profile_public
    expect(await c.is_profile_public(user1.address)).to.equal(true);
  });

  it("test_get_profile_components", async () => {
    const { c, user1 } = await loadFixture(deployFixture);

    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      sampleSettings()
    );

    // get_personal_info (caller must be owner or profile public — owner here)
    const p = await c.connect(user1).get_personal_info(user1.address);
    expect(p.username).to.equal("alice_dev");
    expect(p.name_).to.equal("Alice Developer");
    expect(p.email).to.equal("alice@example.com");

    // get_social_links
    const s = await c.connect(user1).get_social_links(user1.address);
    expect(s.x_handle).to.equal("@alice_dev");
    expect(s.github).to.equal("github.com/alice-dev");

    // get_settings (only owner may call with `user == msg.sender`)
    const set = await c.connect(user1).get_settings(user1.address);
    expect(set.display_public_profile).to.equal(true);
    expect(set.email_notifications).to.equal(true);
    expect(set.marketplace_profile).to.equal(true);
  });

  it("test_update_personal_info", async () => {
    const { c, user1 } = await loadFixture(deployFixture);

    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      sampleSettings()
    );

    const updatedPersonal = personalInfo(
      "alice_senior_dev",
      "Alice Senior Developer",
      "Senior full-stack developer and blockchain expert",
      "New York, NY",
      "alice.senior@example.com",
      "+1-555-9999",
      "BlockchainCorp",
      "https://alicesenior.dev"
    );

    await c.connect(user1).update_personal_info(updatedPersonal);

    const got = await c.connect(user1).get_personal_info(user1.address);
    expect(got.username).to.equal("alice_senior_dev");
    expect(got.name_).to.equal("Alice Senior Developer");
    expect(got.location).to.equal("New York, NY");
  });

  it("test_update_social_links", async () => {
    const { c, user1 } = await loadFixture(deployFixture);

    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      sampleSettings()
    );

    const updatedSocial = socialLinks(
      "@alice_senior",
      "linkedin.com/in/alice-senior-dev",
      "@alice.senior.codes",
      "@alice_senior_codes",
      "alice.senior.developer",
      "alice_senior#5678",
      "@AliceSeniorDev",
      "github.com/alice-senior-dev"
    );

    await c.connect(user1).update_social_links(updatedSocial);

    const got = await c.connect(user1).get_social_links(user1.address);
    expect(got.x_handle).to.equal("@alice_senior");
    expect(got.github).to.equal("github.com/alice-senior-dev");
  });

  it("test_update_settings", async () => {
    const { c, user1 } = await loadFixture(deployFixture);

    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      sampleSettings()
    );

    const updated = profileSettings(false, false, true);
    await c.connect(user1).update_settings(updated);

    const set = await c.connect(user1).get_settings(user1.address);
    expect(set.display_public_profile).to.equal(false);
    expect(set.email_notifications).to.equal(false);
    expect(set.marketplace_profile).to.equal(true);

    // profile is now private
    expect(await c.is_profile_public(user1.address)).to.equal(false);
  });

  it("test_privacy_controls", async () => {
    const { c, user1, user2 } = await loadFixture(deployFixture);

    // user1 registers PRIVATE profile
    const privateSettings = profileSettings(false, true, true);
    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      privateSettings
    );

    // user1 can access own info
    const own = await c.connect(user1).get_personal_info(user1.address);
    expect(own.username).to.equal("alice_dev");

    // user2 can check flags but can't read details (we don't call getters that would revert)
    expect(await c.is_profile_registered(user1.address)).to.equal(true);
    expect(await c.is_profile_public(user1.address)).to.equal(false);
  });

  it("test_multiple_users", async () => {
    const { c, user1, user2 } = await loadFixture(deployFixture);

    // user1 registers
    await c.connect(user1).register_profile(
      samplePersonalInfo(),
      sampleSocialLinks(),
      sampleSettings()
    );

    // user2 registers with its own data
    const user2Personal = personalInfo(
      "bob_designer",
      "Bob Designer",
      "UI/UX Designer specializing in Web3",
      "Austin, TX",
      "bob@example.com",
      "+1-555-0456",
      "DesignStudio",
      "https://bob.design"
    );
    await c.connect(user2).register_profile(
      user2Personal,
      sampleSocialLinks(),
      sampleSettings()
    );

    expect(await c.is_profile_registered(user1.address)).to.equal(true);
    expect(await c.is_profile_registered(user2.address)).to.equal(true);
    expect(await c.get_profile_count()).to.equal(2);

    // user1 can access user2's public profile
    const user2Info = await c.connect(user1).get_personal_info(user2.address);
    expect(user2Info.username).to.equal("bob_designer");
  });
});
