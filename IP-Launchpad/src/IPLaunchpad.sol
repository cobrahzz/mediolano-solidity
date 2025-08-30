// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Minimal ERC20 interface (avec name/symbol/decimals + mint comme dans le Cairo)
interface IERC20Like {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    function total_supply() external view returns (uint256); // non standard Cairo-style
    function totalSupply() external view returns (uint256);   // standard helper (Mock en expose les deux)
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transfer_from(address sender, address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function mint(address recipient, uint256 amount) external returns (bool);
}

contract Crowdfunding {
    // ───────────────────── Structs ─────────────────────
    struct Asset {
        address creator;
        uint256 goal;
        uint256 raised;
        uint64 start_time;
        uint64 end_time;
        uint256 base_price;
        bool is_closed;
        uint64 ipfs_hash_len;
    }

    struct Investment {
        uint256 amount;
        uint64 timestamp;
    }

    // ───────────────────── Storage ─────────────────────
    uint64  private _assetCount;     // asset_count
    address private _tokenAddress;   // token_address
    address private _owner;          // owner

    mapping(uint64 => Asset) public assetData;                       // asset_id => Asset
    mapping(uint64 => mapping(uint64 => uint256)) private ipfsParts; // (asset_id, idx) => felt/uint256
    mapping(uint64 => mapping(address => Investment)) public investorData; // (asset_id, investor) => Investment

    // ───────────────────── Events ─────────────────────
    event AssetCreated(
        uint64 assetId,
        address indexed creator,
        uint256 goal,
        uint64 startTime,
        uint64 duration,
        uint256 basePrice,
        uint64 ipfsHashLen,
        uint256[] ipfsHash
    );

    event Funded(
        uint64 indexed assetId,
        address indexed investor,
        uint256 amount,
        uint64 timestamp
    );

    event FundingClosed(
        uint64 indexed assetId,
        uint256 totalRaised,
        bool success
    );

    event CreatorWithdrawal(uint64 indexed assetId, uint256 amount);
    event InvestorWithdrawal(uint64 indexed assetId, address indexed investor, uint256 amount);

    // ───────────────────── Constructor ─────────────────────
    constructor(address owner_, address ipTokenContract_) {
        _owner = owner_;
        _tokenAddress = ipTokenContract_;
        _assetCount = 0;
    }

    // ───────────────────── Core API (même logique que Cairo) ─────────────────────
    function createAsset(
        uint256 goal,
        uint64  duration,
        uint256 basePrice,
        uint256[] calldata ipfsHash
    ) external {
        require(duration > 0, "DURATION_MUST_BE_POSITIVE");
        require(goal > 0, "GOAL_MUST_BE_POSITIVE");
        require(basePrice > 0, "BASE_PRICE_MUST_BE_POSITIVE");

        uint64 start = uint64(block.timestamp);
        uint64 end   = start + duration;
        uint64 assetId = _assetCount;

        assetData[assetId] = Asset({
            creator: msg.sender,
            goal: goal,
            raised: 0,
            start_time: start,
            end_time: end,
            base_price: basePrice,
            is_closed: false,
            ipfs_hash_len: uint64(ipfsHash.length)
        });

        for (uint64 i = 0; i < ipfsHash.length; i++) {
            ipfsParts[assetId][i] = ipfsHash[uint256(i)];
        }

        _assetCount = assetId + 1;

        emit AssetCreated(
            assetId,
            msg.sender,
            goal,
            start,
            duration,
            basePrice,
            uint64(ipfsHash.length),
            ipfsHash
        );
    }

    /// NOTE: fidèle au Cairo → pas de transferFrom ici, uniquement comptable.
    function fund(uint64 assetId, uint256 amount) external {
        Asset storage a = assetData[assetId];
        require(a.start_time != 0, "ASSET_NOT_FOUND");
        require(msg.sender != a.creator, "CREATOR_CANNOT_FUND");
        require(!a.is_closed, "FUNDING_CLOSED");

        uint64 nowTs = uint64(block.timestamp);
        require(nowTs >= a.start_time, "FUNDING_NOT_STARTED");
        require(nowTs < a.end_time, "FUNDING_ENDED");
        require(amount > 0, "AMOUNT_ZERO");

        // Discount
        uint64 timeElapsed     = nowTs - a.start_time;
        uint64 totalDuration   = a.end_time - a.start_time;
        uint64 timeRemainPct   = totalDuration > 0
            ? ((totalDuration - timeElapsed) * 100) / totalDuration
            : 0;

        uint64 maxDiscount = 10;
        uint64 discountPct = timeRemainPct > 0 ? (timeRemainPct * maxDiscount) / 100 : 0;
        // min 10% de remise, comme dans le Cairo (max_u64(discountPct, 10))
        uint64 effectivePct = discountPct > 10 ? discountPct : 10;

        uint256 discountedPrice = _mulDiv(a.base_price, uint256(100 - effectivePct), 100);
        require(amount >= discountedPrice, "INSUFFICIENT_FUNDS");

        Investment storage inv = investorData[assetId][msg.sender];
        inv.amount += amount;
        inv.timestamp = nowTs;

        a.raised += amount;

        emit Funded(assetId, msg.sender, amount, nowTs);
    }

    function close_funding(uint64 assetId) external {
        Asset storage a = assetData[assetId];
        require(a.start_time != 0, "ASSET_NOT_FOUND");
        require(msg.sender == a.creator, "NOT_CREATOR");
        require(!a.is_closed, "FUNDING_ALREADY_CLOSED");

        require(uint64(block.timestamp) > a.end_time, "FUNDING_NOT_ENDED");

        bool success = a.raised >= a.goal;
        a.is_closed = true;

        emit FundingClosed(assetId, a.raised, success);
    }

    /// Transfert ERC20 depuis le solde du contrat → idem Cairo (le contrat doit déjà détenir les tokens)
    function withdraw_creator(uint64 assetId) external {
        Asset storage a = assetData[assetId];
        require(a.start_time != 0, "ASSET_NOT_FOUND");
        require(msg.sender == a.creator, "NOT_CREATOR");
        require(a.is_closed, "FUNDING_NOT_CLOSED");
        require(a.raised >= a.goal, "GOAL_NOT_REACHED");

        uint256 amount = a.raised;
        require(amount > 0, "AMOUNT_TO_TRANSFER_ZERO");

        bool ok = IERC20Like(_tokenAddress).transfer(msg.sender, amount);
        require(ok, "TRANSFER_FAILED");

        // NB: fidèle au Cairo → on NE remet PAS a.raised a 0 (retrait multiple possible si non protégé côté token)
        emit CreatorWithdrawal(assetId, amount);
    }

    function withdraw_investor(uint64 assetId) external {
        Asset storage a = assetData[assetId];
        require(a.start_time != 0, "ASSET_NOT_FOUND");

        Investment storage inv = investorData[assetId][msg.sender];

        require(inv.amount > 0, "NO_INVESTMENT");
        require(a.is_closed, "FUNDING_NOT_CLOSED");
        require(a.raised < a.goal, "GOAL_REACHED");

        uint256 amount = inv.amount;
        require(amount > 0, "AMOUNT_TO_TRANSFER_ZERO");

        bool ok = IERC20Like(_tokenAddress).transfer(msg.sender, amount);
        require(ok, "TRANSFER_FAILED");

        inv.amount = 0;
        inv.timestamp = 0;

        emit InvestorWithdrawal(assetId, msg.sender, amount);
    }

    function set_token_address(address tokenAddress_) external {
        require(msg.sender == _owner, "NOT_CONTRACT_OWNER");
        _tokenAddress = tokenAddress_;
    }

    // ───────────────────── Views (mêmes signatures logiques) ─────────────────────
    function get_asset_count() external view returns (uint64) {
        return _assetCount;
    }

    function get_asset_data(uint64 assetId) external view returns (Asset memory) {
        return assetData[assetId];
    }

    function get_asset_ipfs_hash(uint64 assetId) external view returns (uint256[] memory outHash) {
        Asset storage a = assetData[assetId];
        uint64 n = a.ipfs_hash_len;
        outHash = new uint256[](uint256(n));
        for (uint64 i = 0; i < n; i++) {
            outHash[uint256(i)] = ipfsParts[assetId][i];
        }
    }

    function get_investor_data(uint64 assetId, address investor) external view returns (Investment memory) {
        return investorData[assetId][investor];
    }

    function get_token_address() external view returns (address) {
        return _tokenAddress;
    }

    // ───────────────────── Helpers ─────────────────────
    function _mulDiv(uint256 value, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        require(denominator != 0, "DIVISION_BY_ZERO");
        // "unsafe" comme dans le Cairo (peut revert en overflow sur value*numerator)
        return (value * numerator) / denominator;
    }
}
