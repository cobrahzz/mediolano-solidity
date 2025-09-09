// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseCore.sol";

abstract contract OwnershipRegistry is BaseCore {
    // Ownership information per asset
    struct OwnershipInfo {
        uint32 totalOwners;
        bool   isActive;
        uint64 registrationTimestamp;
    }

    // Events for ownership changes
    event CollectiveOwnershipRegistered(uint256 indexed assetId, uint32 totalOwners, uint64 timestamp);
    event IPOwnershipTransferred(uint256 indexed assetId, address indexed from, address indexed to, uint256 percentage, uint64 timestamp);

    // Ownership mappings
    mapping(uint256 => OwnershipInfo) public ownershipInfo;
    mapping(uint256 => mapping(address => uint256)) public ownerPercentage;   // assetId -> (owner -> ownership percentage)
    mapping(uint256 => mapping(address => uint256)) public governanceWeight;  // assetId -> (owner -> governance weight)
    mapping(uint256 => address[]) internal _assetOwners;                     // assetId -> list of current owners

    // Modifier to restrict actions to asset owners
    modifier onlyAssetOwner(uint256 assetId) {
        require(isOwner(assetId, _msgSender()), "Not asset owner");
        _;
    }

    // Register collective ownership for a new asset (must total 100%)
    function registerCollectiveOwnership(
        uint256 assetId,
        address[] calldata owners,
        uint256[] calldata ownershipPercentages,
        uint256[] calldata governanceWeights
    ) public whenNotPaused returns (bool) {
        require(owners.length > 0, "At least one owner");
        require(owners.length == ownershipPercentages.length, "Length mismatch");
        require(owners.length == governanceWeights.length, "Length mismatch");

        uint256 totalP = 0;
        for (uint256 i = 0; i < ownershipPercentages.length; i++) {
            totalP += ownershipPercentages[i];
        }
        require(totalP == 100, "Total ownership must equal 100");

        ownershipInfo[assetId] = OwnershipInfo({
            totalOwners: uint32(owners.length),
            isActive: true,
            registrationTimestamp: _now()
        });

        // Reset and set up owners list with percentages and weights
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

    // View functions for ownership info
    function getOwnershipInfo(uint256 assetId) external view returns (OwnershipInfo memory) {
        return ownershipInfo[assetId];
    }

    function getOwnerPercentage(uint256 assetId, address owner_) external view returns (uint256) {
        return ownerPercentage[assetId][owner_];
    }

    // Transfer a percentage of ownership from one owner to another
    function transferOwnershipShare(
        uint256 assetId,
        address from,
        address to,
        uint256 percentage
    ) external whenNotPaused returns (bool) {
        require(_msgSender() == from, "Only owner can transfer share");
        uint256 current = ownerPercentage[assetId][from];
        require(current >= percentage, "Insufficient ownership to transfer");

        // Deduct from sender and add to recipient
        ownerPercentage[assetId][from] = current - percentage;
        uint256 toCurrent = ownerPercentage[assetId][to];
        ownerPercentage[assetId][to] = toCurrent + percentage;

        // If the recipient was not an owner before, add to owner list
        if (toCurrent == 0) {
            _assetOwners[assetId].push(to);
            ownershipInfo[assetId].totalOwners += 1;
        }

        // Adjust governance weights proportionally to ownership change
        uint256 fromW = governanceWeight[assetId][from];
        uint256 wToTransfer = (fromW * percentage) / current;
        governanceWeight[assetId][from] = fromW - wToTransfer;
        governanceWeight[assetId][to]   += wToTransfer;

        emit IPOwnershipTransferred(assetId, from, to, percentage, _now());
        return true;
    }

    // Check ownership and governance rights
    function isOwner(uint256 assetId, address addr) public view returns (bool) {
        return ownerPercentage[assetId][addr] > 0;
    }

    function hasGovernanceRights(uint256 assetId, address addr) public view returns (bool) {
        return governanceWeight[assetId][addr] > 0;
    }

    function getGovernanceWeight(uint256 assetId, address owner_) public view returns (uint256) {
        return governanceWeight[assetId][owner_];
    }

    // Return the list of owners for an asset
    function getAssetOwners(uint256 assetId) public view returns (address[] memory) {
        return _assetOwners[assetId];
    }
}
