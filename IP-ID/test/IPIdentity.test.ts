import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const b32 = (n: number | bigint | string) => {
  if (typeof n === "string" && n.startsWith("0x")) return n;
  return ethers.toBeHex(BigInt(n), 32);
};

async function deployIPIdentity() {
  const [owner, nonOwner, user] = await ethers.getSigners();
  const IPIdentity = await ethers.getContractFactory("IPIdentity");
  const ip = await IPIdentity.deploy(
    owner.address,
    "IPIdentity",
    "IPID",
    "https://ipfs.io/ipfs/"
  );
  await ip.waitForDeployment();
  return { ip, owner, nonOwner, user };
}

async function registerDefault(ip: any, caller: any, ipIdNum = 123) {
  return ip
    .connect(caller)
    .register_ip_id(
      b32(ipIdNum),
      "ipfs://metadata",
      "image",
      "MIT",
      1, // collection_id
      250, // royalty_rate (2.5%)
      1000, // licensing_fee
      true, // commercial_use
      true, // derivative_works
      true, // attribution_required
      "ERC721", // metadata_standard
      "https://example.com", // external_url
      "art,digital", // tags
      "US" // jurisdiction
    );
}

describe("IPIdentity", () => {
  it("register_ip_id reverts if already registered", async () => {
    const { ip, user } = await deployIPIdentity();
    await expect(registerDefault(ip, user)).to.emit(ip, "IPIDRegistered");
    await expect(registerDefault(ip, user)).to.be.revertedWith(
      "IP ID already registered"
    );
  });

  it("update_ip_id_metadata success + timestamp", async () => {
    const { ip, user } = await deployIPIdentity();
    await registerDefault(ip, user);
    await time.setNextBlockTimestamp(2000);
    await expect(
      ip.connect(user).update_ip_id_metadata(b32(123), "ipfs://new_metadata")
    ).to.emit(ip, "IPIDMetadataUpdated");

    const data = await ip.get_ip_id_data(b32(123));
    expect(data.metadata_uri).to.eq("ipfs://new_metadata");
    expect(data.updated_at).to.eq(2000n);
  });

  it("update_ip_id_metadata reverts if not owner", async () => {
    const { ip, user, nonOwner } = await deployIPIdentity();
    await registerDefault(ip, user);
    await expect(
      ip
        .connect(nonOwner)
        .update_ip_id_metadata(b32(123), "ipfs://new_metadata")
    ).to.be.revertedWith("Caller is not the owner");
  });

  it("update_ip_id_metadata reverts on invalid ip id", async () => {
    const { ip, user } = await deployIPIdentity();
    await expect(
      ip.connect(user).update_ip_id_metadata(b32(123), "ipfs://new_metadata")
    ).to.be.revertedWith("Invalid IP ID");
  });

  it("verify_ip_id success (only contract owner) + timestamp", async () => {
    const { ip, owner, user } = await deployIPIdentity();
    await registerDefault(ip, user);
    await time.setNextBlockTimestamp(2000);
    await expect(ip.connect(owner).verify_ip_id(b32(123))).to.emit(
      ip,
      "IPIDVerified"
    );

    const data = await ip.get_ip_id_data(b32(123));
    expect(data.is_verified).to.eq(true);
    expect(data.updated_at).to.eq(2000n);
  });

  it("verify_ip_id reverts if caller not owner (Ownable)", async () => {
    const { ip, user } = await deployIPIdentity();
    await registerDefault(ip, user);
    await expect(ip.connect(user).verify_ip_id(b32(123))).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("verify_ip_id reverts on invalid ip id", async () => {
    const { ip, owner } = await deployIPIdentity();
    await expect(ip.connect(owner).verify_ip_id(b32(123))).to.be.revertedWith(
      "Invalid IP ID"
    );
  });

  it("get_ip_id_data reverts on invalid ip id", async () => {
    const { ip } = await deployIPIdentity();
    await expect(ip.get_ip_id_data(b32(999))).to.be.revertedWith(
      "Invalid IP ID"
    );
  });

  it("enhanced registration + utility getters", async () => {
    const { ip, user } = await deployIPIdentity();
    await registerDefault(ip, user);

    const d = await ip.get_ip_id_data(b32(123));
    expect(d.collection_id).to.eq(1n);
    expect(d.royalty_rate).to.eq(250n);
    expect(d.licensing_fee).to.eq(1000n);
    expect(d.commercial_use).to.eq(true);
    expect(d.derivative_works).to.eq(true);
    expect(d.attribution_required).to.eq(true);
    expect(d.metadata_standard).to.eq("ERC721");
    expect(d.external_url).to.eq("https://example.com");
    expect(d.tags).to.eq("art,digital");
    expect(d.jurisdiction).to.eq("US");

    expect(await ip.is_ip_id_registered(b32(123))).to.eq(true);
    expect(await ip.can_use_commercially(b32(123))).to.eq(true);
    expect(await ip.can_create_derivatives(b32(123))).to.eq(true);
    expect(await ip.requires_attribution(b32(123))).to.eq(true);
    expect(await ip.get_total_registered_ips()).to.eq(1n);
  });

  it("licensing update + read via getter tuple", async () => {
    const { ip, user } = await deployIPIdentity();
    await registerDefault(ip, user);

    await expect(
      ip
        .connect(user)
        .update_ip_id_licensing(
          b32(123),
          "Apache 2.0",
          500, // 5%
          2000,
          false,
          false,
          false
        )
    ).to.emit(ip, "IPIDLicensingUpdated");

    const [license, royalty, fee, commercial, derivatives, attribution] =
      await ip.get_ip_licensing_terms(b32(123));
    expect(license).to.eq("Apache 2.0");
    expect(royalty).to.eq(500n);
    expect(fee).to.eq(2000n);
    expect(commercial).to.eq(false);
    expect(derivatives).to.eq(false);
    expect(attribution).to.eq(false);
  });

  it("ownership transfer updates owner + indexes", async () => {
    const { ip, user, nonOwner } = await deployIPIdentity();
    await registerDefault(ip, user);

    expect(await ip.get_ip_owner(b32(123))).to.eq(user.address);

    await expect(
      ip.connect(user).transfer_ip_ownership(b32(123), nonOwner.address)
    ).to.emit(ip, "IPIDOwnershipTransferred");

    expect(await ip.get_ip_owner(b32(123))).to.eq(nonOwner.address);

    const userIPs = await ip.get_owner_ip_ids(user.address);
    const nonOwnerIPs = await ip.get_owner_ip_ids(nonOwner.address);
    expect(userIPs.length).to.eq(0);
    expect(nonOwnerIPs.length).to.eq(1);
    expect(nonOwnerIPs[0]).to.eq(b32(123));
  });

  it("batch queries: owner, collection, type, total", async () => {
    const { ip, user, nonOwner } = await deployIPIdentity();

    await ip
      .connect(user)
      .register_ip_id(
        b32(123),
        "ipfs://metadata1",
        "image",
        "MIT",
        1,
        250,
        1000,
        true,
        true,
        true,
        "ERC721",
        "https://example1.com",
        "art",
        "US"
      );
    await ip
      .connect(user)
      .register_ip_id(
        b32(124),
        "ipfs://metadata2",
        "video",
        "Apache",
        1,
        300,
        1500,
        false,
        true,
        false,
        "ERC721",
        "https://example2.com",
        "video",
        "EU"
      );
    await ip
      .connect(nonOwner)
      .register_ip_id(
        b32(125),
        "ipfs://metadata3",
        "image",
        "GPL",
        2,
        400,
        2000,
        true,
        false,
        true,
        "ERC1155",
        "https://example3.com",
        "art,nft",
        "UK"
      );

    const owner1IPs = await ip.get_owner_ip_ids(user.address);
    expect(owner1IPs.length).to.eq(2);

    const owner2IPs = await ip.get_owner_ip_ids(nonOwner.address);
    expect(owner2IPs.length).to.eq(1);

    const coll1 = await ip.get_ip_ids_by_collection(1);
    expect(coll1.length).to.eq(2);

    const coll2 = await ip.get_ip_ids_by_collection(2);
    expect(coll2.length).to.eq(1);

    const imageIPs = await ip.get_ip_ids_by_type("image");
    expect(imageIPs.length).to.eq(2);

    const videoIPs = await ip.get_ip_ids_by_type("video");
    expect(videoIPs.length).to.eq(1);

    expect(await ip.get_total_registered_ips()).to.eq(3n);

    // multiple data
    const arr = await ip.get_multiple_ip_data([b32(123), b32(124), b32(999)]);
    expect(arr.length).to.eq(2);
    expect(arr[0].metadata_uri).to.be.a("string");
  });

  it("verification workflow + paging", async () => {
    const { ip, owner, user } = await deployIPIdentity();

    await registerDefault(ip, user, 123);
    expect(await ip.is_ip_verified(b32(123))).to.eq(false);

    await ip.connect(owner).verify_ip_id(b32(123));
    expect(await ip.is_ip_verified(b32(123))).to.eq(true);

    // add another to test paging
    await ip
      .connect(user)
      .register_ip_id(
        b32(124),
        "ipfs://m2",
        "image",
        "MIT",
        1,
        250,
        1000,
        true,
        true,
        true,
        "ERC721",
        "https://ex.com",
        "art",
        "US"
      );
    await ip.connect(owner).verify_ip_id(b32(124));

    const all = await ip.get_verified_ip_ids(10, 0);
    expect(all.length).to.eq(2);

    const page1 = await ip.get_verified_ip_ids(1, 0);
    const page2 = await ip.get_verified_ip_ids(1, 1);
    expect(page1.length).to.eq(1);
    expect(page2.length).to.eq(1);
    expect(page1[0]).to.eq(b32(123));
    expect(page2[0]).to.eq(b32(124));
  });
});
