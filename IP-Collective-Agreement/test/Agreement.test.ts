// test/CollectiveIPCore.test.ts
import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const b32 = (s: string) => ethers.encodeBytes32String(s);
const toWei = (n: string) => ethers.parseUnits(n, 18);

describe("CollectiveIPCore (full-stack, single-file tests)", function () {
  const BASE_URI = "ipfs://base/{id}.json";

  let owner: any, a1: any, a2: any, a3: any, outsider: any, licensee: any, revenueSender: any, authority: any;
  let core: any;
  let erc20: any;

  const PCT = [60, 30, 10];
  const GOV = [600, 300, 100];
  const ART = b32("ART");
  const GLOBAL = b32("GLOBAL");
  const EXCLUSIVE = b32("EXCLUSIVE");
  const NON_EXCLUSIVE = b32("NON_EXCLUSIVE");
  const DERIVATIVE = b32("DERIVATIVE");
  const EMERGENCY_PAUSE = b32("EMERGENCY_PAUSE");

  before(async () => {
    [owner, a1, a2, a3, outsider, licensee, revenueSender, authority] = await ethers.getSigners();
  });

  it("deploys core + mock ERC20", async () => {
    const Core = await ethers.getContractFactory("CollectiveIPCore");
    core = await Core.deploy(BASE_URI, owner.address);
    await core.waitForDeployment();

    const Mock = await ethers.getContractFactory("MockERC20");
    // Mint 1e9 tokens to owner; we’ll distribute to licensee / revenueSender
    erc20 = await Mock.deploy("MockUSD", "mUSD", toWei("1000000000"), owner.address);
    await erc20.waitForDeployment();

    // Distribute balances
    await erc20.connect(owner).transfer(licensee.address, toWei("1000000"));
    await erc20.connect(owner).transfer(revenueSender.address, toWei("1000000"));

    expect(await core.owner()).to.equal(owner.address);
    expect(await erc20.balanceOf(licensee.address)).to.equal(toWei("1000000"));
  });

  let assetId: bigint;

  it("registers an IP asset (ERC1155) with collective ownership + initial mint", async () => {
    const tx = await core
      .connect(owner)
      .registerIpAsset(
        ART,
        "ipfs://asset/1.json",
        [a1.address, a2.address, a3.address],
        PCT,
        GOV
      );
    const rec = await tx.wait();
    const ev = rec!.logs.find((l: any) => l.fragment?.name === "AssetRegistered");
    assetId = ev?.args?.assetId;

    // ownership + supply
    expect(assetId).to.equal(1n);
    expect(await core.getOwnerPercentage(assetId, a1.address)).to.equal(60);
    expect(await core.getOwnerPercentage(assetId, a2.address)).to.equal(30);
    expect(await core.getOwnerPercentage(assetId, a3.address)).to.equal(10);

    // ERC1155 minted 1000 total → 600/300/100
    expect(await core.balanceOf(a1.address, assetId)).to.equal(600n);
    expect(await core.balanceOf(a2.address, assetId)).to.equal(300n);
    expect(await core.balanceOf(a3.address, assetId)).to.equal(100n);

    const info = await core.getAssetInfo(assetId);
    expect(info.assetType).to.equal(ART);
    expect(info.totalSupply).to.equal(1000n);
  });

  it("updates metadata & transfers ownership share", async () => {
    await core.connect(a1).updateAssetMetadata(assetId, "ipfs://asset/1-v2.json");
    const uri = await core.getAssetURI(assetId);
    expect(uri).to.equal("ipfs://asset/1-v2.json");

    // a1 transfers 10% to a2
    await core.connect(a1).transferOwnershipShare(assetId, a1.address, a2.address, 10);
    expect(await core.getOwnerPercentage(assetId, a1.address)).to.equal(50);
    expect(await core.getOwnerPercentage(assetId, a2.address)).to.equal(40);
    expect(await core.getOwnerPercentage(assetId, a3.address)).to.equal(10);
  });

  it("rejects non-owner actions (onlyAssetOwner / onlyOwner)", async () => {
    await expect(core.connect(outsider).updateAssetMetadata(assetId, "x")).to.be.revertedWith("Not asset owner");
    await expect(core.connect(outsider).pauseContract()).to.be.reverted; // onlyOwner
  });

  describe("Revenue distribution", () => {
    it("receives ERC20 revenue, distributes all, owners withdraw", async () => {
      const amount = toWei("1000");
      await erc20.connect(revenueSender).approve(await core.getAddress(), amount);
      await core.connect(revenueSender).receiveRevenue(assetId, await erc20.getAddress(), amount);

      expect(await core.getAccumulatedRevenue(assetId, await erc20.getAddress())).to.equal(amount);

      // Set a small min distribution and distribute all
      await core.connect(a1).setMinimumDistribution(assetId, 1, await erc20.getAddress());
      await core.connect(a1).distributeAllRevenue(assetId, await erc20.getAddress());

      // Percentages now 50/40/10
      const p1 = await core.getPendingRevenue(assetId, a1.address, await erc20.getAddress());
      const p2 = await core.getPendingRevenue(assetId, a2.address, await erc20.getAddress());
      const p3 = await core.getPendingRevenue(assetId, a3.address, await erc20.getAddress());
      expect(p1).to.equal(toWei("500"));
      expect(p2).to.equal(toWei("400"));
      expect(p3).to.equal(toWei("100"));

      const b1Before = await erc20.balanceOf(a1.address);
      await core.connect(a1).withdrawPendingRevenue(assetId, await erc20.getAddress());
      const b1After = await erc20.balanceOf(a1.address);
      expect(b1After - b1Before).to.equal(toWei("500"));
    });
  });

  describe("Licensing + royalties", () => {
    let licenseId: bigint;

    it("creates license request (EXCLUSIVE → needs approval)", async () => {
      const terms = {
        maxUsageCount: 0n,
        currentUsageCount: 0n,
        attributionRequired: true,
        modificationAllowed: false,
        commercialRevenueShare: 0n,
        terminationNoticePeriod: 0n,
      };

      const fee = toWei("1000"); // > 500 → requires approval anyway
      const duration = 60n * 60n * 24n * 30n; // 30j
      const tx = await core
        .connect(a1)
        .createLicenseRequest(
          assetId,
          licensee.address,
          EXCLUSIVE,
          DERIVATIVE,
          GLOBAL,
          fee,
          500n, // 5% bps = 500
          duration,
          await erc20.getAddress(),
          terms,
          "ipfs://license/1"
        );
      const rec = await tx.wait();
      const ev = rec!.logs.find((l: any) => l.fragment?.name === "LicenseOfferCreated");
      licenseId = ev?.args?.licenseId;

      const info = await core.getLicenseInfo(licenseId);
      expect(info.requiresApproval).to.equal(true);
      expect(info.isApproved).to.equal(false);
    });

    it("owner approves license; licensee executes (fee auto-distributed)", async () => {
      await core.connect(a2).approveLicense(licenseId, true);

      // licensee must approve fee to core
      await erc20.connect(licensee).approve(await core.getAddress(), toWei("1000"));
      await core.connect(licensee).executeLicense(licenseId);

      const li = await core.getLicenseInfo(licenseId);
      expect(li.isActive).to.equal(true);

      // fee distributed 50/40/10 to pending
      expect(await core.getPendingRevenue(assetId, a1.address, await erc20.getAddress())).to.equal(0); // already withdrawn earlier
      expect(await core.getPendingRevenue(assetId, a2.address, await erc20.getAddress())).to.equal(toWei("400"));
      expect(await core.getPendingRevenue(assetId, a3.address, await erc20.getAddress())).to.equal(toWei("100"));
    });

    it("licensee reports usage and pays royalties (5%)", async () => {
      await core.connect(licensee).reportUsageRevenue(licenseId, toWei("10000"), 123);
      const due = await core.calculateDueRoyalties(licenseId);
      expect(due).to.equal(toWei("500")); // 5% of 10k

      await erc20.connect(licensee).approve(await core.getAddress(), due);
      await core.connect(licensee).payRoyalties(licenseId, due);

      // pending revenue increased (pro-rata on royalties)
      const p1 = await core.getPendingRevenue(assetId, a1.address, await erc20.getAddress());
      const p2 = await core.getPendingRevenue(assetId, a2.address, await erc20.getAddress());
      const p3 = await core.getPendingRevenue(assetId, a3.address, await erc20.getAddress());
      // a2 had 400, a3 had 100 already from fee distribution
      expect(p1).to.equal(toWei("250")); // 50% of 500
      expect(p2).to.equal(toWei("650")); // 40% of 500 + 400
      expect(p3).to.equal(toWei("150")); // 10% of 500 + 100
    });

    it("suspends then reactivates license (time-based)", async () => {
      // suspend 1 day
      await core.connect(a1).suspendLicense(licenseId, 24 * 60 * 60);
      expect(await core.getLicenseStatus(licenseId)).to.equal(b32("SUSPENDED"));

      await time.increase(24 * 60 * 60 + 1);
      expect(await core.getLicenseStatus(licenseId)).to.equal(b32("SUSPENSION_EXPIRED"));

      await core.checkAndReactivateLicense(licenseId);
      expect(await core.getLicenseStatus(licenseId)).to.equal(b32("ACTIVE"));
    });

    it("transfers license to a new licensee", async () => {
      await core.connect(licensee).transferLicense(licenseId, outsider.address);
      const li = await core.getLicenseInfo(licenseId);
      expect(li.licensee).to.equal(outsider.address);
    });
  });

  describe("Governance (asset mgmt / revenue policy / emergency)", () => {
    it("sets custom governance settings to speed up tests", async () => {
      // quorum 50%, exec delay 1 hour
      await core.connect(a1).setGovernanceSettings(assetId, {
        defaultQuorumPercentage: 5000n,
        emergencyQuorumPercentage: 3000n,
        licenseQuorumPercentage: 4000n,
        assetMgmtQuorumPercentage: 6000n,
        revenuePolicyQuorumPercentage: 5500n,
        defaultVotingDuration: 3600n, // 1h
        emergencyVotingDuration: 1800n, // 30m
        executionDelay: 3600n, // 1h
      });
    });

    let pAsset: bigint;
    it("proposes + exécute un AssetManagement (metadata + compliance)", async () => {
      const tx = await core
        .connect(a2)
        .proposeAssetManagement(
          assetId,
          {
            newMetadataUri: "ipfs://asset/1-governed.json",
            newComplianceStatus: b32("BERNE_COMPLIANT"),
            updateMetadata: true,
            updateCompliance: true,
          },
          3600, // voting 1h
          "Update metadata + compliance"
        );
      const rec = await tx.wait();
      const ev = rec!.logs.find((l: any) => l.fragment?.name === "GovernanceProposalCreated");
      pAsset = ev?.args?.proposalId;

      // votes: a1(50%), a2(40%) pour → quorum 60% requis → 90% atteint
      await core.connect(a1).voteOnGovernanceProposal(pAsset, true);
      await core.connect(a2).voteOnGovernanceProposal(pAsset, true);

      await time.increase(3600 + 5); // voting over
      await time.increase(3600 + 5); // execution delay ok

      await core.executeAssetManagementProposal(pAsset);

      const info = await core.getAssetInfo(assetId);
      expect(info.metadataUri).to.equal("ipfs://asset/1-governed.json");
      expect(info.complianceStatus).to.equal(b32("BERNE_COMPLIANT"));
    });

    let pRev: bigint;
    it("proposes + exécute une RevenuePolicy (min distribution)", async () => {
      const tx = await core
        .connect(a1)
        .proposeRevenuePolicy(
          assetId,
          {
            tokenAddress: await erc20.getAddress(),
            newMinimumDistribution: toWei("10"),
            newDistributionFrequency: 0, // unused in core logic, stored nowhere
          },
          3600,
          "Set min distribution to 10 mUSD"
        );
      const rec = await tx.wait();
      const ev = rec!.logs.find((l: any) => l.fragment?.name === "GovernanceProposalCreated");
      pRev = ev?.args?.proposalId;

      await core.connect(a1).voteOnGovernanceProposal(pRev, true); // 50%
      await core.connect(a2).voteOnGovernanceProposal(pRev, true); // → 90%

      await time.increase(3600 + 5);
      await time.increase(3600 + 5);

      await core.executeRevenuePolicyProposal(pRev);
      expect(await core.getMinimumDistribution(assetId, await erc20.getAddress())).to.equal(toWei("10"));
    });

    let pEm: bigint;
    it("proposes emergency PAUSE and executes it; transfers revert while paused", async () => {
      const tx = await core
        .connect(a1)
        .proposeEmergencyAction(
          assetId,
          {
            actionType: EMERGENCY_PAUSE,
            targetId: 0n,
            suspensionDuration: 0n,
            reason: "panic",
          },
          "Emergency pause"
        );
      const rec = await tx.wait();
      const ev = rec!.logs.find((l: any) => l.fragment?.name === "GovernanceProposalCreated");
      pEm = ev?.args?.proposalId;

      // vote a1 + a2
      await core.connect(a1).voteOnGovernanceProposal(pEm, true);
      await core.connect(a2).voteOnGovernanceProposal(pEm, true);

      await time.increase(1800 + 5); // voting over (emergencyVotingDuration)
      await time.increase(3600 + 5); // execution delay

      await core.executeEmergencyProposal(pEm);
      expect(await core.pausedFlag()).to.equal(true);

      // ERC1155 transfer must revert (paused)
      await expect(
        core.connect(a1).safeTransferFrom(a1.address, a2.address, assetId, 1, "0x")
      ).to.be.revertedWithCustomError(core, "EnforcedPause"); // OZ Pausable custom error

      // unpause by contract owner
      await core.connect(owner).unpauseContract();
      await core.connect(a1).safeTransferFrom(a1.address, a2.address, assetId, 1, "0x"); // now OK
    });
  });

  describe("Compliance (Berne) end-to-end", () => {
    const US = b32("US");
    it("registers a Compliance Authority for US", async () => {
      await core
        .connect(owner)
        .registerComplianceAuthority(
          authority.address,
          "US Copyright Office",
          [US],
          b32("GOVERNMENT"),
          "ipfs://auth/usco"
        );

      const c = await core.getComplianceAuthority(authority.address);
      expect(c.authorityAddress).to.equal(authority.address);
      expect(c.isActive).to.equal(true);
    });

    let requestId: bigint;
    it("owner requests compliance verification; authority approves", async () => {
      // requester must be owner (a1), country + publication date required
      const pubDate = BigInt(Math.floor(Date.now() / 1000) - 86400); // yesterday
      const tx = await core
        .connect(a1)
        .requestComplianceVerification(
          assetId,
          b32("BERNE_COMPLIANT"),
          "ipfs://evidence",
          US,
          pubDate,
          b32("LITERARY"),
          true,
          [a1.address, a2.address] // 2 authors => collective work
        );
      const rec = await tx.wait();
      const ev = rec!.logs.find((l: any) => l.fragment?.name === "ComplianceVerificationRequested");
      requestId = ev?.args?.requestId;

      // authority processes with automatic protection in US + manual in none
      await core
        .connect(authority)
        .processComplianceVerification(
          requestId,
          true,
          "looks valid",
          60n * 60n * 24n * 365n, // 1 year protection duration
          [US],
          []
        );

      const record = await core.getComplianceRecord(assetId);
      expect(record.assetId).to.equal(assetId);
      expect(record.countryOfOrigin).to.equal(US);
      expect(record.automaticProtectionCount).to.equal(1);
    });

    it("validates license compliance for US + GLOBAL & checks protection", async () => {
      const ok = await core.validateLicenseCompliance(assetId, US, GLOBAL, DERIVATIVE);
      expect(ok).to.equal(true);

      const [autoCountries, manualCountries] = await core.checkInternationalProtectionStatus(assetId);
      expect(autoCountries.length).to.equal(1);
      expect(manualCountries.length).to.equal(0);

      const validInUS = await core.checkProtectionValidity(assetId, US);
      expect(validInUS).to.equal(true);
    });

    it("sets restrictive country requirements and sees licensing restrictions", async () => {
      // Make a dummy country that needs registration + no moral rights
      const ZZ = b32("ZZ");
      await core.connect(owner).setCountryRequirements(ZZ, {
        countryCode: ZZ,
        isBerneSignatory: true,
        automaticProtection: false,
        registrationRequired: true,
        protectionDurationYears: 50,
        noticeRequired: true,
        depositRequired: false,
        translationRightsDuration: 10,
        moralRightsProtected: false,
      });

      const restr = await core.getLicensingRestrictions(assetId, ZZ);
      // Should contain at least NOTICE_REQUIRED and REGISTRATION_REQUIRED; order is not guaranteed
      const s = restr.map((x: string) => ethers.decodeBytes32String(x));
      expect(s).to.include.members(["NOTICE_REQUIRED", "REGISTRATION_REQUIRED"]);
    });

    it("renewal workflow & expiring protections list", async () => {
      // mark renewal in < 15 days
      const rec = await core.getComplianceRecord(assetId);
      // force a short nextRenewalDate by renewing now (sets +1y) then time-travel near expiry
      await core.connect(a1).renewProtection(assetId, "ipfs://renewal1");
      // fast-forward almost 1 year but keep < threshold window we’ll query
      await time.increase(60 * 60 * 24 * 350);

      const [required, deadline] = await core.checkRenewalRequirements(assetId);
      expect(required).to.equal(true);
      expect(deadline).to.be.greaterThan(0n);

      // query assets expiring within 30 days
      const expiring = await core.getExpiringProtections(30);
      expect(expiring.length).to.be.greaterThan(0);
    });
  });

  describe("Misc & getters", () => {
    it("lists owners / creators / proposals", async () => {
      const owners = await core.getAssetOwners(assetId);
      expect(owners).to.have.lengthOf(3);

      const creators = await core.getAssetCreators(assetId);
      expect(creators).to.have.lengthOf(3);

      const active = await core.getActiveProposalsForAsset(assetId);
      // some may be closed; active should be 0 after executions above
      expect(active.length).to.equal(0);
    });

    it("getAssetsByComplianceStatus returns our asset", async () => {
      const arr = await core.getAssetsByComplianceStatus(b32("BERNE_COMPLIANT"));
      expect(arr.map((x: bigint) => x.toString())).to.include(assetId.toString());
    });
  });

  describe("Security / edge cases", () => {
    it("rejects revenue with zero amount", async () => {
      await expect(
        core.connect(revenueSender).receiveRevenue(assetId, await erc20.getAddress(), 0)
      ).to.be.revertedWith("Amount>0");
    });

    it("rejects license execution without approval", async () => {
      // Create a NON_EXCLUSIVE with low fee (no approval) to sanity-check path, then create one that needs approval and try execution
      const terms = {
        maxUsageCount: 1n,
        currentUsageCount: 0n,
        attributionRequired: false,
        modificationAllowed: true,
        commercialRevenueShare: 0n,
        terminationNoticePeriod: 0n,
      };

      const lidTx = await core
        .connect(a1)
        .createLicenseRequest(
          assetId,
          outsider.address,
          NON_EXCLUSIVE,
          b32("COMMERCIAL"),
          GLOBAL,
          100n, // <=500 → pas d'approval
          0n,
          0n,
          await erc20.getAddress(),
          terms,
          "ipfs://license/no-approval"
        );
      const lidRec = await lidTx.wait();
      const lid = lidRec!.logs.find((l: any) => l.fragment?.name === "LicenseOfferCreated")?.args?.licenseId;

      // auto-approved
      const li = await core.getLicenseInfo(lid);
      expect(li.isApproved).to.equal(true);

      // Create a second that requires approval and try to execute as outsider before approval → should revert "Not approved"
      const needTx = await core
        .connect(a1)
        .createLicenseRequest(
          assetId,
          outsider.address,
          EXCLUSIVE,
          b32("COMMERCIAL"),
          GLOBAL,
          1000n,
          0n,
          0n,
          await erc20.getAddress(),
          terms,
          "ipfs://license/needs-approval"
        );
      const needRec = await needTx.wait();
      const lid2 = needRec!.logs.find((l: any) => l.fragment?.name === "LicenseOfferCreated")?.args?.licenseId;

      await expect(core.connect(outsider).executeLicense(lid2)).to.be.revertedWith("Not approved");
    });
  });
});
