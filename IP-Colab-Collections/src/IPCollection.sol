// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPCollection – port Solidity du contrat Cairo (contributions, vérif, mint, marketplace, co-création)
contract IPCollection {
    // --------- Types ----------
    struct ContributionType {
        bytes32 typeId;
        uint8 minQualityScore;
        uint64 submissionDeadline;
        uint256 maxSupply;
    }

    struct Contribution {
        address contributor;
        string assetURI;
        string metadata;
        bytes32 contributionType;
        uint8 qualityScore;
        uint64 submissionTime;
        bool verified;
        bool minted;
        uint64 timestamp;
        // Marketplace
        bool listed;
        uint256 price;
        // Collaboration
        address coCreator;
        uint8 royaltyPercentage;
    }

    // --------- Storage ----------
    address public owner;
    uint256 private _contributionsCount;

    mapping(uint256 => Contribution) private _contributions;
    mapping(address => uint256) private _contributorCount;
    mapping(address => mapping(uint256 => uint256)) private _contributorContributions;

    mapping(address => bool) private _verifiers;

    mapping(bytes32 => ContributionType) private _types;
    mapping(bytes32 => uint256) private _typeCounts;

    // --------- Events ----------
    event ContributionSubmitted(uint256 indexed contributionId, address contributor, string assetURI);
    event ContributionVerified(uint256 indexed contributionId, bool verified, uint8 qualityScore);
    event NFTMinted(uint256 indexed contributionId, address recipient);
    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event BatchSubmitted(uint256 indexed count, address contributor);
    event TypeRegistered(bytes32 indexed typeId, uint8 minQualityScore, uint64 submissionDeadline, uint256 maxSupply);
    event ContributionListed(uint256 indexed contributionId, uint256 price);
    event ContributionUnlisted(uint256 indexed contributionId);
    event PriceUpdated(uint256 indexed contributionId, uint256 newPrice);
    event CoCreatorAdded(uint256 indexed contributionId, address coCreator, uint8 royaltyPercentage);

    // --------- Constructor ----------
    constructor(address owner_) {
        owner = owner_;
        _verifiers[owner_] = true;
    }

    // --------- Modifiers ----------
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // --------- External / Public API (port de l'interface Cairo) ----------

    // Type management
    function registerContributionType(
        bytes32 typeId,
        uint8 minQualityScore,
        uint64 submissionDeadline,
        uint256 maxSupply
    ) external onlyOwner {
        _types[typeId] = ContributionType({
            typeId: typeId,
            minQualityScore: minQualityScore,
            submissionDeadline: submissionDeadline,
            maxSupply: maxSupply
        });
        _typeCounts[typeId] = 0;

        emit TypeRegistered(typeId, minQualityScore, submissionDeadline, maxSupply);
    }

    function getContributionType(bytes32 typeId) external view returns (ContributionType memory) {
        return _types[typeId];
    }

    // Core contribution functions
    function submitContribution(
        string calldata assetURI,
        string calldata metadata,
        bytes32 contributionType
    ) public {
        ContributionType memory t = _types[contributionType];
        // En Cairo: lecture du type puis assert sur la deadline et max supply.
        // Si le type n'existe pas, deadline=0 -> revert "Deadline passed".
        require(block.timestamp <= t.submissionDeadline, "Deadline passed");
        require(_typeCounts[contributionType] < t.maxSupply, "Max supply reached");

        uint256 id = _contributionsCount + 1;

        _contributions[id] = Contribution({
            contributor: msg.sender,
            assetURI: assetURI,
            metadata: metadata,
            contributionType: contributionType,
            qualityScore: 0,
            submissionTime: uint64(block.timestamp),
            verified: false,
            minted: false,
            timestamp: uint64(block.timestamp),
            listed: false,
            price: 0,
            coCreator: address(0),
            royaltyPercentage: 0
        });

        uint256 n = _contributorCount[msg.sender] + 1;
        _contributorCount[msg.sender] = n;
        _contributorContributions[msg.sender][n] = id;

        _typeCounts[contributionType] += 1;
        _contributionsCount = id;

        emit ContributionSubmitted(id, msg.sender, assetURI);
    }

    function verifyContribution(
        uint256 contributionId,
        bool verified,
        uint8 qualityScore
    ) external {
        require(_verifiers[msg.sender], "Not authorized");

        Contribution memory c = _contributions[contributionId];
        require(!c.minted, "Already minted");

        ContributionType memory t = _types[c.contributionType];
        require(qualityScore >= t.minQualityScore, "Quality score too low");

        c.verified = verified;
        c.qualityScore = qualityScore;
        c.timestamp = uint64(block.timestamp);
        _contributions[contributionId] = c;

        emit ContributionVerified(contributionId, verified, qualityScore);
    }

    function mintNFT(uint256 contributionId, address recipient) external {
        Contribution memory c = _contributions[contributionId];
        require(c.verified, "Not verified");
        require(!c.minted, "Already minted");

        c.minted = true;
        c.timestamp = uint64(block.timestamp);
        _contributions[contributionId] = c;

        emit NFTMinted(contributionId, recipient);
    }

    // Batch operations
    function batchSubmitContributions(
        string[] calldata assets,
        string[] calldata metadatas,
        bytes32[] calldata types_
    ) external {
        require(assets.length == metadatas.length && assets.length == types_.length, "Length mismatch");

        for (uint256 i = 0; i < assets.length; i++) {
            submitContribution(assets[i], metadatas[i], types_[i]);
        }

        emit BatchSubmitted(assets.length, msg.sender);
    }

    // Query functions
    function getContribution(uint256 contributionId) external view returns (Contribution memory) {
        return _contributions[contributionId];
    }

    function getContributionsCount() external view returns (uint256) {
        return _contributionsCount;
    }

    function getContributorContributions(address contributor) external view returns (uint256[] memory) {
        uint256 count = _contributorCount[contributor];
        uint256[] memory ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = _contributorContributions[contributor][i + 1];
        }
        return ids;
    }

    // Access control (verifiers)
    function isVerifier(address account) external view returns (bool) {
        return _verifiers[account];
    }

    function addVerifier(address verifier) external onlyOwner {
        _verifiers[verifier] = true;
        emit VerifierAdded(verifier);
    }

    function removeVerifier(address verifier) external onlyOwner {
        _verifiers[verifier] = false;
        emit VerifierRemoved(verifier);
    }

    // Marketplace
    function listContribution(uint256 contributionId, uint256 price) external {
        Contribution memory c = _contributions[contributionId];
        require(c.verified, "Not verified");
        require(c.minted, "Not minted");
        require(!c.listed, "Already listed");
        require(msg.sender == c.contributor || msg.sender == c.coCreator, "Not authorized");

        c.listed = true;
        c.price = price;
        c.timestamp = uint64(block.timestamp);
        _contributions[contributionId] = c;

        emit ContributionListed(contributionId, price);
    }

    function unlistContribution(uint256 contributionId) external {
        Contribution memory c = _contributions[contributionId];
        require(c.listed, "Not listed");
        require(msg.sender == c.contributor || msg.sender == c.coCreator, "Not authorized");

        c.listed = false;
        c.price = 0;
        c.timestamp = uint64(block.timestamp);
        _contributions[contributionId] = c;

        emit ContributionUnlisted(contributionId);
    }

    function updatePrice(uint256 contributionId, uint256 newPrice) external {
        Contribution memory c = _contributions[contributionId];
        require(c.listed, "Not listed");
        require(msg.sender == c.contributor || msg.sender == c.coCreator, "Not authorized");

        c.price = newPrice;
        c.timestamp = uint64(block.timestamp);
        _contributions[contributionId] = c;

        emit PriceUpdated(contributionId, newPrice);
    }

    // Collaboration
    function addCoCreator(
        uint256 contributionId,
        address coCreator,
        uint8 royaltyPercentage
    ) external {
        Contribution memory c = _contributions[contributionId];
        require(msg.sender == c.contributor, "Not contributor");
        require(royaltyPercentage <= 100, "Invalid royalty");
        require(c.coCreator == address(0), "Co-creator exists");

        c.coCreator = coCreator;
        c.royaltyPercentage = royaltyPercentage;
        c.timestamp = uint64(block.timestamp);
        _contributions[contributionId] = c;

        emit CoCreatorAdded(contributionId, coCreator, royaltyPercentage);
    }
}
