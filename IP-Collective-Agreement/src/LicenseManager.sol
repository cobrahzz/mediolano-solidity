// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RevenueDistribution.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract LicenseManager is RevenueDistribution {
    // License terms and info structs
    struct LicenseTerms {
        uint256 maxUsageCount;       // 0 means unlimited
        uint256 currentUsageCount;
        bool    attributionRequired;
        bool    modificationAllowed;
        uint256 commercialRevenueShare;
        uint64  terminationNoticePeriod;
    }

    struct LicenseInfo {
        uint256 licenseId;
        uint256 assetId;
        address licensor;
        address licensee;
        bytes32 licenseType;
        bytes32 usageRights;
        bytes32 territory;
        uint256 licenseFee;
        uint256 royaltyRate;        // in basis points (bps)
        uint64  startTimestamp;
        uint64  endTimestamp;
        bool    isActive;
        bool    requiresApproval;
        bool    isApproved;
        address paymentToken;
        bool    isSuspended;
        uint64  suspensionEndTimestamp;
        string  metadataUri;
    }

    struct RoyaltyInfo {
        uint256 assetId;
        address licensee;
        uint256 totalRevenueReported;
        uint256 totalRoyaltiesPaid;
        uint64  lastPaymentTimestamp;
        uint64  paymentFrequency;
        uint64  nextPaymentDue;
    }

    struct LicenseProposal {
        uint256 proposalId;
        uint256 assetId;
        address proposer;
        uint256 votesFor;
        uint256 votesAgainst;
        uint64  votingDeadline;
        uint64  executionDeadline;
        bool    isExecuted;
        bool    isCancelled;
    }

    // License-related events
    event LicenseOfferCreated(uint256 indexed licenseId, uint256 indexed assetId, address licensee, bytes32 licenseType, uint256 licenseFee, bool requiresApproval, uint64 timestamp);
    event LicenseApproved(uint256 indexed licenseId, address approvedBy, bool approved, uint64 timestamp);
    event LicenseExecuted(uint256 indexed licenseId, address licensee, address executedBy, uint64 timestamp);
    event LicenseRevoked(uint256 indexed licenseId, address revokedBy, string reason, uint64 timestamp);
    event LicenseSuspended(uint256 indexed licenseId, address suspendedBy, uint64 suspensionDuration, uint64 timestamp);
    event LicenseTransferred(uint256 indexed licenseId, address oldLicensee, address newLicensee, uint64 timestamp);
    event RoyaltyPaid(uint256 indexed licenseId, address payer, uint256 amount, uint64 timestamp);
    event UsageReported(uint256 indexed licenseId, address reporter, uint256 revenueAmount, uint256 usageCount, uint64 timestamp);
    event LicenseProposalCreated(uint256 indexed proposalId, uint256 indexed assetId, address proposer, uint64 votingDeadline, uint64 timestamp);
    event LicenseProposalVoted(uint256 indexed proposalId, address voter, bool voteFor, uint256 votingWeight, uint64 timestamp);
    event LicenseProposalExecuted(uint256 indexed proposalId, uint256 licenseId, address executedBy, uint64 timestamp);
    event LicenseReactivated(uint256 indexed licenseId, address reactivatedBy, uint64 timestamp);

    // License storage
    mapping(uint256 => LicenseInfo) public licenses;
    mapping(uint256 => LicenseTerms) public licenseTerms;
    uint256 public nextLicenseId = 1;
    mapping(uint256 => uint256[]) public assetLicenses;      // assetId -> licenses issued for that asset
    mapping(address => uint256[]) public licenseeLicenses;   // licensee address -> licenses they hold
    mapping(uint256 => RoyaltyInfo) public royalties;

    // License proposal (governance-like) storage
    mapping(uint256 => LicenseProposal) public licenseProposals;
    mapping(uint256 => mapping(address => bool)) public licenseProposalHasVoted;
    mapping(uint256 => bool) public licenseProposalVote;  // (not actively used, placeholder in original design)
    mapping(uint256 => LicenseInfo) public proposedLicense;
    mapping(uint256 => LicenseTerms) public proposalTerms;
    uint256 public nextLicenseProposalId = 1;
    mapping(uint256 => LicenseTerms) public defaultLicenseTerms;  // default terms per asset for proposals

    // Create a new license offer/request for an asset. Only asset owners (licensors) can call this.
    function createLicenseRequest(
        uint256 assetId,
        address licensee,
        bytes32 licenseType,
        bytes32 usageRights,
        bytes32 territory,
        uint256 licenseFee,
        uint256 royaltyRate,           // in bps (0-10000)
        uint64  durationSeconds,
        address paymentToken,
        LicenseTerms calldata terms,
        string  calldata metadataUri
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        require(licensee != address(0), "Invalid licensee address");
        require(royaltyRate <= 10_000, "Royalty > 100%");

        uint256 licenseId = nextLicenseId++;
        uint64 nowTs = _now();
        uint64 endTs = (durationSeconds == 0) ? 0 : uint64(nowTs + durationSeconds);

        bool requiresApproval = _requiresGovernanceApproval(assetId, licenseType, licenseFee);

        // Initialize license details in storage
        LicenseInfo storage li = licenses[licenseId];
        li.licenseId = licenseId;
        li.assetId = assetId;
        li.licensor = _msgSender();
        li.licensee = licensee;
        li.licenseType = licenseType;
        li.usageRights = usageRights;
        li.territory = territory;
        li.licenseFee = licenseFee;
        li.royaltyRate = royaltyRate;
        li.startTimestamp = nowTs;
        li.endTimestamp = endTs;
        li.isActive = false;
        li.requiresApproval = requiresApproval;
        li.isApproved = !requiresApproval;
        li.paymentToken = paymentToken;
        li.metadataUri = metadataUri;
        li.isSuspended = false;
        li.suspensionEndTimestamp = 0;

        // Store custom license terms
        licenseTerms[licenseId] = terms;
        assetLicenses[assetId].push(licenseId);

        emit LicenseOfferCreated(licenseId, assetId, licensee, licenseType, licenseFee, requiresApproval, nowTs);
        return licenseId;
    }

    // Approve or reject a pending license offer (if approval was required)
    function approveLicense(uint256 licenseId, bool approve_) external whenNotPaused returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.requiresApproval, "No approval required");
        require(!li.isApproved, "Already processed");
        require(isOwner(li.assetId, _msgSender()), "Only asset owners can approve");

        li.isApproved = approve_;
        emit LicenseApproved(licenseId, _msgSender(), approve_, _now());
        return true;
    }

    // Licensee executes (accepts) an approved license offer, paying any license fee
    function executeLicense(uint256 licenseId) external whenNotPaused nonReentrant returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only the specified licensee can execute");
        require(li.isApproved, "License not approved yet");
        require(!li.isActive, "License already active");
        if (li.endTimestamp != 0) {
            require(_now() < li.endTimestamp, "License term expired");
        }

        // Process payment (license fee) if applicable, then auto-distribute to owners
        if (li.licenseFee > 0) {
            _processLicensePayment(licenseId);
        }

        li.isActive = true;
        licenseeLicenses[li.licensee].push(licenseId);

        // Initialize royalty tracking for this license
        royalties[licenseId] = RoyaltyInfo({
            assetId: li.assetId,
            licensee: li.licensee,
            totalRevenueReported: 0,
            totalRoyaltiesPaid: 0,
            lastPaymentTimestamp: 0,
            paymentFrequency: THIRTY_DAYS,
            nextPaymentDue: uint64(_now() + THIRTY_DAYS)
        });

        emit LicenseExecuted(licenseId, li.licensee, _msgSender(), _now());
        return true;
    }

    // Revoke an active license (e.g., for violation), providing a reason
    function revokeLicense(uint256 licenseId, string calldata reason) external whenNotPaused onlyAssetOwner(licenses[licenseId].assetId) returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.isActive, "License is not active");
        li.isActive = false;
        emit LicenseRevoked(licenseId, _msgSender(), reason, _now());
        return true;
    }

    // Suspend an active license temporarily for a given duration (in seconds)
    function suspendLicense(uint256 licenseId, uint64 suspensionDuration) external whenNotPaused onlyAssetOwner(licenses[licenseId].assetId) returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.isActive, "License is not active");
        li.isActive = false;
        li.isSuspended = true;
        li.suspensionEndTimestamp = _now() + suspensionDuration;
        emit LicenseSuspended(licenseId, _msgSender(), suspensionDuration, _now());
        return true;
    }

    // Transfer an active license to a new licensee (initiated by current licensee)
    function transferLicense(uint256 licenseId, address newLicensee) external whenNotPaused returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only current licensee can transfer");
        require(newLicensee != address(0), "Invalid new licensee");
        require(li.isActive, "License must be active");

        address oldLicensee = li.licensee;
        li.licensee = newLicensee;
        // Update royalty info to reflect new licensee
        royalties[licenseId].licensee = newLicensee;
        licenseeLicenses[newLicensee].push(licenseId);

        emit LicenseTransferred(licenseId, oldLicensee, newLicensee, _now());
        return true;
    }

    // Licensee reports revenue and usage under the license (for royalty calculations)
    function reportUsageRevenue(uint256 licenseId, uint256 revenueAmount, uint256 usageCount) external whenNotPaused returns (bool) {
        LicenseInfo memory li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only licensee can report");
        require(li.isActive, "License is not active");

        LicenseTerms storage t = licenseTerms[licenseId];
        t.currentUsageCount += usageCount;
        if (t.maxUsageCount > 0) {
            require(t.currentUsageCount <= t.maxUsageCount, "Usage limit exceeded");
        }

        // Track revenue for royalty purposes
        RoyaltyInfo storage ri = royalties[licenseId];
        ri.totalRevenueReported += revenueAmount;

        emit UsageReported(licenseId, _msgSender(), revenueAmount, usageCount, _now());
        return true;
    }

    // Licensee pays due royalties (in the specified payment token)
    function payRoyalties(uint256 licenseId, uint256 amount) external whenNotPaused nonReentrant returns (bool) {
        LicenseInfo memory li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only licensee can pay");
        require(amount > 0, "Amount must be > 0");
        require(li.paymentToken != address(0), "Payment token must be an ERC20");

        IERC20(li.paymentToken).transferFrom(_msgSender(), address(this), amount);

        // Update royalty info
        RoyaltyInfo storage ri = royalties[licenseId];
        ri.totalRoyaltiesPaid += amount;
        ri.lastPaymentTimestamp = _now();
        ri.nextPaymentDue = uint64(_now() + ri.paymentFrequency);

        // Distribute the royalty payment to asset owners
        _distributeLicenseFee(li.assetId, li.paymentToken, amount);

        emit RoyaltyPaid(licenseId, _msgSender(), amount, _now());
        return true;
    }

    // Calculate currently due royalties for a license (based on reported revenue and royalty rate)
    function calculateDueRoyalties(uint256 licenseId) external view returns (uint256) {
        LicenseInfo memory li = licenses[licenseId];
        RoyaltyInfo memory ri = royalties[licenseId];
        if (li.royaltyRate == 0) return 0;
        uint256 due = (ri.totalRevenueReported * li.royaltyRate) / 10_000;
        if (due > ri.totalRoyaltiesPaid) {
            return due - ri.totalRoyaltiesPaid;
        }
        return 0;
    }

    // Automatically reactivate a suspended license if the suspension period has elapsed
    function checkAndReactivateLicense(uint256 licenseId) external whenNotPaused returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        if (!li.isSuspended) return false;
        if (_now() >= li.suspensionEndTimestamp) {
            li.isActive = true;
            li.isSuspended = false;
            li.suspensionEndTimestamp = 0;
            emit LicenseReactivated(licenseId, _msgSender(), _now());
            return true;
        }
        return false;
    }

    // Asset owner manually reactivates a suspended license (before suspension period ends, if needed)
    function reactivateSuspendedLicense(uint256 licenseId) external whenNotPaused onlyAssetOwner(licenses[licenseId].assetId) returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.isSuspended, "License is not suspended");
        li.isActive = true;
        li.isSuspended = false;
        li.suspensionEndTimestamp = 0;
        emit LicenseReactivated(licenseId, _msgSender(), _now());
        return true;
    }

    // Get current status of a license (returns one of the status code constants)
    function getLicenseStatus(uint256 licenseId) external view returns (bytes32) {
        LicenseInfo memory li = licenses[licenseId];
        if (li.licenseId == 0) return _NOT_FOUND;
        if (!li.isApproved) return _PENDING_APPROVAL;
        if (!li.isActive && !li.isSuspended) return _INACTIVE;
        if (li.isSuspended) {
            if (_now() >= li.suspensionEndTimestamp) return _SUSPENSION_EXPIRED;
            return _SUSPENDED;
        }
        if (li.endTimestamp != 0 && _now() >= li.endTimestamp) return _EXPIRED;
        return _ACTIVE;
    }

        // Fetch full license details
    function getLicenseInfoA(uint256 licenseId) external view returns (
        uint256 licenseIdOut,
        uint256 assetId,
        address licensor,
        address licensee,
        bytes32 licenseType,
        bytes32 usageRights,
        bytes32 territory
    ) {
        LicenseInfo storage li = licenses[licenseId];
        return (
            li.licenseId,
            li.assetId,
            li.licensor,
            li.licensee,
            li.licenseType,
            li.usageRights,
            li.territory
        );
    }

    function getLicenseInfoB(uint256 licenseId) external view returns (
        uint256 licenseFee,
        uint256 royaltyRate,
        uint64  startTimestamp,
        uint64  endTimestamp
    ) {
        LicenseInfo storage li = licenses[licenseId];
        return (
            li.licenseFee,
            li.royaltyRate,
            li.startTimestamp,
            li.endTimestamp
        );
    }

    function getLicenseInfoC(uint256 licenseId) external view returns (
        bool    isActive,
        bool    requiresApproval,
        bool    isApproved,
        address paymentToken,
        bool    isSuspended,
        uint64  suspensionEndTimestamp
    ) {
        LicenseInfo storage li = licenses[licenseId];
        return (
            li.isActive,
            li.requiresApproval,
            li.isApproved,
            li.paymentToken,
            li.isSuspended,
            li.suspensionEndTimestamp
        );
    }


    function getLicenseMetadataUri(uint256 licenseId) external view returns (string memory) {
        return licenses[licenseId].metadataUri;
    }

    function getLicenseTermsInfo(uint256 licenseId) external view returns (LicenseTerms memory) {
        return licenseTerms[licenseId];
    }

    function getAssetLicenses(uint256 assetId) external view returns (uint256[] memory) {
        return assetLicenses[assetId];
    }

    function getLicenseeLicenses(address licensee) external view returns (uint256[] memory) {
        return licenseeLicenses[licensee];
    }

    // Check if a license is currently valid (active, approved, not expired, and within usage limits)
    function isLicenseValid(uint256 licenseId) external view returns (bool) {
        LicenseInfo memory li = licenses[licenseId];
        if (li.licenseId == 0 || !li.isActive || !li.isApproved) return false;
        if (li.endTimestamp != 0 && _now() >= li.endTimestamp) return false;
        LicenseTerms memory t = licenseTerms[licenseId];
        if (t.maxUsageCount > 0 && t.currentUsageCount > t.maxUsageCount) return false;
        return true;
    }

    function getRoyaltyInfo(uint256 licenseId) external view returns (RoyaltyInfo memory) {
        return royalties[licenseId];
    }

    function setDefaultLicenseTerms(uint256 assetId, LicenseTerms calldata terms) external onlyAssetOwner(assetId) returns (bool) {
        defaultLicenseTerms[assetId] = terms;
        return true;
    }

    // Governance-like flow for proposing license terms (collective decision by owners)
    function proposeLicenseTerms(uint256 assetId, LicenseInfo calldata proposed, uint64 votingDuration) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        uint256 proposalId = nextLicenseProposalId++;
        uint64 deadline = uint64(_now() + votingDuration);
        uint64 execDeadline = uint64(deadline + 86_400);  // 24h execution window after voting

        licenseProposals[proposalId] = LicenseProposal({
            proposalId: proposalId,
            assetId: assetId,
            proposer: _msgSender(),
            votesFor: 0,
            votesAgainst: 0,
            votingDeadline: deadline,
            executionDeadline: execDeadline,
            isExecuted: false,
            isCancelled: false
        });
        proposedLicense[proposalId] = proposed;
        proposalTerms[proposalId] = defaultLicenseTerms[assetId];

        emit LicenseProposalCreated(proposalId, assetId, _msgSender(), deadline, _now());
        return proposalId;
    }

    function voteOnLicenseProposal(uint256 proposalId, bool voteFor) external whenNotPaused returns (bool) {
        LicenseProposal storage p = licenseProposals[proposalId];
        require(p.proposalId != 0, "No proposal");
        require(!p.isExecuted && !p.isCancelled, "Proposal closed");
        require(_now() < p.votingDeadline, "Voting period ended");
        require(isOwner(p.assetId, _msgSender()), "Only asset owners can vote");
        require(!licenseProposalHasVoted[proposalId][_msgSender()], "Already voted");

        licenseProposalHasVoted[proposalId][_msgSender()] = true;
        uint256 weight = getGovernanceWeight(p.assetId, _msgSender());
        if (voteFor) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        emit LicenseProposalVoted(p.proposalId, _msgSender(), voteFor, weight, _now());
        return true;
    }

    function executeLicenseProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        LicenseProposal storage p = licenseProposals[proposalId];
        require(p.proposalId != 0, "No proposal");
        require(!p.isExecuted && !p.isCancelled, "Proposal closed");
        require(_now() > p.votingDeadline && _now() <= p.executionDeadline, "Not in execution window");
        require(p.votesFor > p.votesAgainst, "Proposal not passed");

        // Create the new license as proposed
        uint256 newLicenseId = nextLicenseId++;
        LicenseInfo memory src = proposedLicense[proposalId];
        LicenseInfo storage dst = licenses[newLicenseId];
        dst.licenseId = newLicenseId;
        dst.assetId = p.assetId;
        dst.licensor = p.proposer;
        dst.licensee = src.licensee;
        dst.licenseType = src.licenseType;
        dst.usageRights = src.usageRights;
        dst.territory = src.territory;
        dst.licenseFee = src.licenseFee;
        dst.royaltyRate = src.royaltyRate;
        dst.startTimestamp = src.startTimestamp;
        dst.endTimestamp = src.endTimestamp;
        dst.isActive = false;
        dst.requiresApproval = src.requiresApproval;
        dst.isApproved = true;
        dst.paymentToken = src.paymentToken;
        dst.metadataUri = src.metadataUri;
        dst.isSuspended = false;
        dst.suspensionEndTimestamp = 0;

        licenseTerms[newLicenseId] = proposalTerms[proposalId];
        assetLicenses[p.assetId].push(newLicenseId);
        p.isExecuted = true;

        emit LicenseProposalExecuted(proposalId, newLicenseId, _msgSender(), _now());
        return true;
    }

    // Internal helper to determine if a license request needs collective governance approval
    function _requiresGovernanceApproval(uint256 /*assetId*/, bytes32 licenseType, uint256 licenseFee) internal pure returns (bool) {
        if (licenseType == _EXCLUSIVE || licenseType == _SOLE_EXCLUSIVE) return true;
        if (licenseFee > 500) return true;
        return false;
    }

    // Internal helper to process license fee payment
    function _processLicensePayment(uint256 licenseId) internal {
        LicenseInfo memory li = licenses[licenseId];
        if (li.licenseFee == 0) return;
        require(li.paymentToken != address(0), "Payment token must be ERC20");
        // Transfer license fee from licensee to contract, then distribute among owners
        IERC20(li.paymentToken).transferFrom(li.licensee, address(this), li.licenseFee);
        _distributeLicenseFee(li.assetId, li.paymentToken, li.licenseFee);
    }
}
