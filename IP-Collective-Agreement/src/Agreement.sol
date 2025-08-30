// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * Collective IP Core (Solidity port from Cairo)
 * - ERC1155-based representation of IP assets (assetId => fungible supply)
 * - Collective ownership registry with percentages + governance weights
 * - Revenue collection, distribution and withdrawals (ERC20 tokens)
 * - Licensing (requests, approvals, execution, suspension, transfer)
 * - Royalty tracking & payments
 * - Governance (proposals, quorum & execution for asset mgmt/revenue/emergency)
 * - Compliance Berne (authorities, country requirements, verification)
 *
 * This file consolidates almost everything into ONE contract (plus 2 tiny mocks at the end)
 * to match your "as few files as possible" requirement.
 */

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CollectiveIPCore is ERC1155, Ownable, Pausable, ReentrancyGuard {
    // -------------------------------------------------------------------------
    // Constants (from constants.cairo)
    // -------------------------------------------------------------------------
    uint64  public constant THIRTY_DAYS = 2_592_000; // 30 days in seconds
    uint256 public constant STANDARD_INITIAL_SUPPLY = 1_000;

    // Common felt252-like codes mapped to bytes32 (Cairo uses 'STRINGS')
    bytes32 private constant _PENDING          = "PENDING";
    bytes32 private constant _BERNE_COMPLIANT  = "BERNE_COMPLIANT";
    bytes32 private constant _NON_COMPLIANT    = "NON_COMPLIANT";
    bytes32 private constant _UNDER_REVIEW     = "UNDER_REVIEW";

    bytes32 private constant _GLOBAL           = "GLOBAL";
    bytes32 private constant _EXCLUSIVE        = "EXCLUSIVE";
    bytes32 private constant _NON_EXCLUSIVE    = "NON_EXCLUSIVE";
    bytes32 private constant _SOLE_EXCLUSIVE   = "SOLE_EXCLUSIVE";
    bytes32 private constant _SUBLICENSABLE    = "SUBLICENSABLE";
    bytes32 private constant _DERIVATIVE       = "DERIVATIVE";

    bytes32 private constant _LICENSE_APPROVAL = "LICENSE_APPROVAL";
    bytes32 private constant _ASSET_MANAGEMENT = "ASSET_MANAGEMENT";
    bytes32 private constant _REVENUE_POLICY   = "REVENUE_POLICY";
    bytes32 private constant _EMERGENCY        = "EMERGENCY";

    // License status codes for get_license_status()
    bytes32 private constant _NOT_FOUND         = "NOT_FOUND";
    bytes32 private constant _PENDING_APPROVAL  = "PENDING_APPROVAL";
    bytes32 private constant _INACTIVE          = "INACTIVE";
    bytes32 private constant _SUSPENSION_EXPIRED= "SUSPENSION_EXPIRED";
    bytes32 private constant _SUSPENDED         = "SUSPENDED";
    bytes32 private constant _EXPIRED           = "EXPIRED";
    bytes32 private constant _ACTIVE            = "ACTIVE";

    // Restrictions (compliance)
    bytes32 private constant _NO_COMPLIANCE_RECORD = "NO_COMPLIANCE_RECORD";
    bytes32 private constant _NO_PROTECTION        = "NO_PROTECTION";
    bytes32 private constant _NOTICE_REQUIRED      = "NOTICE_REQUIRED";
    bytes32 private constant _NO_MORAL_RIGHTS      = "NO_MORAL_RIGHTS";
    bytes32 private constant _REGISTRATION_REQUIRED= "REGISTRATION_REQUIRED";

    // -------------------------------------------------------------------------
    // Structs (types.cairo merged)
    // -------------------------------------------------------------------------

    // Ownership
    struct OwnershipInfo {
        uint32 totalOwners;
        bool   isActive;
        uint64 registrationTimestamp;
    }

    struct OwnerRevenueInfo {
        uint256 totalEarned;
        uint256 totalWithdrawn;
        uint64  lastWithdrawalTimestamp;
    }

    // Asset
    struct IPAssetInfo {
        uint256 assetId;
        bytes32 assetType;         // e.g., "ART","MUSIC","SOFTWARE", etc.
        string  metadataUri;
        uint256 totalSupply;
        uint64  creationTimestamp;
        bool    isVerified;
        bytes32 complianceStatus;  // "PENDING", "BERNE_COMPLIANT", etc.
    }

    // Revenue
    struct RevenueInfo {
        uint256 totalReceived;
        uint256 totalDistributed;
        uint256 accumulated;
        uint64  lastDistributionTimestamp;
        uint256 minimumDistribution;
        uint32  distributionCount;
    }

    // License
    struct LicenseTerms {
        uint256 maxUsageCount;        // 0 = unlimited
        uint256 currentUsageCount;
        bool    attributionRequired;
        bool    modificationAllowed;
        uint256 commercialRevenueShare; // additional share if needed
        uint64  terminationNoticePeriod;
    }

    struct LicenseInfo {
        uint256 licenseId;
        uint256 assetId;
        address licensor;
        address licensee;
        bytes32 licenseType;      // "EXCLUSIVE", "NON_EXCLUSIVE", ...
        bytes32 usageRights;      // "COMMERCIAL", "DERIVATIVE", ...
        bytes32 territory;        // "GLOBAL", "US", ...
        uint256 licenseFee;       // upfront
        uint256 royaltyRate;      // basis points (100 = 1%)
        uint64  startTimestamp;
        uint64  endTimestamp;     // 0 = perpetual
        bool    isActive;
        bool    requiresApproval;
        bool    isApproved;
        address paymentToken;     // 0 = native disabled here; ERC20 only
        string  metadataUri;
        bool    isSuspended;
        uint64  suspensionEndTimestamp;
    }

    struct RoyaltyInfo {
        uint256 assetId;
        address licensee;
        uint256 totalRevenueReported;
        uint256 totalRoyaltiesPaid;
        uint64  lastPaymentTimestamp;
        uint64  paymentFrequency; // default THIRTY_DAYS
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

    // Governance
    struct GovernanceProposal {
        uint256 proposalId;
        uint256 assetId;
        bytes32 proposalType;         // "ASSET_MANAGEMENT", "REVENUE_POLICY", "EMERGENCY"
        address proposer;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotingWeight;
        uint256 quorumRequired;
        uint64  votingDeadline;
        uint64  executionDeadline;
        bool    isExecuted;
        bool    isCancelled;
        string  description;
    }

    struct AssetManagementProposal {
        string  newMetadataUri;
        bytes32 newComplianceStatus;
        bool    updateMetadata;
        bool    updateCompliance;
    }

    struct RevenuePolicyProposal {
        address tokenAddress;
        uint256 newMinimumDistribution;
        uint64  newDistributionFrequency;
    }

    struct EmergencyProposal {
        bytes32 actionType;       // "SUSPEND_ASSET" | "SUSPEND_LICENSE" | "EMERGENCY_PAUSE"
        uint256 targetId;         // Asset ID or License ID
        uint64  suspensionDuration;
        string  reason;
    }

    struct GovernanceSettings {
        uint256 defaultQuorumPercentage;       // bps
        uint256 emergencyQuorumPercentage;     // bps
        uint256 licenseQuorumPercentage;       // bps
        uint256 assetMgmtQuorumPercentage;     // bps
        uint256 revenuePolicyQuorumPercentage; // bps
        uint64  defaultVotingDuration;         // seconds
        uint64  emergencyVotingDuration;       // seconds
        uint64  executionDelay;                // seconds
    }

    // Compliance
    struct ComplianceRecord {
        uint256 assetId;
        bytes32 complianceStatus;
        bytes32 countryOfOrigin;   // ISO code in bytes32
        uint64  publicationDate;
        address registrationAuthority;
        uint64  verificationTimestamp;
        string  complianceEvidenceUri;
        uint32  automaticProtectionCount;
        uint32  manualRegistrationCount;
        uint64  protectionDuration; // seconds
        bool    isAnonymousWork;
        bool    isCollectiveWork;
        bool    renewalRequired;
        uint64  nextRenewalDate;
    }

    struct ComplianceVerificationRequest {
        uint256 requestId;
        uint256 assetId;
        address requester;
        bytes32 requestedStatus;
        string  evidenceUri;
        bytes32 countryOfOrigin;
        uint64  publicationDate;
        bytes32 workType;
        bool    isOriginalWork;
        uint32  authorsCount;
        uint64  requestTimestamp;
        bool    isProcessed;
        bool    isApproved;
        string  verifierNotes;
    }

    struct CountryComplianceRequirements {
        bytes32 countryCode;
        bool    isBerneSignatory;
        bool    automaticProtection;
        bool    registrationRequired;
        uint16  protectionDurationYears;
        bool    noticeRequired;
        bool    depositRequired;
        uint16  translationRightsDuration;
        bool    moralRightsProtected;
    }

    struct ComplianceAuthority {
        address authorityAddress;
        string  authorityName;
        uint32  authorizedCountriesCount;
        bytes32 authorityType; // "GOVERNMENT","CERTIFIED_ORG","LEGAL_EXPERT"
        bool    isActive;
        uint256 verificationCount;
        uint64  registrationTimestamp;
        string  credentialsUri;
    }

    // -------------------------------------------------------------------------
    // Events (mirroring Cairo)
    // -------------------------------------------------------------------------

    // Ownership
    event CollectiveOwnershipRegistered(uint256 indexed assetId, uint32 totalOwners, uint64 timestamp);
    event IPOwnershipTransferred(uint256 indexed assetId, address indexed from, address indexed to, uint256 percentage, uint64 timestamp);

    // Asset
    event AssetRegistered(uint256 indexed assetId, bytes32 assetType, uint32 totalCreators, uint64 timestamp);
    event MetadataUpdated(uint256 indexed assetId, string oldMetadata, string newMetadata, address updatedBy, uint64 timestamp);

    // Revenue
    event RevenueReceived(uint256 indexed assetId, address indexed token, uint256 amount, address from, uint64 timestamp);
    event RevenueDistributed(uint256 indexed assetId, address indexed token, uint256 totalAmount, uint32 recipientsCount, address distributedBy, uint64 timestamp);
    event RevenueWithdrawn(uint256 indexed assetId, address indexed owner, address indexed token, uint256 amount, uint64 timestamp);

    // License
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

    // Governance
    event GovernanceProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed assetId,
        bytes32 proposalType,
        address proposer,
        uint256 quorumRequired,
        uint64 votingDeadline,
        string description,
        uint64 timestamp
    );
    event ProposalQuorumReached(uint256 indexed proposalId, uint256 totalVotes, uint256 quorumRequired, uint64 timestamp);
    event AssetManagementExecuted(uint256 indexed proposalId, uint256 indexed assetId, bool metadataUpdated, bool complianceUpdated, address executedBy, uint64 timestamp);
    event RevenuePolicyUpdated(uint256 indexed proposalId, uint256 indexed assetId, address tokenAddress, uint256 newMinimumDistribution, address executedBy, uint64 timestamp);
    event EmergencyActionExecuted(uint256 indexed proposalId, bytes32 actionType, uint256 targetId, address executedBy, uint64 timestamp);
    event GovernanceSettingsUpdated(uint256 indexed assetId, address updatedBy, uint64 timestamp);

    // Compliance
    event ComplianceVerificationRequested(
        uint256 indexed requestId,
        uint256 indexed assetId,
        address requester,
        bytes32 requestedStatus,
        bytes32 countryOfOrigin,
        uint64 timestamp
    );
    event ComplianceVerified(
        uint256 indexed assetId,
        bytes32 newStatus,
        address verifiedBy,
        bytes32 countryOfOrigin,
        uint64 protectionDuration,
        uint64 timestamp
    );
    event ComplianceAuthorityRegistered(address indexed authorityAddress, string authorityName, bytes32 authorityType, uint32 authorizedCountriesCount, uint64 timestamp);
    event ProtectionRenewalRequired(uint256 indexed assetId, bytes32 currentStatus, uint64 renewalDeadline, uint64 timestamp);
    event ProtectionExpired(uint256 indexed assetId, bytes32 previousStatus, uint64 expirationTimestamp, uint64 timestamp);
    event CrossBorderProtectionUpdated(uint256 indexed assetId, bytes32 countryCode, bool protectionStatus, address updatedBy, uint64 timestamp);

    // -------------------------------------------------------------------------
    // Storage (merged from Storage struct)
    // -------------------------------------------------------------------------

    // ERC1155 baseURI is provided by constructor

    // Ownership
    mapping(uint256 => OwnershipInfo) public ownershipInfo;
    mapping(uint256 => mapping(address => uint256)) public ownerPercentage;    // (assetId, owner) => %
    mapping(uint256 => mapping(address => uint256)) public governanceWeight;   // (assetId, owner) => weight
    mapping(uint256 => address[])       private _assetOwners;                  // enumeration

    // Asset
    mapping(uint256 => IPAssetInfo) public assetInfo; // (assetId) => info
    mapping(uint256 => address[])    private _assetCreators; // enumeration of creators
    uint256 public nextAssetId = 1;
    bool    public pausedFlag; // mirror of Pausable (kept for fidelity)
    uint256 public totalAssets;

    // Revenue
    mapping(uint256 => mapping(address => RevenueInfo)) public revenue; // (assetId, token) => RevenueInfo
    mapping(uint256 => mapping(address => mapping(address => uint256))) public pendingRevenue; // (assetId, owner, token) => amount
    mapping(uint256 => mapping(address => mapping(address => OwnerRevenueInfo))) public ownerRevenue; // (assetId, owner, token) => info

    // Licensing
    mapping(uint256 => LicenseInfo) public licenses;          // licenseId => LicenseInfo
    mapping(uint256 => LicenseTerms) public licenseTerms;     // licenseId => LicenseTerms
    uint256 public nextLicenseId = 1;
    mapping(uint256 => uint256[]) public assetLicenses;       // assetId => [licenseIds]
    mapping(address => uint256[]) public licenseeLicenses;    // licensee => [licenseIds]
    mapping(uint256 => RoyaltyInfo) public royalties;         // licenseId => RoyaltyInfo

    // License proposals (governance for license terms)
    mapping(uint256 => LicenseProposal) public licenseProposals;
    mapping(uint256 => mapping(address => bool)) public licenseProposalHasVoted; // (proposalId,voter) => bool
    mapping(uint256 => bool) public licenseProposalVote; // placeholder per voter if needed
    mapping(uint256 => LicenseInfo) public proposedLicense; // proposalId => LicenseInfo (blueprint)
    mapping(uint256 => LicenseTerms) public proposalTerms;   // proposalId => LicenseTerms
    uint256 public nextLicenseProposalId = 1;
    mapping(uint256 => LicenseTerms) public defaultLicenseTerms; // assetId => default terms

    // Governance
    mapping(uint256 => GovernanceProposal) public governanceProposals;
    mapping(uint256 => AssetManagementProposal) public assetMgmtProposals;
    mapping(uint256 => RevenuePolicyProposal)  public revenuePolicyProposals;
    mapping(uint256 => EmergencyProposal)      public emergencyProposals;
    mapping(uint256 => GovernanceSettings)     public governanceSettings; // assetId => settings
    mapping(uint256 => mapping(address => bool)) public governanceHasVoted;
    mapping(uint256 => mapping(address => bool)) public governanceVotes; // record of last vote
    uint256 public nextGovernanceProposalId = 1;
    mapping(uint256 => uint256[]) public activeProposalsForAsset; // assetId => [proposalIds]

    // Compliance
    mapping(uint256 => ComplianceRecord) public complianceRecords;         // assetId => record
    mapping(address => ComplianceAuthority) public complianceAuthorities;  // authority => info
    mapping(bytes32 => CountryComplianceRequirements) public countryRequirements; // country => requirements

    mapping(uint256 => ComplianceVerificationRequest) public complianceRequests; // requestId => request
    uint256 public nextVerificationRequestId = 1;

    // authority authorized countries (for quick checks + enumeration)
    mapping(address => mapping(bytes32 => bool)) public authorityCountryAllowed;  // authority => (country => bool)
    mapping(address => bytes32[]) public authorityCountries;                      // authority => [countries]

    // International protection flags per asset
    mapping(uint256 => mapping(bytes32 => bool)) public internationalProtection; // (assetId, country) => true/false
    mapping(uint256 => bytes32[]) public automaticProtectionCountries;           // enumeration
    mapping(uint256 => bytes32[]) public manualRegistrationCountries;            // enumeration

    // Indices by status
    mapping(bytes32 => uint256[]) public assetsByStatus;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(string memory baseURI_, address initialOwner) ERC1155(baseURI_) {
        _transferOwnership(initialOwner);
        pausedFlag = false;
    }

    // -------------------------------------------------------------------------
    // Modifiers/helpers
    // -------------------------------------------------------------------------
    modifier onlyAssetOwner(uint256 assetId) {
        require(isOwner(assetId, _msgSender()), "Not asset owner");
        _;
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Ownership Registry (IOwnershipRegistry)
    // -------------------------------------------------------------------------
    function registerCollectiveOwnership(
        uint256 assetId,
        address[] calldata owners,
        uint256[] calldata ownershipPercentages,
        uint256[] calldata governanceWeights
    ) public whenNotPaused returns (bool) {
        require(owners.length > 0, "At least one owner");
        require(owners.length == ownershipPercentages.length, "len mismatch");
        require(owners.length == governanceWeights.length, "len mismatch");

        uint256 totalP = 0;
        for (uint256 i = 0; i < ownershipPercentages.length; i++) totalP += ownershipPercentages[i];
        require(totalP == 100, "Total ownership must equal 100");

        ownershipInfo[assetId] = OwnershipInfo({
            totalOwners: uint32(owners.length),
            isActive: true,
            registrationTimestamp: _now()
        });

        delete _assetOwners[assetId];
        for (uint256 i = 0; i < owners.length; i++) {
            address o = owners[i];
            ownerPercentage[assetId][o]  = ownershipPercentages[i];
            governanceWeight[assetId][o] = governanceWeights[i];
            _assetOwners[assetId].push(o);
        }

        emit CollectiveOwnershipRegistered(assetId, uint32(owners.length), _now());
        return true;
    }

    function getOwnershipInfo(uint256 assetId) external view returns (OwnershipInfo memory) {
        return ownershipInfo[assetId];
    }

    function getOwnerPercentage(uint256 assetId, address owner_) external view returns (uint256) {
        return ownerPercentage[assetId][owner_];
    }

    function transferOwnershipShare(
        uint256 assetId,
        address from,
        address to,
        uint256 percentage
    ) external whenNotPaused returns (bool) {
        require(_msgSender() == from, "Only owner can transfer share");
        uint256 current = ownerPercentage[assetId][from];
        require(current >= percentage, "Insufficient ownership");

        ownerPercentage[assetId][from] = current - percentage;
        uint256 toCurrent = ownerPercentage[assetId][to];
        ownerPercentage[assetId][to] = toCurrent + percentage;

        if (toCurrent == 0) {
            _assetOwners[assetId].push(to);
            ownershipInfo[assetId].totalOwners += 1;
        }

        // Update governance weight proportionally
        uint256 fromW = governanceWeight[assetId][from];
        uint256 wToTransfer = (fromW * percentage) / current;
        governanceWeight[assetId][from] = fromW - wToTransfer;
        governanceWeight[assetId][to]   = governanceWeight[assetId][to] + wToTransfer;

        emit IPOwnershipTransferred(assetId, from, to, percentage, _now());
        return true;
    }

    function isOwner(uint256 assetId, address addr) public view returns (bool) {
        return ownerPercentage[assetId][addr] > 0;
    }

    function hasGovernanceRights(uint256 assetId, address addr) public view returns (bool) {
        return governanceWeight[assetId][addr] > 0;
    }

    function getGovernanceWeight(uint256 assetId, address owner_) public view returns (uint256) {
        return governanceWeight[assetId][owner_];
    }

    function getAssetOwners(uint256 assetId) public view returns (address[] memory) {
        return _assetOwners[assetId];
    }

    function getAssetCreators(uint256 assetId) public view returns (address[] memory) {
        // In Cairo creators were stored separately; we mirror: creators = first owners registered at creation
        return _assetCreators[assetId];
    }

    // -------------------------------------------------------------------------
    // Asset Manager (IIPAssetManager)
    // -------------------------------------------------------------------------
    function registerIpAsset(
        bytes32 assetType,
        string calldata metadataUri,
        address[] calldata creators,
        uint256[] calldata ownershipPercentages,
        uint256[] calldata governanceWeights
    ) external whenNotPaused onlyOwner returns (uint256) {
        require(creators.length > 0, "At least one creator");
        require(creators.length == ownershipPercentages.length, "len mismatch");
        require(creators.length == governanceWeights.length, "len mismatch");

        uint256 totalP = 0;
        for (uint256 i=0;i<ownershipPercentages.length;i++) totalP += ownershipPercentages[i];
        require(totalP == 100, "Total ownership must equal 100");

        uint256 assetId = nextAssetId++;
        assetInfo[assetId] = IPAssetInfo({
            assetId: assetId,
            assetType: assetType,
            metadataUri: metadataUri,
            totalSupply: STANDARD_INITIAL_SUPPLY,
            creationTimestamp: _now(),
            isVerified: false,
            complianceStatus: _PENDING
        });

        totalAssets += 1;

        // store creators (we mirror Cairo's separate storage)
        delete _assetCreators[assetId];
        for (uint256 i=0;i<creators.length;i++) {
            _assetCreators[assetId].push(creators[i]);
        }

        // register collective ownership (+ owners list)
        registerCollectiveOwnership(assetId, creators, ownershipPercentages, governanceWeights);

        // mint ERC1155 supply to creators pro-rata
        for (uint256 i=0;i<creators.length;i++) {
            uint256 pct = ownershipPercentages[i];
            uint256 amount = (STANDARD_INITIAL_SUPPLY * pct) / 100;
            if (amount > 0) {
                _mint(creators[i], assetId, amount, "");
            }
        }

        emit AssetRegistered(assetId, assetType, uint32(creators.length), _now());
        return assetId;
    }

    function getAssetInfo(uint256 assetId) external view returns (IPAssetInfo memory) {
        return assetInfo[assetId];
    }

    function updateAssetMetadata(uint256 assetId, string calldata newUri) external whenNotPaused onlyAssetOwner(assetId) returns (bool) {
        string memory oldUri = assetInfo[assetId].metadataUri;
        assetInfo[assetId].metadataUri = newUri;
        emit MetadataUpdated(assetId, oldUri, newUri, _msgSender(), _now());
        return true;
    }

    function mintAdditionalTokens(uint256 assetId, address to, uint256 amount) external whenNotPaused onlyAssetOwner(assetId) returns (bool) {
        assetInfo[assetId].totalSupply += amount;
        _mint(to, assetId, amount, "");
        return true;
    }

    function verifyAssetOwnership(uint256 assetId) public view returns (bool) {
        OwnershipInfo memory oi = ownershipInfo[assetId];
        IPAssetInfo  memory ai = assetInfo[assetId];
        if (ai.assetId == 0 || !oi.isActive) return false;
        return true;
    }

    function getTotalSupply(uint256 assetId) external view returns (uint256) {
        return assetInfo[assetId].totalSupply;
    }

    function getAssetURI(uint256 assetId) external view returns (string memory) {
        return assetInfo[assetId].metadataUri;
    }

    function pauseContract() external onlyOwner { _pause(); pausedFlag = true; }
    function unpauseContract() external onlyOwner { _unpause(); pausedFlag = false; }

    // -------------------------------------------------------------------------
    // Revenue Distribution (IRevenueDistribution)
    // -------------------------------------------------------------------------
    function receiveRevenue(uint256 assetId, address token, uint256 amount) external whenNotPaused nonReentrant returns (bool) {
        require(verifyAssetOwnership(assetId), "Invalid asset");
        require(amount > 0, "Amount>0");
        require(token != address(0), "ERC20 token required"); // as in Cairo: ERC20 only

        IERC20(token).transferFrom(_msgSender(), address(this), amount);

        RevenueInfo storage ri = revenue[assetId][token];
        ri.totalReceived += amount;
        ri.accumulated   += amount;

        emit RevenueReceived(assetId, token, amount, _msgSender(), _now());
        return true;
    }

    function distributeRevenue(uint256 assetId, address token, uint256 amount) public whenNotPaused onlyAssetOwner(assetId) nonReentrant returns (bool) {
        require(verifyAssetOwnership(assetId), "Invalid asset");
        require(amount > 0, "Amount>0");

        RevenueInfo storage ri = revenue[assetId][token];
        require(ri.accumulated >= amount, "Insufficient accumulated");
        require(amount >= ri.minimumDistribution, "Below minimum");

        address[] memory owners = _assetOwners[assetId];
        uint256 totalDistributed = 0;

        for (uint256 i=0;i<owners.length;i++) {
            address o = owners[i];
            uint256 pct = ownerPercentage[assetId][o];
            uint256 share = (amount * pct) / 100;

            if (share > 0) {
                pendingRevenue[assetId][o][token] += share;

                OwnerRevenueInfo storage ori = ownerRevenue[assetId][o][token];
                ori.totalEarned += share;

                totalDistributed += share;
            }
        }

        ri.accumulated             -= totalDistributed;
        ri.totalDistributed        += totalDistributed;
        ri.lastDistributionTimestamp = _now();
        ri.distributionCount       += 1;

        emit RevenueDistributed(assetId, token, totalDistributed, uint32(owners.length), _msgSender(), _now());
        return true;
    }

    function distributeAllRevenue(uint256 assetId, address token) external whenNotPaused returns (bool) {
        RevenueInfo memory ri = revenue[assetId][token];
        if (ri.accumulated == 0) return false;
        return distributeRevenue(assetId, token, ri.accumulated);
    }

    function withdrawPendingRevenue(uint256 assetId, address token) external whenNotPaused nonReentrant returns (uint256) {
        require(isOwner(assetId, _msgSender()), "Not owner");
        uint256 pending = pendingRevenue[assetId][_msgSender()][token];
        require(pending > 0, "No pending");

        pendingRevenue[assetId][_msgSender()][token] = 0;

        OwnerRevenueInfo storage ori = ownerRevenue[assetId][_msgSender()][token];
        ori.totalWithdrawn += pending;
        ori.lastWithdrawalTimestamp = _now();

        IERC20(token).transfer(_msgSender(), pending);

        emit RevenueWithdrawn(assetId, _msgSender(), token, pending, _now());
        return pending;
    }

    function getAccumulatedRevenue(uint256 assetId, address token) external view returns (uint256) {
        return revenue[assetId][token].accumulated;
    }

    function getPendingRevenue(uint256 assetId, address owner_, address token) external view returns (uint256) {
        return pendingRevenue[assetId][owner_][token];
    }

    function getTotalRevenueDistributed(uint256 assetId, address token) external view returns (uint256) {
        return revenue[assetId][token].totalDistributed;
    }

    function getOwnerTotalEarned(uint256 assetId, address owner_, address token) external view returns (uint256) {
        return ownerRevenue[assetId][owner_][token].totalEarned;
    }

    function setMinimumDistribution(uint256 assetId, uint256 minAmount, address token) external onlyAssetOwner(assetId) returns (bool) {
        revenue[assetId][token].minimumDistribution = minAmount;
        return true;
    }

    function getMinimumDistribution(uint256 assetId, address token) external view returns (uint256) {
        return revenue[assetId][token].minimumDistribution;
    }

    // -------------------------------------------------------------------------
    // License Manager (ILicenseManager)
    // -------------------------------------------------------------------------
    function createLicenseRequest(
        uint256 assetId,
        address licensee,
        bytes32 licenseType,
        bytes32 usageRights,
        bytes32 territory,
        uint256 licenseFee,
        uint256 royaltyRate,           // bps
        uint64  durationSeconds,
        address paymentToken,
        LicenseTerms calldata terms,
        string  calldata metadataUri
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        require(licensee != address(0), "Bad licensee");
        require(royaltyRate <= 10_000, "royalty>100%");
        uint256 licenseId = nextLicenseId++;

        uint64 endTs = durationSeconds == 0 ? 0 : _now() + durationSeconds;

        bool requiresApproval = _requiresGovernanceApproval(assetId, licenseType, licenseFee);

        licenses[licenseId] = LicenseInfo({
            licenseId: licenseId,
            assetId: assetId,
            licensor: _msgSender(),
            licensee: licensee,
            licenseType: licenseType,
            usageRights: usageRights,
            territory: territory,
            licenseFee: licenseFee,
            royaltyRate: royaltyRate,
            startTimestamp: _now(),
            endTimestamp: endTs,
            isActive: false,
            requiresApproval: requiresApproval,
            isApproved: !requiresApproval,
            paymentToken: paymentToken,
            metadataUri: metadataUri,
            isSuspended: false,
            suspensionEndTimestamp: 0
        });

        licenseTerms[licenseId] = terms;
        assetLicenses[assetId].push(licenseId);

        emit LicenseOfferCreated(licenseId, assetId, licensee, licenseType, licenseFee, requiresApproval, _now());
        return licenseId;
    }

    function approveLicense(uint256 licenseId, bool approve_) external whenNotPaused returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.requiresApproval, "No approval required");
        require(!li.isApproved, "Already processed");
        require(isOwner(li.assetId, _msgSender()), "Only owners");

        li.isApproved = approve_;
        emit LicenseApproved(licenseId, _msgSender(), approve_, _now());
        return true;
    }

    function executeLicense(uint256 licenseId) external whenNotPaused nonReentrant returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only licensee");
        require(li.isApproved, "Not approved");
        require(!li.isActive, "Already active");
        if (li.endTimestamp != 0) require(_now() < li.endTimestamp, "Expired");

        // process payment (license fee) to contract, then auto-distribute to owners
        if (li.licenseFee > 0) {
            _processLicensePayment(licenseId);
        }

        li.isActive = true;
        licenseeLicenses[li.licensee].push(licenseId);

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

    function revokeLicense(uint256 licenseId, string calldata reason) external whenNotPaused onlyAssetOwner(licenses[licenseId].assetId) returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.isActive, "Not active");
        li.isActive = false;
        emit LicenseRevoked(licenseId, _msgSender(), reason, _now());
        return true;
    }

    function suspendLicense(uint256 licenseId, uint64 suspensionDuration) external whenNotPaused onlyAssetOwner(licenses[licenseId].assetId) returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.isActive, "Not active");
        li.isActive = false;
        li.isSuspended = true;
        li.suspensionEndTimestamp = _now() + suspensionDuration;
        emit LicenseSuspended(licenseId, _msgSender(), suspensionDuration, _now());
        return true;
    }

    function transferLicense(uint256 licenseId, address newLicensee) external whenNotPaused returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only licensee");
        require(newLicensee != address(0), "Bad new licensee");
        require(li.isActive, "Must be active");

        address old = li.licensee;
        li.licensee = newLicensee;

        // update royalty info holder
        royalties[licenseId].licensee = newLicensee;

        licenseeLicenses[newLicensee].push(licenseId);
        emit LicenseTransferred(licenseId, old, newLicensee, _now());
        return true;
    }

    function reportUsageRevenue(uint256 licenseId, uint256 revenueAmount, uint256 usageCount) external whenNotPaused returns (bool) {
        LicenseInfo memory li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only licensee");
        require(li.isActive, "Not active");

        LicenseTerms storage t = licenseTerms[licenseId];
        t.currentUsageCount += usageCount;
        if (t.maxUsageCount > 0) {
            require(t.currentUsageCount <= t.maxUsageCount, "Usage limit exceeded");
        }

        RoyaltyInfo storage ri = royalties[licenseId];
        ri.totalRevenueReported += revenueAmount;

        emit UsageReported(licenseId, _msgSender(), revenueAmount, usageCount, _now());
        return true;
    }

    function payRoyalties(uint256 licenseId, uint256 amount) external whenNotPaused nonReentrant returns (bool) {
        LicenseInfo memory li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(_msgSender() == li.licensee, "Only licensee");
        require(amount > 0, "Amount>0");
        require(li.paymentToken != address(0), "ERC20 only");

        IERC20(li.paymentToken).transferFrom(_msgSender(), address(this), amount);

        RoyaltyInfo storage ri = royalties[licenseId];
        ri.totalRoyaltiesPaid += amount;
        ri.lastPaymentTimestamp = _now();
        ri.nextPaymentDue = uint64(_now() + ri.paymentFrequency);

        _distributeLicenseFee(li.assetId, li.paymentToken, amount);

        emit RoyaltyPaid(licenseId, _msgSender(), amount, _now());
        return true;
    }

    function calculateDueRoyalties(uint256 licenseId) external view returns (uint256) {
        LicenseInfo memory li = licenses[licenseId];
        RoyaltyInfo memory ri = royalties[licenseId];
        if (li.royaltyRate == 0) return 0;

        uint256 due = (ri.totalRevenueReported * li.royaltyRate) / 10_000;
        if (due > ri.totalRoyaltiesPaid) return (due - ri.totalRoyaltiesPaid);
        return 0;
    }

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

    function reactivateSuspendedLicense(uint256 licenseId) external whenNotPaused onlyAssetOwner(licenses[licenseId].assetId) returns (bool) {
        LicenseInfo storage li = licenses[licenseId];
        require(li.licenseId != 0, "License not found");
        require(li.isSuspended, "Not suspended");
        li.isActive = true;
        li.isSuspended = false;
        li.suspensionEndTimestamp = 0;
        emit LicenseReactivated(licenseId, _msgSender(), _now());
        return true;
    }

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

    function getLicenseInfo(uint256 licenseId) external view returns (LicenseInfo memory) { return licenses[licenseId]; }
    function getLicenseTerms(uint256 licenseId) external view returns (LicenseTerms memory) { return licenseTerms[licenseId]; }
    function getAssetLicenses(uint256 assetId) external view returns (uint256[] memory) { return assetLicenses[assetId]; }
    function getLicenseeLicenses(address licensee) external view returns (uint256[] memory) { return licenseeLicenses[licensee]; }

    function isLicenseValid(uint256 licenseId) external view returns (bool) {
        LicenseInfo memory li = licenses[licenseId];
        if (li.licenseId == 0 || !li.isActive || !li.isApproved) return false;
        if (li.endTimestamp != 0 && _now() >= li.endTimestamp) return false;

        LicenseTerms memory t = licenseTerms[licenseId];
        if (t.maxUsageCount > 0 && t.currentUsageCount > t.maxUsageCount) return false;
        return true;
    }

    function getRoyaltyInfo(uint256 licenseId) external view returns (RoyaltyInfo memory) { return royalties[licenseId]; }

    function setDefaultLicenseTerms(uint256 assetId, LicenseTerms calldata terms) external onlyAssetOwner(assetId) returns (bool) {
        defaultLicenseTerms[assetId] = terms;
        return true;
    }

    // License proposals (governance-like flow)
    function proposeLicenseTerms(uint256 assetId, LicenseInfo calldata proposed, uint64 votingDuration) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        uint256 pid = nextLicenseProposalId++;
        uint64 vd = _now() + votingDuration;
        uint64 ed = vd + 86_400; // 24h execution window
        licenseProposals[pid] = LicenseProposal({
            proposalId: pid,
            assetId: assetId,
            proposer: _msgSender(),
            votesFor: 0,
            votesAgainst: 0,
            votingDeadline: vd,
            executionDeadline: ed,
            isExecuted: false,
            isCancelled: false
        });
        proposedLicense[pid] = proposed;
        proposalTerms[pid] = defaultLicenseTerms[assetId];
        emit LicenseProposalCreated(pid, assetId, _msgSender(), vd, _now());
        return pid;
    }

    function voteOnLicenseProposal(uint256 proposalId, bool voteFor) external whenNotPaused returns (bool) {
        LicenseProposal storage p = licenseProposals[proposalId];
        require(p.proposalId != 0, "No proposal");
        require(!p.isExecuted && !p.isCancelled, "Closed");
        require(_now() < p.votingDeadline, "Voting ended");
        require(isOwner(p.assetId, _msgSender()), "Only owners");
        require(!licenseProposalHasVoted[proposalId][_msgSender()], "Already voted");

        licenseProposalHasVoted[proposalId][_msgSender()] = true;
        uint256 weight = getGovernanceWeight(p.assetId, _msgSender());
        if (voteFor) p.votesFor += weight; else p.votesAgainst += weight;

        emit LicenseProposalVoted(proposalId, _msgSender(), voteFor, weight, _now());
        return true;
    }

    function executeLicenseProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        LicenseProposal storage p = licenseProposals[proposalId];
        require(p.proposalId != 0, "No proposal");
        require(!p.isExecuted && !p.isCancelled, "Closed");
        require(_now() > p.votingDeadline && _now() <= p.executionDeadline, "Not in exec window");
        require(p.votesFor > p.votesAgainst, "Not passed");

        LicenseInfo memory pl = proposedLicense[proposalId];
        uint256 lid = nextLicenseId++;
        pl.licenseId = lid;
        pl.licensor  = p.proposer;
        pl.isApproved = true;
        pl.isActive   = false;
        pl.isSuspended= false;
        pl.suspensionEndTimestamp = 0;

        licenses[lid] = pl;
        licenseTerms[lid] = proposalTerms[proposalId];
        assetLicenses[p.assetId].push(lid);
        p.isExecuted = true;

        emit LicenseProposalExecuted(proposalId, lid, _msgSender(), _now());
        return true;
    }

    // -------------------------------------------------------------------------
    // Governance (IGovernance)
    // -------------------------------------------------------------------------
    function setGovernanceSettings(uint256 assetId, GovernanceSettings calldata settings) external onlyAssetOwner(assetId) returns (bool) {
        require(settings.defaultQuorumPercentage <= 10_000, "quorum>100%");
        require(settings.emergencyQuorumPercentage <= settings.defaultQuorumPercentage, "bad emergency quorum");
        require(settings.executionDelay >= 3600, "exec delay < 1h");
        governanceSettings[assetId] = settings;
        emit GovernanceSettingsUpdated(assetId, _msgSender(), _now());
        return true;
    }

    function getGovernanceSettings(uint256 assetId) public view returns (GovernanceSettings memory) {
        GovernanceSettings memory s = governanceSettings[assetId];
        if (s.defaultQuorumPercentage == 0) {
            return GovernanceSettings({
                defaultQuorumPercentage: 5000,
                emergencyQuorumPercentage: 3000,
                licenseQuorumPercentage: 4000,
                assetMgmtQuorumPercentage: 6000,
                revenuePolicyQuorumPercentage: 5500,
                defaultVotingDuration: 259_200,   // 3 days
                emergencyVotingDuration: 86_400,  // 1 day
                executionDelay: 86_400            // 1 day
            });
        }
        return s;
    }

    function proposeAssetManagement(
        uint256 assetId,
        AssetManagementProposal calldata data,
        uint64 votingDuration,
        string calldata description
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        uint256 pid = _createGovernanceProposal(assetId, _ASSET_MANAGEMENT, _msgSender(), votingDuration, description);
        assetMgmtProposals[pid] = data;
        return pid;
    }

    function proposeRevenuePolicy(
        uint256 assetId,
        RevenuePolicyProposal calldata data,
        uint64 votingDuration,
        string calldata description
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        uint256 pid = _createGovernanceProposal(assetId, _REVENUE_POLICY, _msgSender(), votingDuration, description);
        revenuePolicyProposals[pid] = data;
        return pid;
    }

    function proposeEmergencyAction(
        uint256 assetId,
        EmergencyProposal calldata data,
        string calldata description
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        GovernanceSettings memory s = getGovernanceSettings(assetId);
        uint256 pid = _createGovernanceProposal(assetId, _EMERGENCY, _msgSender(), s.emergencyVotingDuration, description);
        emergencyProposals[pid] = data;
        return pid;
    }

    function voteOnGovernanceProposal(uint256 proposalId, bool voteFor) external whenNotPaused returns (bool) {
        GovernanceProposal storage p = governanceProposals[proposalId];
        require(p.proposalId != 0, "No proposal");
        require(!p.isExecuted && !p.isCancelled, "Closed");
        require(_now() < p.votingDeadline, "Voting ended");
        require(isOwner(p.assetId, _msgSender()), "Only owners");
        require(!governanceHasVoted[proposalId][_msgSender()], "Already voted");

        governanceHasVoted[proposalId][_msgSender()] = true;
        uint256 weight = getGovernanceWeight(p.assetId, _msgSender());
        if (voteFor) p.votesFor += weight; else p.votesAgainst += weight;

        uint256 totalVotes = p.votesFor + p.votesAgainst;
        if (totalVotes >= p.quorumRequired) {
            emit ProposalQuorumReached(proposalId, totalVotes, p.quorumRequired, _now());
        }
        return true;
    }

    function executeAssetManagementProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        require(_canExecuteProposal(proposalId), "Cannot execute");
        GovernanceProposal memory g = governanceProposals[proposalId];
        AssetManagementProposal memory d = assetMgmtProposals[proposalId];

        governanceProposals[proposalId].isExecuted = true;

        bool mu=false; bool cu=false;
        if (d.updateMetadata) {
            string memory oldUri = assetInfo[g.assetId].metadataUri;
            assetInfo[g.assetId].metadataUri = d.newMetadataUri;
            mu = keccak256(bytes(oldUri)) != keccak256(bytes(d.newMetadataUri));
        }
        if (d.updateCompliance) {
            assetInfo[g.assetId].complianceStatus = d.newComplianceStatus;
            cu = true;
        }

        emit AssetManagementExecuted(proposalId, g.assetId, mu, cu, _msgSender(), _now());
        return true;
    }

    function executeRevenuePolicyProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        require(_canExecuteProposal(proposalId), "Cannot execute");
        GovernanceProposal memory g = governanceProposals[proposalId];
        RevenuePolicyProposal memory d = revenuePolicyProposals[proposalId];

        governanceProposals[proposalId].isExecuted = true;
        RevenueInfo storage ri = revenue[g.assetId][d.tokenAddress];
        ri.minimumDistribution = d.newMinimumDistribution;

        emit RevenuePolicyUpdated(proposalId, g.assetId, d.tokenAddress, d.newMinimumDistribution, _msgSender(), _now());
        return true;
    }

    function executeEmergencyProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        require(_canExecuteProposal(proposalId), "Cannot execute");
        GovernanceProposal memory g = governanceProposals[proposalId];
        EmergencyProposal memory d = emergencyProposals[proposalId];

        governanceProposals[proposalId].isExecuted = true;

        if (d.actionType == "SUSPEND_LICENSE") {
            LicenseInfo storage li = licenses[d.targetId];
            if (li.licenseId != 0 && li.isActive) {
                li.isActive = false;
                li.isSuspended = true;
                li.suspensionEndTimestamp = _now() + d.suspensionDuration;
            }
        } else if (d.actionType == "SUSPEND_ASSET") {
            uint256[] memory lids = assetLicenses[g.assetId];
            for (uint256 i=0;i<lids.length;i++) {
                LicenseInfo storage li = licenses[lids[i]];
                if (li.isActive) {
                    li.isActive = false;
                    li.isSuspended = true;
                    li.suspensionEndTimestamp = _now() + d.suspensionDuration;
                }
            }
        } else if (d.actionType == "EMERGENCY_PAUSE") {
            _pause();
            pausedFlag = true;
        }

        emit EmergencyActionExecuted(proposalId, d.actionType, d.targetId, _msgSender(), _now());
        return true;
    }

    function getGovernanceProposal(uint256 proposalId) external view returns (GovernanceProposal memory) {
        return governanceProposals[proposalId];
    }
    function getAssetManagementProposal(uint256 proposalId) external view returns (AssetManagementProposal memory) {
        return assetMgmtProposals[proposalId];
    }
    function getRevenuePolicyProposal(uint256 proposalId) external view returns (RevenuePolicyProposal memory) {
        return revenuePolicyProposals[proposalId];
    }
    function getEmergencyProposal(uint256 proposalId) external view returns (EmergencyProposal memory) {
        return emergencyProposals[proposalId];
    }

    function checkQuorumReached(uint256 proposalId) public view returns (bool) {
        GovernanceProposal memory p = governanceProposals[proposalId];
        uint256 totalVotes = p.votesFor + p.votesAgainst;
        return totalVotes >= p.quorumRequired;
    }

    function getProposalParticipationRate(uint256 proposalId) external view returns (uint256) {
        GovernanceProposal memory p = governanceProposals[proposalId];
        uint256 totalVotes = p.votesFor + p.votesAgainst;
        if (p.totalVotingWeight == 0) return 0;
        return (totalVotes * 10_000) / p.totalVotingWeight; // bps
    }

    function canExecuteProposal(uint256 proposalId) external view returns (bool) {
        return _canExecuteProposal(proposalId);
    }

    function getActiveProposalsForAsset(uint256 assetId) external view returns (uint256[] memory) {
        uint256[] memory ids = activeProposalsForAsset[assetId];
        // filter out executed/cancelled
        uint256 n=0;
        for (uint256 i=0;i<ids.length;i++){
            GovernanceProposal memory p = governanceProposals[ids[i]];
            if (!p.isExecuted && !p.isCancelled) n++;
        }
        uint256[] memory out=new uint256[](n);
        uint256 k=0;
        for (uint256 i=0;i<ids.length;i++){
            GovernanceProposal memory p = governanceProposals[ids[i]];
            if (!p.isExecuted && !p.isCancelled) { out[k]=ids[i]; k++; }
        }
        return out;
    }

    // -------------------------------------------------------------------------
    // Compliance Berne (IBerneCompliance)
    // -------------------------------------------------------------------------
    function registerComplianceAuthority(
        address authority,
        string calldata name_,
        bytes32[] calldata authorizedCountries,
        bytes32 authorityType,
        string calldata credentialsUri
    ) external onlyOwner returns (bool) {
        require(authority != address(0), "Bad authority");
        require(
            authorityType == "GOVERNMENT" || authorityType == "CERTIFIED_ORG" || authorityType == "LEGAL_EXPERT",
            "Invalid type"
        );

        ComplianceAuthority memory a = ComplianceAuthority({
            authorityAddress: authority,
            authorityName: name_,
            authorizedCountriesCount: uint32(authorizedCountries.length),
            authorityType: authorityType,
            isActive: true,
            verificationCount: 0,
            registrationTimestamp: _now(),
            credentialsUri: credentialsUri
        });
        complianceAuthorities[authority] = a;

        delete authorityCountries[authority];
        for (uint256 i=0;i<authorizedCountries.length;i++){
            bytes32 c = authorizedCountries[i];
            authorityCountryAllowed[authority][c] = true;
            authorityCountries[authority].push(c);
        }

        emit ComplianceAuthorityRegistered(authority, name_, authorityType, uint32(authorizedCountries.length), _now());
        return true;
    }

    function deactivateComplianceAuthority(address authority) external onlyOwner returns (bool) {
        ComplianceAuthority storage a = complianceAuthorities[authority];
        require(a.authorityAddress != address(0), "Not found");
        a.isActive = false;
        return true;
    }

    function getComplianceAuthority(address authority) external view returns (ComplianceAuthority memory) { return complianceAuthorities[authority]; }

    function isAuthorizedForCountry(address authority, bytes32 country) public view returns (bool) {
        ComplianceAuthority memory a = complianceAuthorities[authority];
        if (!a.isActive) return false;
        return authorityCountryAllowed[authority][country];
    }

    function setCountryRequirements(bytes32 country, CountryComplianceRequirements calldata req) external onlyOwner returns (bool) {
        require(country != bytes32(0), "Bad country");
        countryRequirements[country] = req;
        return true;
    }

    function getCountryRequirements(bytes32 country) public view returns (CountryComplianceRequirements memory) {
        CountryComplianceRequirements memory r = countryRequirements[country];
        if (r.countryCode == 0) {
            return CountryComplianceRequirements({
                countryCode: country,
                isBerneSignatory: true,
                automaticProtection: true,
                registrationRequired: false,
                protectionDurationYears: 70,
                noticeRequired: false,
                depositRequired: false,
                translationRightsDuration: 10,
                moralRightsProtected: true
            });
        }
        return r;
    }

    function getBerneSignatoryCountries() external pure returns (bytes32[] memory arr) {
        bytes32[21] memory list = [
            bytes32("US"),bytes32("UK"),bytes32("FR"),bytes32("DE"),bytes32("JP"),
            bytes32("CA"),bytes32("AU"),bytes32("IT"),bytes32("ES"),bytes32("NL"),
            bytes32("SE"),bytes32("CH"),bytes32("NO"),bytes32("DK"),bytes32("FI"),
            bytes32("AT"),bytes32("BE"),bytes32("PT"),bytes32("GR"),bytes32("IE"),
            bytes32("PL")
        ];
        arr = new bytes32[](list.length);
        for (uint i=0;i<list.length;i++) arr[i]=list[i];
    }

    function requestComplianceVerification(
        uint256 assetId,
        bytes32 requestedStatus,
        string calldata evidenceUri,
        bytes32 countryOfOrigin,
        uint64  publicationDate,
        bytes32 workType,
        bool    isOriginalWork,
        address[] calldata authors
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        require(countryOfOrigin != 0, "Country required");
        require(publicationDate > 0, "Publication date required");

        uint256 rid = nextVerificationRequestId++;
        complianceRequests[rid] = ComplianceVerificationRequest({
            requestId: rid,
            assetId: assetId,
            requester: _msgSender(),
            requestedStatus: requestedStatus,
            evidenceUri: evidenceUri,
            countryOfOrigin: countryOfOrigin,
            publicationDate: publicationDate,
            workType: workType,
            isOriginalWork: isOriginalWork,
            authorsCount: uint32(authors.length),
            requestTimestamp: _now(),
            isProcessed: false,
            isApproved: false,
            verifierNotes: ""
        });

        emit ComplianceVerificationRequested(rid, assetId, _msgSender(), requestedStatus, countryOfOrigin, _now());
        return rid;
    }

    function processComplianceVerification(
        uint256 requestId,
        bool approved,
        string calldata verifierNotes,
        uint64 protectionDuration,
        bytes32[] calldata automaticCountries,
        bytes32[] calldata manualRegistration
    ) external whenNotPaused returns (bool) {
        ComplianceAuthority memory a = complianceAuthorities[_msgSender()];
        require(a.isActive, "Not active authority");

        ComplianceVerificationRequest storage r = complianceRequests[requestId];
        require(r.requestId != 0, "Request not found");
        require(!r.isProcessed, "Already processed");
        require(isAuthorizedForCountry(_msgSender(), r.countryOfOrigin), "Not authorized");

        r.isProcessed = true;
        r.isApproved  = approved;
        r.verifierNotes = verifierNotes;

        if (approved) {
            ComplianceRecord memory cr = ComplianceRecord({
                assetId: r.assetId,
                complianceStatus: r.requestedStatus,
                countryOfOrigin: r.countryOfOrigin,
                publicationDate: r.publicationDate,
                registrationAuthority: _msgSender(),
                verificationTimestamp: _now(),
                complianceEvidenceUri: r.evidenceUri,
                automaticProtectionCount: uint32(automaticCountries.length),
                manualRegistrationCount: uint32(manualRegistration.length),
                protectionDuration: protectionDuration,
                isAnonymousWork: false,
                isCollectiveWork: r.authorsCount > 1,
                renewalRequired: protectionDuration > 0,
                nextRenewalDate: protectionDuration > 0 ? uint64(_now() + protectionDuration) : 0
            });

            complianceRecords[r.assetId] = cr;

            // Update asset info
            assetInfo[r.assetId].complianceStatus = r.requestedStatus;

            // Update authority stats
            complianceAuthorities[_msgSender()].verificationCount += 1;

            // Set international protection
            for (uint256 i=0;i<automaticCountries.length;i++){
                internationalProtection[r.assetId][automaticCountries[i]] = true;
                automaticProtectionCountries[r.assetId].push(automaticCountries[i]);
            }
            for (uint256 i=0;i<manualRegistration.length;i++){
                manualRegistrationCountries[r.assetId].push(manualRegistration[i]);
            }

            emit ComplianceVerified(r.assetId, r.requestedStatus, _msgSender(), r.countryOfOrigin, protectionDuration, _now());
        }
        return true;
    }

    function updateComplianceStatus(uint256 assetId, bytes32 newStatus, string calldata evidenceUri) external returns (bool) {
        ComplianceAuthority memory a = complianceAuthorities[_msgSender()];
        require(a.isActive, "Not active authority");

        ComplianceRecord storage cr = complianceRecords[assetId];
        require(cr.assetId != 0, "No record");

        cr.complianceStatus = newStatus;
        cr.complianceEvidenceUri = evidenceUri;
        cr.verificationTimestamp = _now();

        assetInfo[assetId].complianceStatus = newStatus;
        return true;
    }

    function getComplianceRecord(uint256 assetId) external view returns (ComplianceRecord memory) {
        return complianceRecords[assetId];
    }

    function checkProtectionValidity(uint256 assetId, bytes32 country) public view returns (bool) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return false;
        if (cr.protectionDuration > 0) {
            uint64 endTs = cr.publicationDate + uint64(cr.protectionDuration);
            if (_now() >= endTs) return false;
        }
        return internationalProtection[assetId][country];
    }

    function calculateProtectionDuration(bytes32 country, bytes32 /* workType */, uint64 /*publicationDate*/, bool isAnonymous) public view returns (uint64) {
        CountryComplianceRequirements memory req = getCountryRequirements(country);
        uint64 durationYears = uint64(req.protectionDurationYears);
        uint64 secondsPerYear = 31_536_000; // 365d
        if (isAnonymous) return 70 * secondsPerYear;
        return durationYears  * secondsPerYear;
    }

    function checkRenewalRequirements(uint256 assetId) external view returns (bool renewalRequired, uint64 deadline) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return (false, 0);
        return (cr.renewalRequired, cr.nextRenewalDate);
    }

    function renewProtection(uint256 assetId, string calldata renewalEvidenceUri) external onlyAssetOwner(assetId) returns (bool) {
        ComplianceRecord storage cr = complianceRecords[assetId];
        require(cr.assetId != 0, "No record");
        require(cr.renewalRequired, "Not required");

        cr.nextRenewalDate = _now() + 31_536_000; // +1 year
        cr.complianceEvidenceUri = renewalEvidenceUri;
        return true;
    }

    function markProtectionExpired(uint256 assetId) external returns (bool) {
        ComplianceAuthority memory a = complianceAuthorities[_msgSender()];
        require(a.isActive, "Not active authority");
        ComplianceRecord storage cr = complianceRecords[assetId];
        require(cr.assetId != 0, "No record");

        bytes32 prev = cr.complianceStatus;
        cr.complianceStatus = _NON_COMPLIANT;
        assetInfo[assetId].complianceStatus = _NON_COMPLIANT;

        emit ProtectionExpired(assetId, prev, _now(), _now());
        return true;
    }

    function registerInternationalProtection(uint256 assetId, bytes32[] calldata countries, string[] calldata /*evidenceUris*/) external onlyAssetOwner(assetId) returns (bool) {
        require(countries.length > 0, "No countries");
        for (uint256 i=0;i<countries.length;i++){
            bytes32 c = countries[i];
            internationalProtection[assetId][c] = true;
            // We push into automatic list for visibility (closest to Cairo intent)
            automaticProtectionCountries[assetId].push(c);
            emit CrossBorderProtectionUpdated(assetId, c, true, _msgSender(), _now());
        }
        return true;
    }

    struct InternationalProtectionStatus {
        bytes32[] automaticCountries;
        bytes32[] manualCountries;
    }

    // Remplace l’ancienne checkInternationalProtectionStatus(...) par :
    function checkInternationalProtectionStatus(uint256 assetId)
        public
        view
        returns (uint256 automaticCount, uint256 manualCount)
    {
        ComplianceRecord storage cr = complianceRecords[assetId];
        if (cr.assetId == 0) return (0, 0);
        return (
            uint256(cr.automaticProtectionCount),
            uint256(cr.manualRegistrationCount)
        );
    }



    function validateLicenseCompliance(uint256 assetId, bytes32 licenseeCountry, bytes32 licenseTerritory, bytes32 usageRights) external view returns (bool) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return false;

        if (!checkProtectionValidity(assetId, licenseeCountry)) return false;
        if (licenseTerritory != _GLOBAL && !checkProtectionValidity(assetId, licenseTerritory)) return false;

        CountryComplianceRequirements memory req = getCountryRequirements(licenseeCountry);
        if (!req.moralRightsProtected && usageRights == _DERIVATIVE) return false;

        return true;
    }

    function getLicensingRestrictions(uint256 assetId, bytes32 targetCountry)
        public
        view
        returns (bytes32[] memory out)
    {
        // Pas d’enregistrement de conformité -> on renvoie juste NO_COMPLIANCE_RECORD
        ComplianceRecord storage cr = complianceRecords[assetId];
        if (cr.assetId == 0) {
            out = new bytes32[](1);
            out[0] = _NO_COMPLIANCE_RECORD;
            return out;
        }

        // Vérifie la protection
        bool noProt = !checkProtectionValidity(assetId, targetCountry);

        // Récupère les exigences pays
        CountryComplianceRequirements storage req = countryRequirements[targetCountry];

        // Compte d’abord combien de restrictions il y aura
        uint256 count = 0;
        if (noProt) count++;
        if (req.noticeRequired) count++;
        if (!req.moralRightsProtected) count++;
        if (req.registrationRequired && !internationalProtection[assetId][targetCountry]) count++;

        // Alloue le tableau à la bonne taille et le remplit
        out = new bytes32[](count);
        uint256 i = 0;

        if (noProt) {
            out[i++] = _NO_PROTECTION;
            // si pas de protection, les autres restrictions ne changent rien,
            // mais on garde la logique Cairo: on peut s’arrêter ici si tu préfères.
            // return out;
        }
        if (req.noticeRequired)                 out[i++] = _NOTICE_REQUIRED;
        if (!req.moralRightsProtected)          out[i++] = _NO_MORAL_RIGHTS;
        if (req.registrationRequired && !internationalProtection[assetId][targetCountry]) {
            out[i++] = _REGISTRATION_REQUIRED;
        }
    }

    function getComplianceVerificationRequest(uint256 requestId) external view returns (ComplianceVerificationRequest memory) {
        return complianceRequests[requestId];
    }

    function getPendingVerificationRequests(address authority) external view returns (uint256[] memory) {
        // Cairo uses indexed queues by authority; here we filter over *all* requests (simple approach).
        // For big sets you'd index; kept simple for parity focus.
        uint256 total = nextVerificationRequestId - 1;
        uint256[] memory tmp = new uint256[](total);
        uint256 n=0;
        for (uint256 i=1;i<=total;i++){
            ComplianceVerificationRequest memory r = complianceRequests[i];
            if (!r.isProcessed && isAuthorizedForCountry(authority, r.countryOfOrigin)) {
                tmp[n++] = i;
            }
        }
        return _shrinkU(tmp, n);
    }

    function getAssetsByComplianceStatus(bytes32 status) external view returns (uint256[] memory) {
        // Cairo keeps an index; to avoid heavy writes everywhere, we scan.
        // For production, maintain index in state transitions.
        uint256 total = nextAssetId - 1;
        uint256[] memory tmp = new uint256[](total);
        uint256 n=0;
        for (uint256 id=1; id<=total; id++) {
            if (assetInfo[id].assetId != 0 && assetInfo[id].complianceStatus == status) tmp[n++]=id;
        }
        return _shrinkU(tmp, n);
    }

    function getExpiringProtections(uint64 withinDays) external view returns (uint256[] memory) {
        uint64 current = _now();
        uint64 threshold = current + withinDays * 86_400;
        uint256 total = nextAssetId - 1;
        uint256[] memory tmp = new uint256[](total);
        uint256 n=0;

        for (uint256 id=1; id<=total; id++) {
            ComplianceRecord memory cr = complianceRecords[id];
            if (cr.assetId != 0 && cr.renewalRequired) {
                if (cr.nextRenewalDate <= threshold && cr.nextRenewalDate > current) {
                    tmp[n++] = id;
                }
            }
        }
        return _shrinkU(tmp, n);
    }

    function isWorkInPublicDomain(uint256 assetId, bytes32 /*country*/) external view returns (bool) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return false;
        if (cr.protectionDuration > 0) {
            uint64 endTs = cr.publicationDate + uint64(cr.protectionDuration);
            if (_now() >= endTs) return true;
        }
        return false;
    }

    function getMoralRightsStatus(uint256 assetId, bytes32 country) external view returns (bool) {
        CountryComplianceRequirements memory req = getCountryRequirements(country);
        ComplianceRecord memory cr = complianceRecords[assetId];
        return req.moralRightsProtected && cr.assetId != 0 && checkProtectionValidity(assetId, country);
    }

    function getAuthorityCountries(address authority) external view returns (bytes32[] memory) {
        return authorityCountries[authority];
    }

    function getAutomaticProtectionCountries(uint256 assetId) external view returns (bytes32[] memory) {
        return automaticProtectionCountries[assetId];
    }

    function getManualRegistrationCountries(uint256 assetId) external view returns (bytes32[] memory) {
        return manualRegistrationCountries[assetId];
    }

    // -------------------------------------------------------------------------
    // INTERNALS
    // -------------------------------------------------------------------------
    function _createGovernanceProposal(
        uint256 assetId,
        bytes32 proposalType,
        address proposer,
        uint64 votingDuration,
        string memory description
    ) internal returns (uint256) {
        uint256 pid = nextGovernanceProposalId++;
        GovernanceSettings memory s = getGovernanceSettings(assetId);
        uint64 now_ = _now();

        uint256 totalWeight = _calculateTotalVotingWeight(assetId);
        uint256 quorum = _calculateQuorumRequired(proposalType, totalWeight, s);

        GovernanceProposal memory p = GovernanceProposal({
            proposalId: pid,
            assetId: assetId,
            proposalType: proposalType,
            proposer: proposer,
            votesFor: 0,
            votesAgainst: 0,
            totalVotingWeight: totalWeight,
            quorumRequired: quorum,
            votingDeadline: now_ + votingDuration,
            executionDeadline: now_ + votingDuration + s.executionDelay,
            isExecuted: false,
            isCancelled: false,
            description: description
        });

        governanceProposals[pid] = p;
        activeProposalsForAsset[assetId].push(pid);

        emit GovernanceProposalCreated(pid, assetId, proposalType, proposer, quorum, p.votingDeadline, description, now_);
        return pid;
    }

    function _calculateTotalVotingWeight(uint256 assetId) internal view returns (uint256) {
        address[] memory owners = _assetOwners[assetId];
        uint256 total=0;
        for (uint256 i=0;i<owners.length;i++){
            total += governanceWeight[assetId][owners[i]];
        }
        return total;
    }

    function _calculateQuorumRequired(bytes32 proposalType, uint256 totalWeight, GovernanceSettings memory s) internal pure returns (uint256) {
        uint256 q = s.defaultQuorumPercentage;
        if (proposalType == _EMERGENCY) q = s.emergencyQuorumPercentage;
        else if (proposalType == _LICENSE_APPROVAL) q = s.licenseQuorumPercentage;
        else if (proposalType == _ASSET_MANAGEMENT) q = s.assetMgmtQuorumPercentage;
        else if (proposalType == _REVENUE_POLICY) q = s.revenuePolicyQuorumPercentage;
        return (totalWeight * q) / 10_000;
    }

    function _canExecuteProposal(uint256 proposalId) internal view returns (bool) {
        GovernanceProposal memory p = governanceProposals[proposalId];
        if (p.proposalId == 0 || p.isExecuted || p.isCancelled) return false;
        uint64 now_ = _now();
        if (now_ <= p.votingDeadline) return false;
        if (now_ > p.executionDeadline) return false;
        if (!checkQuorumReached(proposalId)) return false;
        if (p.votesFor <= p.votesAgainst) return false;
        return true;
    }

    function _requiresGovernanceApproval(uint256 /*assetId*/, bytes32 licenseType, uint256 licenseFee) internal pure returns (bool) {
        if (licenseType == _EXCLUSIVE || licenseType == _SOLE_EXCLUSIVE) return true;
        if (licenseFee > 500) return true; // same spirit as Cairo
        return false;
    }

    function _processLicensePayment(uint256 licenseId) internal {
        LicenseInfo memory li = licenses[licenseId];
        if (li.licenseFee == 0) return;
        require(li.paymentToken != address(0), "ERC20 only");
        IERC20(li.paymentToken).transferFrom(li.licensee, address(this), li.licenseFee);
        _distributeLicenseFee(li.assetId, li.paymentToken, li.licenseFee);
    }

    function _distributeLicenseFee(uint256 assetId, address token, uint256 amount) internal {
        RevenueInfo storage ri = revenue[assetId][token];
        ri.totalReceived += amount;
        ri.accumulated   += amount;

        // auto-distribute immediately pro-rata
        address[] memory owners = _assetOwners[assetId];
        uint256 distributed=0;
        for (uint256 i=0;i<owners.length;i++){
            address o = owners[i];
            uint256 pct = ownerPercentage[assetId][o];
            uint256 share = (amount * pct) / 100;
            if (share > 0) {
                pendingRevenue[assetId][o][token] += share;
                ownerRevenue[assetId][o][token].totalEarned += share;
                distributed += share;
            }
        }
        ri.accumulated             -= distributed;
        ri.totalDistributed        += distributed;
        ri.lastDistributionTimestamp = _now();
        ri.distributionCount       += 1;
    }

    // helpers for shrinking temp arrays
    function _shrink(bytes32[] memory arr, uint256 n) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i=0;i<n;i++) out[i]=arr[i];
    }
    function _shrinkU(uint256[] memory arr, uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i=0;i<n;i++) out[i]=arr[i];
    }

    // -------------------------------------------------------------------------
    // ERC1155 hooks / pause gate
    // -------------------------------------------------------------------------
    function _beforeTokenTransfer(
        address operator, address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    // -------------------------------------------------------------------------
    // Upgrade stub (to mirror Cairo intent)
    // -------------------------------------------------------------------------
    function upgrade(bytes32 /*newClassHash*/) external view onlyOwner {
        revert("Upgrade not supported; use proxy");
    }
}

/* ========================================================================== */
/* === Mocks bundled in same file (from mock/*.cairo) ======================= */
/* ========================================================================== */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint256 fixedSupply, address recipient) {
        name = name_;
        symbol = symbol_;
        _mint(recipient, fixedSupply);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender]-=amount;
        balanceOf[to]+=amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        allowance[from][msg.sender] = a - amount;
        balanceOf[from]-=amount;
        balanceOf[to]+=amount;
        emit Transfer(from, to, amount);
        return true;
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract ERC1155ReceiverContract is ERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
