// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OwnershipRegistry.sol";

abstract contract IPAssetManager is OwnershipRegistry {
    // Asset details struct
    struct IPAssetInfo {
        uint256 assetId;
        bytes32 assetType;
        string  metadataUri;
        uint256 totalSupply;
        uint64  creationTimestamp;
        bool    isVerified;
        bytes32 complianceStatus;
    }

    // Events for asset registration and updates
    event AssetRegistered(uint256 indexed assetId, bytes32 assetType, uint32 totalCreators, uint64 timestamp);
    event MetadataUpdated(uint256 indexed assetId, string oldMetadata, string newMetadata, address updatedBy, uint64 timestamp);

    // Asset storage
    uint256 public nextAssetId = 1;
    uint256 public totalAssets;
    bool    public pausedFlag;  // Mirror pause state
    mapping(uint256 => IPAssetInfo) public assetInfo;
    mapping(uint256 => address[]) internal _assetCreators;  // Initially registered creators for each asset

    // Register a new IP asset with initial collective ownership and token supply
    function registerIpAsset(
        bytes32 assetType,
        string calldata metadataUri,
        address[] calldata creators,
        uint256[] calldata ownershipPercentages,
        uint256[] calldata governanceWeights
    ) external whenNotPaused onlyOwner returns (uint256) {
        require(creators.length > 0, "At least one creator");
        require(creators.length == ownershipPercentages.length, "Length mismatch");
        require(creators.length == governanceWeights.length, "Length mismatch");

        uint256 totalP = 0;
        for (uint256 i = 0; i < ownershipPercentages.length; i++) {
            totalP += ownershipPercentages[i];
        }
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

        // Record initial creators of the asset
        delete _assetCreators[assetId];
        for (uint256 i = 0; i < creators.length; i++) {
            _assetCreators[assetId].push(creators[i]);
        }

        // Register collective ownership and distribute initial governance weight
        registerCollectiveOwnership(assetId, creators, ownershipPercentages, governanceWeights);

        // Mint initial token supply pro-rata to creators
        for (uint256 i = 0; i < creators.length; i++) {
            uint256 pct = ownershipPercentages[i];
            uint256 amount = (STANDARD_INITIAL_SUPPLY * pct) / 100;
            if (amount > 0) {
                _mint(creators[i], assetId, amount, "");
            }
        }

        emit AssetRegistered(assetId, assetType, uint32(creators.length), _now());
        return assetId;
    }

    // View asset info and metadata
    function getAssetInfo(uint256 assetId) external view returns (
        uint256 assetIdOut,
        bytes32 assetType,
        uint256 totalSupply,
        uint64  creationTimestamp,
        bool    isVerified,
        bytes32 complianceStatus
    ) {
        IPAssetInfo storage ai = assetInfo[assetId];
        return (
            ai.assetId,
            ai.assetType,
            ai.totalSupply,
            ai.creationTimestamp,
            ai.isVerified,
            ai.complianceStatus
        );
    }

    function getAssetURI(uint256 assetId) external view returns (string memory) {
        return assetInfo[assetId].metadataUri;
    }

    // Update asset metadata URI (only asset owners can update)
    function updateAssetMetadata(uint256 assetId, string calldata newUri) external whenNotPaused onlyAssetOwner(assetId) returns (bool) {
        string memory oldUri = assetInfo[assetId].metadataUri;
        assetInfo[assetId].metadataUri = newUri;
        emit MetadataUpdated(assetId, oldUri, newUri, _msgSender(), _now());
        return true;
    }

    // Mint additional tokens for an asset (requires an asset owner)
    function mintAdditionalTokens(uint256 assetId, address to, uint256 amount) external whenNotPaused onlyAssetOwner(assetId) returns (bool) {
        assetInfo[assetId].totalSupply += amount;
        _mint(to, assetId, amount, "");
        return true;
    }

    // Verify that an asset exists and ownership is active
    function verifyAssetOwnership(uint256 assetId) public view returns (bool) {
        OwnershipInfo memory oi = ownershipInfo[assetId];
        IPAssetInfo  memory ai = assetInfo[assetId];
        if (ai.assetId == 0 || !oi.isActive) return false;
        return true;
    }

    function getTotalSupply(uint256 assetId) external view returns (uint256) {
        return assetInfo[assetId].totalSupply;
    }

    // Backwards-compatible alias for getAssetURI
    function getAssetURIDeprecated(uint256 assetId) external view returns (string memory) {
        return assetInfo[assetId].metadataUri;
    }

    // Pause/unpause controls (owner only)
    function pauseContract() external onlyOwner {
        _pause();
        pausedFlag = true;
    }

    function unpauseContract() external onlyOwner {
        _unpause();
        pausedFlag = false;
    }

    // Return initial creators list for an asset
    function getAssetCreators(uint256 assetId) external view returns (address[] memory) {
        return _assetCreators[assetId];
    }
}
