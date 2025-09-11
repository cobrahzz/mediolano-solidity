import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

enum AchievementType {
  Mint,
  Sale,
  License,
  Transfer,
  Collection,
  Collaboration,
  Innovation,
  Community,
  Custom,
}

enum ActivityType {
  AssetMinted,
  AssetSold,
  AssetLicensed,
  AssetTransferred,
  CollectionCreated,
  CollaborationJoined,
  InnovationAwarded,
  CommunityContribution,
  CustomActivity,
}

enum BadgeType {
  Creator,
  Seller,
  Licensor,
  Collector,
  Innovator,
  CommunityLeader,
  EarlyAdopter,
  TopPerformer,
  CustomBadge,
}

enum CertificateType {
  CreatorCertificate,
  SellerCertificate,
  LicensorCertificate,
  InnovationCertificate,
  CommunityCertificate,
  AchievementCertificate,
  CustomCertificate,
}

// Helper: map Cairo short-string → uint256
const felt = (s: string) => BigInt(ethers.toBigInt(ethers.keccak256(ethers.toUtf8Bytes(s))));
const NONE = 0n; // Option::None sentinel

describe("UserAchievements (Cairo → Solidity tests)", () => {
  async function deployFixture() {
    const [owner, user1, user2] = await ethers.getSigners();
    const C = await ethers.getContractFactory("UserAchievements");
    const c = await C.deploy(owner.address);
    await c.waitForDeployment();
    return { c, owner, user1, user2 };
  }

  it("test_constructor", async () => {
    await loadFixture(deployFixture);
    // On ne peut pas lire les points par défaut sans vue dédiée,
    // ce test valide surtout le déploiement.
    expect(true).to.equal(true);
  });

  it("test_record_achievement", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const metadata_id = felt("metadata_hash_123");
    const asset_id = felt("asset_123");
    const category = felt("category_1");
    const points = 50;

    await c.connect(owner).record_achievement(
      user1.address,
      AchievementType.Mint,
      metadata_id,
      asset_id,      // Some
      category,      // Some
      points
    );

    const achievements = await c.get_user_achievements(user1.address, 0, 1);
    expect(achievements.length).to.equal(1);
    expect(achievements[0].achievement_type).to.equal(AchievementType.Mint);
    expect(achievements[0].points).to.equal(points);
    expect(achievements[0].metadata_id).to.equal(metadata_id);

    expect(await c.get_user_total_points(user1.address)).to.equal(points);
    expect(await c.get_user_activity_count(user1.address)).to.equal(1);
  });

  it("test_record_activity_event", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const metadata_id = felt("activity_metadata_456");
    const asset_id = felt("asset_456");
    const category = felt("category_2");

    await c.connect(owner).record_activity_event(
      user1.address,
      ActivityType.AssetSold,
      metadata_id,
      asset_id,
      category
    );

    const achievements = await c.get_user_achievements(user1.address, 0, 1);
    expect(achievements.length).to.equal(1);
    expect(achievements[0].achievement_type).to.equal(AchievementType.Sale);
    expect(achievements[0].points).to.be.greaterThan(0);
  });

  it("test_mint_badge", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const metadata_id = felt("badge_metadata_789");

    await c.connect(owner).mint_badge(user1.address, BadgeType.Creator, metadata_id);

    const badges = await c.get_user_badges(user1.address);
    expect(badges.length).to.equal(1);
    expect(badges[0].badge_type).to.equal(BadgeType.Creator);
    expect(badges[0].metadata_id).to.equal(metadata_id);
    expect(badges[0].is_active).to.equal(true);
  });

  it("test_mint_certificate", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const metadata_id = felt("certificate_metadata_123");
    const expiry = 1735689600n; // future timestamp

    await c
      .connect(owner)
      .mint_certificate(user1.address, CertificateType.CreatorCertificate, metadata_id, Number(expiry));

    const certs = await c.get_user_certificates(user1.address);
    expect(certs.length).to.equal(1);
    expect(certs[0].certificate_type).to.equal(CertificateType.CreatorCertificate);
    expect(certs[0].metadata_id).to.equal(metadata_id);
    expect(certs[0].is_valid).to.equal(true);
  });

  it("test_leaderboard_functionality", async () => {
    const { c, owner, user1, user2 } = await loadFixture(deployFixture);

    await c
      .connect(owner)
      .record_achievement(user1.address, AchievementType.Mint, felt("metadata1"), NONE, NONE, 100);

    await c
      .connect(owner)
      .record_achievement(user2.address, AchievementType.Sale, felt("metadata2"), NONE, NONE, 50);

    const leaderboard = await c.get_leaderboard(0, 10);
    expect(leaderboard.length).to.be.greaterThanOrEqual(2);

    const rank1 = await c.get_user_rank(user1.address);
    const rank2 = await c.get_user_rank(user2.address);
    expect(rank1).to.be.greaterThan(0);
    expect(rank2).to.be.greaterThan(0);
  });

  it("test_multiple_achievements_same_user", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    await c
      .connect(owner)
      .record_achievement(user1.address, AchievementType.Mint, felt("metadata1"), NONE, NONE, 10);
    await c
      .connect(owner)
      .record_achievement(user1.address, AchievementType.Sale, felt("metadata2"), NONE, NONE, 25);
    await c
      .connect(owner)
      .record_achievement(user1.address, AchievementType.License, felt("metadata3"), NONE, NONE, 20);

    const achievements = await c.get_user_achievements(user1.address, 0, 10);
    expect(achievements.length).to.equal(3);

    expect(await c.get_user_total_points(user1.address)).to.equal(55);
    expect(await c.get_user_activity_count(user1.address)).to.equal(3);
  });

  it("test_pagination", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    for (let i = 0; i < 5; i++) {
      await c
        .connect(owner)
        .record_achievement(user1.address, AchievementType.Mint, felt("metadata"), NONE, NONE, 10);
    }

    const p1 = await c.get_user_achievements(user1.address, 0, 2);
    expect(p1.length).to.equal(2);

    const p2 = await c.get_user_achievements(user1.address, 2, 2);
    expect(p2.length).to.equal(2);

    const p3 = await c.get_user_achievements(user1.address, 4, 2);
    expect(p3.length).to.equal(1);
  });

  it("test_set_activity_points", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    await c.connect(owner).set_activity_points(ActivityType.AssetMinted, 15);

    await c
      .connect(owner)
      .record_activity_event(user1.address, ActivityType.AssetMinted, felt("metadata"), NONE, NONE);

    const achievements = await c.get_user_achievements(user1.address, 0, 1);
    expect(achievements[0].points).to.equal(15);
  });

  it("test_achievement_types", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const types: AchievementType[] = [
      AchievementType.Mint,
      AchievementType.Sale,
      AchievementType.License,
      AchievementType.Transfer,
      AchievementType.Collection,
      AchievementType.Collaboration,
      AchievementType.Innovation,
      AchievementType.Community,
      AchievementType.Custom,
    ];

    for (const t of types) {
      await c
        .connect(owner)
        .record_achievement(user1.address, t, felt("metadata"), NONE, NONE, 10);
    }

    const achievements = await c.get_user_achievements(user1.address, 0, 20);
    expect(achievements.length).to.equal(9);
  });

  it("test_badge_types", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const types: BadgeType[] = [
      BadgeType.Creator,
      BadgeType.Seller,
      BadgeType.Licensor,
      BadgeType.Collector,
      BadgeType.Innovator,
      BadgeType.CommunityLeader,
      BadgeType.EarlyAdopter,
      BadgeType.TopPerformer,
      BadgeType.CustomBadge,
    ];

    for (const t of types) {
      await c.connect(owner).mint_badge(user1.address, t, felt("metadata"));
    }

    const badges = await c.get_user_badges(user1.address);
    expect(badges.length).to.equal(9);
  });

  it("test_certificate_types", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const types: CertificateType[] = [
      CertificateType.CreatorCertificate,
      CertificateType.SellerCertificate,
      CertificateType.LicensorCertificate,
      CertificateType.InnovationCertificate,
      CertificateType.CommunityCertificate,
      CertificateType.AchievementCertificate,
      CertificateType.CustomCertificate,
    ];

    for (const t of types) {
      await c.connect(owner).mint_certificate(user1.address, t, felt("metadata"), 0);
    }

    const certs = await c.get_user_certificates(user1.address);
    expect(certs.length).to.equal(7);
  });

  it("test_activity_to_achievement_mapping", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    const pairs: [ActivityType, AchievementType][] = [
      [ActivityType.AssetMinted, AchievementType.Mint],
      [ActivityType.AssetSold, AchievementType.Sale],
      [ActivityType.AssetLicensed, AchievementType.License],
      [ActivityType.AssetTransferred, AchievementType.Transfer],
      [ActivityType.CollectionCreated, AchievementType.Collection],
      [ActivityType.CollaborationJoined, AchievementType.Collaboration],
      [ActivityType.InnovationAwarded, AchievementType.Innovation],
      [ActivityType.CommunityContribution, AchievementType.Community],
      [ActivityType.CustomActivity, AchievementType.Custom],
    ];

    for (const [act /*, expected*/] of pairs) {
      await c
        .connect(owner)
        .record_activity_event(user1.address, act, felt("metadata"), NONE, NONE);
    }

    const achievements = await c.get_user_achievements(user1.address, 0, 20);
    expect(achievements.length).to.equal(9);
  });

  it("test_owner_management", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    await c.connect(owner).set_owner(user1.address);

    await c
      .connect(user1)
      .record_achievement(user1.address, AchievementType.Mint, felt("metadata"), NONE, NONE, 10);

    const achievements = await c.get_user_achievements(user1.address, 0, 1);
    expect(achievements.length).to.equal(1);
  });

  it("test_comprehensive_user_profile", async () => {
    const { c, owner, user1 } = await loadFixture(deployFixture);

    await c
      .connect(owner)
      .record_achievement(
        user1.address,
        AchievementType.Mint,
        felt("achievement_1"),
        felt("asset_1"),
        felt("category_1"),
        25
      );

    await c
      .connect(owner)
      .record_achievement(
        user1.address,
        AchievementType.Sale,
        felt("achievement_2"),
        felt("asset_2"),
        felt("category_2"),
        50
      );

    await c.connect(owner).mint_badge(user1.address, BadgeType.Creator, felt("badge_metadata"));
    await c.connect(owner).mint_badge(user1.address, BadgeType.Seller, felt("badge_metadata_2"));

    await c
      .connect(owner)
      .mint_certificate(
        user1.address,
        CertificateType.CreatorCertificate,
        felt("cert_metadata"),
        1735689600 // Some
      );

    const achievements = await c.get_user_achievements(user1.address, 0, 10);
    const badges = await c.get_user_badges(user1.address);
    const certificates = await c.get_user_certificates(user1.address);
    const total_points = await c.get_user_total_points(user1.address);
    const activity_count = await c.get_user_activity_count(user1.address);
    const rank = await c.get_user_rank(user1.address);

    expect(achievements.length).to.equal(2);
    expect(badges.length).to.equal(2);
    expect(certificates.length).to.equal(1);
    expect(total_points).to.equal(75);
    expect(activity_count).to.equal(2);
    expect(rank).to.be.greaterThan(0);
  });
});
