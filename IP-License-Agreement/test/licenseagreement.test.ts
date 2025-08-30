import { expect } from "chai";
import { ethers } from "hardhat";

describe("IP Licensing (monolithic)", function () {
  async function deployFactory() {
    const [deployer, s1, s2, stranger] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("IPLicensingFactory");
    const factory = await Factory.deploy(deployer.address, ethers.ZeroHash);
    await factory.waitForDeployment();
    return { factory, deployer, s1, s2, stranger };
  }

  async function createAgreement(factory: any, creatorSigner: any, signers: string[]) {
    const tx = await factory.connect(creatorSigner).create_agreement(
      "My Title",
      "My Description",
      "ip://meta",
      signers
    );
    const receipt = await tx.wait();

    // Parse AgreementCreated event to get id + address
    const iface = factory.interface;
    let agreementId: bigint | null = null;
    let agreementAddr: string | null = null;

    for (const log of receipt!.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed?.name === "AgreementCreated") {
          agreementId = parsed.args.agreement_id as bigint;
          agreementAddr = parsed.args.agreement_address as string;
          break;
        }
      } catch {
        /* skip non-matching logs */
      }
    }

    if (agreementId === null || agreementAddr === null) {
      throw new Error("AgreementCreated event not found");
    }

    const agreement = await ethers.getContractAt("IPLicensingAgreement", agreementAddr);
    return { agreement, agreementId, agreementAddr };
  }

  it("deploys factory & creates an agreement, reads metadata & mappings", async () => {
    const { factory, deployer, s1, s2 } = await deployFactory();

    // Create agreement with two signers
    const { agreement, agreementId, agreementAddr } = await createAgreement(
      factory,
      deployer,
      [s1.address, s2.address]
    );

    // Factory getters
    expect(await factory.get_agreement_address(agreementId)).to.equal(agreementAddr);
    expect(await factory.get_agreement_id(agreementAddr)).to.equal(agreementId);
    expect(await factory.get_agreement_count()).to.equal(1);

    // User indexing
    const creatorAgreements = await factory.get_user_agreements(deployer.address);
    expect(creatorAgreements.map((x: any) => x.toString())).to.deep.equal([agreementId.toString()]);
    const s1Agreements = await factory.get_user_agreements(s1.address);
    expect(s1Agreements.map((x: any) => x.toString())).to.deep.equal([agreementId.toString()]);
    expect(await factory.get_user_agreement_count(s2.address)).to.equal(1);

    // Agreement metadata
    const meta = await agreement.get_metadata();
    expect(meta[0]).to.equal("My Title");
    expect(meta[1]).to.equal("My Description");
    expect(meta[2]).to.equal("ip://meta");
    expect(meta[3]).to.be.gt(0);         // creation_timestamp
    expect(meta[4]).to.equal(false);     // is_immutable
    expect(meta[5]).to.equal(0);         // immutability_timestamp

    // Signers
    expect(await agreement.is_signer(s1.address)).to.equal(true);
    expect(await agreement.is_signer(s2.address)).to.equal(true);
    expect(await agreement.is_signer(ethers.ZeroAddress)).to.equal(false);

    // Owner & factory
    expect(await agreement.get_owner()).to.equal(deployer.address);
    expect(await agreement.get_factory()).to.equal(await factory.getAddress());
  });

  it("signing flow, fully signed state, immutability & reverts", async () => {
    const { factory, deployer, s1, s2, stranger } = await deployFactory();
    const { agreement } = await createAgreement(factory, deployer, [s1.address, s2.address]);

    // Non-signer cannot sign
    await expect(agreement.connect(stranger).sign_agreement()).to.be.revertedWith("NOT_A_SIGNER");

    // s1 signs
    await expect(agreement.connect(s1).sign_agreement())
      .to.emit(agreement, "AgreementSigned");
    expect(await agreement.has_signed(s1.address)).to.equal(true);
    expect(await agreement.get_signature_count()).to.equal(1);
    const ts1 = await agreement.get_signature_timestamp(s1.address);
    expect(ts1).to.be.gt(0);

    // s1 cannot sign twice
    await expect(agreement.connect(s1).sign_agreement()).to.be.revertedWith("ALREADY_SIGNED");

    // s2 signs -> fully signed
    await agreement.connect(s2).sign_agreement();
    expect(await agreement.get_signature_count()).to.equal(2);
    expect(await agreement.is_fully_signed()).to.equal(true);

    // Make immutable (by owner)
    await expect(agreement.connect(deployer).make_immutable())
      .to.emit(agreement, "AgreementMadeImmutable");
    const metaAfter = await agreement.get_metadata();
    expect(metaAfter[4]).to.equal(true);         // is_immutable
    expect(metaAfter[5]).to.be.gt(0);            // immutability_timestamp

    // Once immutable, no more metadata changes
    const KEY = ethers.encodeBytes32String("K");
    const VAL = ethers.encodeBytes32String("V");
    await expect(agreement.connect(deployer).add_metadata(KEY, VAL))
      .to.be.revertedWith("AGREEMENT_IMMUTABLE");
  });

  it("metadata add works before immutability, and only owner can add", async () => {
    const { factory, deployer, s1 } = await deployFactory();
    const { agreement } = await createAgreement(factory, deployer, [s1.address]);

    const KEY = ethers.encodeBytes32String("Purpose");
    const VAL = ethers.encodeBytes32String("LicenseX");

    // Non-owner cannot add
    await expect(agreement.connect(s1).add_metadata(KEY, VAL)).to.be.revertedWith("Ownable: not owner");

    // Owner can add
    await expect(agreement.connect(deployer).add_metadata(KEY, VAL))
      .to.emit(agreement, "MetadataAdded");

    expect(await agreement.get_additional_metadata(KEY)).to.equal(VAL);

    // Now make immutable and verify add reverts
    await agreement.connect(deployer).make_immutable();
    await expect(agreement.connect(deployer).add_metadata(KEY, VAL))
      .to.be.revertedWith("AGREEMENT_IMMUTABLE");
  });

  it("factory: only owner can update class hash; inputs validations on create", async () => {
    const { factory, deployer, s1 } = await deployFactory();

    // Only owner can update
    const NEW_HASH = ethers.id("newClassHash"); // bytes32
    await factory.connect(deployer).update_agreement_class_hash(NEW_HASH);
    expect(await factory.get_agreement_class_hash()).to.equal(NEW_HASH);

    await expect(factory.connect(s1).update_agreement_class_hash(NEW_HASH))
      .to.be.revertedWith("Ownable: not owner");

    // Input validations on create
    await expect(factory.create_agreement("", "desc", "meta", [s1.address]))
      .to.be.revertedWith("EMPTY_TITLE");
    await expect(factory.create_agreement("t", "", "meta", [s1.address]))
      .to.be.revertedWith("EMPTY_DESCRIPTION");
    await expect(factory.create_agreement("t", "d", "", [s1.address]))
      .to.be.revertedWith("EMPTY_METADATA");
    await expect(factory.create_agreement("t", "d", "m", []))
      .to.be.revertedWith("NO_SIGNERS");
  });
});
