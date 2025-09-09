// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LicenseManager.sol";

abstract contract Governance is LicenseManager {
    // Governance proposal structs
    struct GovernanceProposal {
        uint256 proposalId;
        uint256 assetId;
        bytes32 proposalType;
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
        bytes32 actionType;      // e.g., "SUSPEND_ASSET", "SUSPEND_LICENSE", "EMERGENCY_PAUSE"
        uint256 targetId;        // Asset ID or License ID target
        uint64  suspensionDuration;
        string  reason;
    }

    struct GovernanceSettings {
        uint256 defaultQuorumPercentage;       // in basis points (bps)
        uint256 emergencyQuorumPercentage;     // in bps
        uint256 licenseQuorumPercentage;       // in bps
        uint256 assetMgmtQuorumPercentage;     // in bps
        uint256 revenuePolicyQuorumPercentage; // in bps
        uint64  defaultVotingDuration;         // in seconds
        uint64  emergencyVotingDuration;       // in seconds
        uint64  executionDelay;                // in seconds
    }

    // Governance events
    event GovernanceProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed assetId,
        bytes32 proposalType,
        address proposer,
        uint256 quorumRequired,
        uint64  votingDeadline,
        string  description,
        uint64  timestamp
    );
    event ProposalQuorumReached(uint256 indexed proposalId, uint256 totalVotes, uint256 quorumRequired, uint64 timestamp);
    event AssetManagementExecuted(uint256 indexed proposalId, uint256 indexed assetId, bool metadataUpdated, bool complianceUpdated, address executedBy, uint64 timestamp);
    event RevenuePolicyUpdated(uint256 indexed proposalId, uint256 indexed assetId, address tokenAddress, uint256 newMinimumDistribution, address executedBy, uint64 timestamp);
    event EmergencyActionExecuted(uint256 indexed proposalId, bytes32 actionType, uint256 targetId, address executedBy, uint64 timestamp);
    event GovernanceSettingsUpdated(uint256 indexed assetId, address updatedBy, uint64 timestamp);

    // Governance storage
    mapping(uint256 => GovernanceProposal) public governanceProposals;
    mapping(uint256 => AssetManagementProposal) public assetMgmtProposals;
    mapping(uint256 => RevenuePolicyProposal)  public revenuePolicyProposals;
    mapping(uint256 => EmergencyProposal)      public emergencyProposals;
    mapping(uint256 => GovernanceSettings)     public governanceSettings;
    mapping(uint256 => mapping(address => bool)) public governanceHasVoted;
    mapping(uint256 => mapping(address => bool)) public governanceVotes;  // records last vote per voter (optional/unused in logic)
    uint256 public nextGovernanceProposalId = 1;
    mapping(uint256 => uint256[]) public activeProposalsForAsset;

    // Set governance parameters for an asset
    function setGovernanceSettings(uint256 assetId, GovernanceSettings calldata settings) external onlyAssetOwner(assetId) returns (bool) {
        require(settings.defaultQuorumPercentage <= 10_000, "Quorum > 100%");
        require(settings.emergencyQuorumPercentage <= settings.defaultQuorumPercentage, "Emergency quorum too high");
        require(settings.executionDelay >= 3600, "Execution delay < 1h");
        governanceSettings[assetId] = settings;
        emit GovernanceSettingsUpdated(assetId, _msgSender(), _now());
        return true;
    }

    function getGovernanceSettings(uint256 assetId) public view returns (GovernanceSettings memory) {
        GovernanceSettings memory s = governanceSettings[assetId];
        if (s.defaultQuorumPercentage == 0) {
            // Return default settings if not set
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

    // Propose an asset management change (metadata/compliance update) for collective voting
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

    // Propose a revenue distribution policy change for an asset
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

    // Propose an emergency action (suspend asset/licenses or emergency pause) – uses default emergency voting duration
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

    // Vote on an active governance proposal
    function voteOnGovernanceProposal(uint256 proposalId, bool voteFor) external whenNotPaused returns (bool) {
        GovernanceProposal storage p = governanceProposals[proposalId];
        require(p.proposalId != 0, "No proposal");
        require(!p.isExecuted && !p.isCancelled, "Proposal closed");
        require(_now() < p.votingDeadline, "Voting ended");
        require(isOwner(p.assetId, _msgSender()), "Only asset owners can vote");
        require(!governanceHasVoted[proposalId][_msgSender()], "Already voted");

        governanceHasVoted[proposalId][_msgSender()] = true;
        uint256 weight = getGovernanceWeight(p.assetId, _msgSender());
        if (voteFor) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        uint256 totalVotes = p.votesFor + p.votesAgainst;
        if (totalVotes >= p.quorumRequired) {
            emit ProposalQuorumReached(proposalId, totalVotes, p.quorumRequired, _now());
        }
        return true;
    }

    // Execute an asset management proposal after voting passes
    function executeAssetManagementProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        require(_canExecuteProposal(proposalId), "Cannot execute");
        GovernanceProposal memory g = governanceProposals[proposalId];
        AssetManagementProposal memory d = assetMgmtProposals[proposalId];
        governanceProposals[proposalId].isExecuted = true;

        bool metadataUpdated = false;
        bool complianceUpdated = false;
        if (d.updateMetadata) {
            string memory oldUri = assetInfo[g.assetId].metadataUri;
            assetInfo[g.assetId].metadataUri = d.newMetadataUri;
            metadataUpdated = (keccak256(bytes(oldUri)) != keccak256(bytes(d.newMetadataUri)));
        }
        if (d.updateCompliance) {
            assetInfo[g.assetId].complianceStatus = d.newComplianceStatus;
            complianceUpdated = true;
        }

        emit AssetManagementExecuted(proposalId, g.assetId, metadataUpdated, complianceUpdated, _msgSender(), _now());
        return true;
    }

    // Execute a revenue policy proposal after voting passes
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

    // Execute an emergency action after voting passes
    function executeEmergencyProposal(uint256 proposalId) external whenNotPaused returns (bool) {
        require(_canExecuteProposal(proposalId), "Cannot execute");
        GovernanceProposal memory g = governanceProposals[proposalId];
        EmergencyProposal memory d = emergencyProposals[proposalId];
        governanceProposals[proposalId].isExecuted = true;

        if (d.actionType == "SUSPEND_LICENSE") {
            // Suspend a specific license
            LicenseInfo storage li = licenses[d.targetId];
            if (li.licenseId != 0 && li.isActive) {
                li.isActive = false;
                li.isSuspended = true;
                li.suspensionEndTimestamp = _now() + d.suspensionDuration;
            }
        } else if (d.actionType == "SUSPEND_ASSET") {
            // Suspend all licenses of an asset
            uint256[] memory lids = assetLicenses[g.assetId];
            for (uint256 i = 0; i < lids.length; i++) {
                LicenseInfo storage li = licenses[lids[i]];
                if (li.isActive) {
                    li.isActive = false;
                    li.isSuspended = true;
                    li.suspensionEndTimestamp = _now() + d.suspensionDuration;
                }
            }
        } else if (d.actionType == "EMERGENCY_PAUSE") {
            // Pause entire contract in emergency
            _pause();
            pausedFlag = true;
        }

        emit EmergencyActionExecuted(proposalId, d.actionType, d.targetId, _msgSender(), _now());
        return true;
    }

    function getGovernanceProposalA(uint256 proposalId) external view returns (
        uint256 proposalIdOut,
        uint256 assetId,
        bytes32 proposalType,
        address proposer
    ) {
        GovernanceProposal storage p = governanceProposals[proposalId];
        return (p.proposalId, p.assetId, p.proposalType, p.proposer);
    }

    function getGovernanceProposalB(uint256 proposalId) external view returns (
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 totalVotingWeight,
        uint256 quorumRequired
    ) {
        GovernanceProposal storage p = governanceProposals[proposalId];
        return (p.votesFor, p.votesAgainst, p.totalVotingWeight, p.quorumRequired);
    }

    function getGovernanceProposalC(uint256 proposalId) external view returns (
        uint64  votingDeadline,
        uint64  executionDeadline,
        bool    isExecuted,
        bool    isCancelled
    ) {
        GovernanceProposal storage p = governanceProposals[proposalId];
        return (p.votingDeadline, p.executionDeadline, p.isExecuted, p.isCancelled);
    }


    function getGovernanceProposalDescription(uint256 proposalId) external view returns (string memory) {
        return governanceProposals[proposalId].description;
    }

    function getAssetManagementProposal(uint256 proposalId) external view returns (
        bytes32 newComplianceStatus,
        bool    updateMetadata,
        bool    updateCompliance
    ) {
        AssetManagementProposal storage p = assetMgmtProposals[proposalId];
        return (p.newComplianceStatus, p.updateMetadata, p.updateCompliance);
    }

    function getAssetManagementProposalUri(uint256 proposalId) external view returns (string memory) {
        return assetMgmtProposals[proposalId].newMetadataUri;
    }

    function getRevenuePolicyProposal(uint256 proposalId) external view returns (RevenuePolicyProposal memory) {
        return revenuePolicyProposals[proposalId];
    }

    function getEmergencyProposal(uint256 proposalId) external view returns (
        bytes32 actionType,
        uint256 targetId,
        uint64  suspensionDuration
    ) {
        EmergencyProposal storage e = emergencyProposals[proposalId];
        return (e.actionType, e.targetId, e.suspensionDuration);
    }

    function getEmergencyProposalReason(uint256 proposalId) external view returns (string memory) {
        return emergencyProposals[proposalId].reason;
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
        return (totalVotes * 10_000) / p.totalVotingWeight;
    }

    function canExecuteProposal(uint256 proposalId) external view returns (bool) {
        return _canExecuteProposal(proposalId);
    }

    function getActiveProposalsForAsset(uint256 assetId) external view returns (uint256[] memory) {
        uint256[] memory ids = activeProposalsForAsset[assetId];
        uint256[] memory tmp = new uint256[](ids.length);
        uint256 n = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            GovernanceProposal memory p = governanceProposals[ids[i]];
            if (!p.isExecuted && !p.isCancelled) {
                tmp[n++] = ids[i];
            }
        }
        // Trim array to active proposals count
        uint256[] memory activeIds = new uint256[](n);
        for (uint256 j = 0; j < n; j++) {
            activeIds[j] = tmp[j];
        }
        return activeIds;
    }

    // Internal: create a new governance proposal (common to all proposal types)
    function _createGovernanceProposal(
        uint256 assetId,
        bytes32 proposalType,
        address proposer,
        uint64 votingDuration,
        string memory description
    ) internal returns (uint256) {
        uint256 proposalId = nextGovernanceProposalId++;
        GovernanceSettings memory s = getGovernanceSettings(assetId);
        uint64 nowTs = _now();
        uint256 totalWeight = _calculateTotalVotingWeight(assetId);
        uint256 quorum = _calculateQuorumRequired(proposalType, totalWeight, s);

        GovernanceProposal storage p = governanceProposals[proposalId];
        p.proposalId = proposalId;
        p.assetId = assetId;
        p.proposalType = proposalType;
        p.proposer = proposer;
        p.votesFor = 0;
        p.votesAgainst = 0;
        p.totalVotingWeight = totalWeight;
        p.quorumRequired = quorum;
        p.votingDeadline = nowTs + votingDuration;
        p.executionDeadline = nowTs + votingDuration + s.executionDelay;
        p.isExecuted = false;
        p.isCancelled = false;
        p.description = description;
        activeProposalsForAsset[assetId].push(proposalId);

        // Emit event in separate call to avoid stack-depth issues
        _emitGovernanceProposalCreated(proposalId, assetId, proposalType, proposer, quorum, p.votingDeadline, description, nowTs);
        return proposalId;
    }

    function _emitGovernanceProposalCreated(
        uint256 proposalId,
        uint256 assetId,
        bytes32 proposalType,
        address proposer,
        uint256 quorum,
        uint64 votingDeadline,
        string memory description,
        uint64 timestamp
    ) internal {
        emit GovernanceProposalCreated(proposalId, assetId, proposalType, proposer, quorum, votingDeadline, description, timestamp);
    }

    function _calculateTotalVotingWeight(uint256 assetId) internal view returns (uint256) {
        address[] memory owners = _assetOwners[assetId];
        uint256 total = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            total += governanceWeight[assetId][owners[i]];
        }
        return total;
    }

    function _calculateQuorumRequired(bytes32 proposalType, uint256 totalWeight, GovernanceSettings memory s) internal pure returns (uint256) {
        uint256 q = s.defaultQuorumPercentage;
        if (proposalType == _EMERGENCY) {
            q = s.emergencyQuorumPercentage;
        } else if (proposalType == _LICENSE_APPROVAL) {
            q = s.licenseQuorumPercentage;
        } else if (proposalType == _ASSET_MANAGEMENT) {
            q = s.assetMgmtQuorumPercentage;
        } else if (proposalType == _REVENUE_POLICY) {
            q = s.revenuePolicyQuorumPercentage;
        }
        return (totalWeight * q) / 10_000;
    }

    function _canExecuteProposal(uint256 proposalId) internal view returns (bool) {
        GovernanceProposal memory p = governanceProposals[proposalId];
        if (p.proposalId == 0 || p.isExecuted || p.isCancelled) return false;
        uint64 nowTs = _now();
        if (nowTs <= p.votingDeadline) return false;
        if (nowTs > p.executionDeadline) return false;
        if (!checkQuorumReached(proposalId)) return false;
        if (p.votesFor <= p.votesAgainst) return false;
        return true;
    }
}
