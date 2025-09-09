// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPAssetManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract RevenueDistribution is IPAssetManager {
    // Revenue tracking per asset and token
    struct RevenueInfo {
        uint256 totalReceived;
        uint256 totalDistributed;
        uint256 accumulated;
        uint64  lastDistributionTimestamp;
        uint256 minimumDistribution;
        uint32  distributionCount;
    }

    // Owner-specific revenue info
    struct OwnerRevenueInfo {
        uint256 totalEarned;
        uint256 totalWithdrawn;
        uint64  lastWithdrawalTimestamp;
    }

    // Events for revenue operations
    event RevenueReceived(uint256 indexed assetId, address indexed token, uint256 amount, address from, uint64 timestamp);
    event RevenueDistributed(uint256 indexed assetId, address indexed token, uint256 totalAmount, uint32 recipientsCount, address distributedBy, uint64 timestamp);
    event RevenueWithdrawn(uint256 indexed assetId, address indexed owner, address indexed token, uint256 amount, uint64 timestamp);

    // Revenue storage
    mapping(uint256 => mapping(address => RevenueInfo)) public revenue;            // assetId -> token -> revenue info
    mapping(uint256 => mapping(address => mapping(address => uint256))) public pendingRevenue;   // assetId -> owner -> token -> amount pending withdrawal
    mapping(uint256 => mapping(address => mapping(address => OwnerRevenueInfo))) public ownerRevenue; // assetId -> owner -> token -> cumulative earnings info

    // Accept revenue (in an ERC20 token) for a given asset
    function receiveRevenue(uint256 assetId, address token, uint256 amount) external whenNotPaused nonReentrant returns (bool) {
        require(verifyAssetOwnership(assetId), "Invalid asset");
        require(amount > 0, "Amount must be > 0");
        require(token != address(0), "Token address required");

        // Transfer the revenue amount from sender to this contract
        IERC20(token).transferFrom(_msgSender(), address(this), amount);

        // Update revenue records
        RevenueInfo storage ri = revenue[assetId][token];
        ri.totalReceived += amount;
        ri.accumulated   += amount;

        emit RevenueReceived(assetId, token, amount, _msgSender(), _now());
        return true;
    }

    // Distribute accumulated revenue to all asset owners (in proportion to ownership percentage)
    function distributeRevenue(uint256 assetId, address token, uint256 amount) public whenNotPaused onlyAssetOwner(assetId) nonReentrant returns (bool) {
        require(verifyAssetOwnership(assetId), "Invalid asset");
        require(amount > 0, "Amount must be > 0");

        RevenueInfo storage ri = revenue[assetId][token];
        require(ri.accumulated >= amount, "Insufficient accumulated revenue");
        require(amount >= ri.minimumDistribution, "Amount below minimum distribution");

        address[] memory owners = _assetOwners[assetId];
        uint256 totalDistributed = 0;
        uint32 ownersCount = uint32(owners.length);

        // Distribute to each owner based on ownership percentage
        for (uint256 i = 0; i < owners.length; i++) {
            address o = owners[i];
            uint256 pct = ownerPercentage[assetId][o];
            uint256 share = (amount * pct) / 100;
            if (share > 0) {
                pendingRevenue[assetId][o][token] += share;
                ownerRevenue[assetId][o][token].totalEarned += share;
                totalDistributed += share;
            }
        }

        ri.accumulated              -= totalDistributed;
        ri.totalDistributed         += totalDistributed;
        ri.lastDistributionTimestamp = _now();
        ri.distributionCount        += 1;

        emit RevenueDistributed(assetId, token, totalDistributed, ownersCount, _msgSender(), _now());
        return true;
    }

    // Convenience: distribute all accumulated revenue for an asset/token
    function distributeAllRevenue(uint256 assetId, address token) external whenNotPaused returns (bool) {
        uint256 amount = revenue[assetId][token].accumulated;
        if (amount == 0) return false;
        return distributeRevenue(assetId, token, amount);
    }

    // Owner withdraws their pending revenue (ERC20 token is transferred to owner)
    function withdrawPendingRevenue(uint256 assetId, address token) external whenNotPaused nonReentrant returns (uint256) {
        require(isOwner(assetId, _msgSender()), "Not an asset owner");
        uint256 pending = pendingRevenue[assetId][_msgSender()][token];
        require(pending > 0, "No pending revenue");

        // Reset pending amount and record withdrawal
        pendingRevenue[assetId][_msgSender()][token] = 0;
        OwnerRevenueInfo storage ori = ownerRevenue[assetId][_msgSender()][token];
        ori.totalWithdrawn += pending;
        ori.lastWithdrawalTimestamp = _now();

        // Transfer the funds to the owner
        IERC20(token).transfer(_msgSender(), pending);

        emit RevenueWithdrawn(assetId, _msgSender(), token, pending, _now());
        return pending;
    }

    // View functions for revenue data
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

    // Set minimum distribution amount for an asset/token (to avoid dust distributions)
    function setMinimumDistribution(uint256 assetId, uint256 minAmount, address token) external onlyAssetOwner(assetId) returns (bool) {
        revenue[assetId][token].minimumDistribution = minAmount;
        return true;
    }

    function getMinimumDistribution(uint256 assetId, address token) external view returns (uint256) {
        return revenue[assetId][token].minimumDistribution;
    }

    // Internal helper: distribute a license fee or royalty to owners immediately (pro-rata)
    function _distributeLicenseFee(uint256 assetId, address token, uint256 amount) internal {
        RevenueInfo storage ri = revenue[assetId][token];
        ri.totalReceived += amount;
        ri.accumulated   += amount;

        address[] memory owners = _assetOwners[assetId];
        uint256 distributed = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            address o = owners[i];
            uint256 pct = ownerPercentage[assetId][o];
            uint256 share = (amount * pct) / 100;
            if (share > 0) {
                pendingRevenue[assetId][o][token] += share;
                ownerRevenue[assetId][o][token].totalEarned += share;
                distributed += share;
            }
        }

        ri.accumulated               -= distributed;
        ri.totalDistributed          += distributed;
        ri.lastDistributionTimestamp  = _now();
        ri.distributionCount         += 1;
    }
}
