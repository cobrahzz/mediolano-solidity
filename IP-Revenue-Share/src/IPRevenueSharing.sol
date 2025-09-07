// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ─────────────────────────────────────────────────────────────────────────────
 *                                Interfaces
 * ──────────────────────────────────────────────────────────────────────────── */

interface IERC20Minimal {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
}

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/* ─────────────────────────────────────────────────────────────────────────────
 *                              IPRevenueSharing
 * ──────────────────────────────────────────────────────────────────────────── */

contract IPRevenueSharing {
    /* --------------------------------- Storage -------------------------------- */
    struct IPMetadata {
        bytes32 ipfs_hash;
        bytes32 license_terms;
        address creator;
        uint64  creation_date;
        uint64  last_updated;
        uint32  version;
    }

    struct FractionalOwnership {
        uint256 total_shares;
        uint256 accrued_revenue;
    }

    struct Listing {
        address seller;
        address nft_contract;
        uint256 token_id;
        uint256 price;
        address currency;
        bool    active;
        IPMetadata          metadata;
        FractionalOwnership fractional;
    }

    struct AssetRef {
        address nft_contract;
        uint256 token_id;
    }

    // (nft, tokenId) => Listing
    mapping(address => mapping(uint256 => Listing)) private _listings;

    // ((nft, tokenId), owner) => shares
    mapping(address => mapping(uint256 => mapping(address => uint256))) private _fractional_shares;

    // currency => last known "internal" contract balance mirror
    mapping(address => uint256) private _contract_balance;

    address public owner;

    // ((nft, tokenId), idx) => owner
    mapping(address => mapping(uint256 => mapping(uint256 => address))) private _fractional_owner_index;

    // (nft, tokenId) => count (uint32 semantics)
    mapping(address => mapping(uint256 => uint32)) private _fractional_owner_count;

    // ((nft, tokenId), owner) => claimed revenue
    mapping(address => mapping(uint256 => mapping(address => uint256))) private _claimed_revenue;

    // ((nft, tokenId), owner) => bool
    mapping(address => mapping(uint256 => mapping(address => bool))) private _is_fractional_owner;

    // user => (index => (nft, tokenId))
    mapping(address => mapping(uint256 => AssetRef)) private _user_ip_assets;

    // user => count
    mapping(address => uint256) private _user_ip_asset_count;

    /* --------------------------------- Events --------------------------------- */
    event IPAssetCreated(address indexed nft_contract, uint256 indexed token_id, address creator);
    event RoyaltyClaimed(uint256 indexed token_id, address owner, uint256 amount);
    event RevenueRecorded(uint256 indexed token_id, uint256 amount);

    /* --------------------------------- Init ----------------------------------- */
    constructor(address _owner) {
        owner = _owner;
    }

    /* --------------------------------- Modifs --------------------------------- */
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /* ----------------------------- Public API (1:1) --------------------------- */

    // create_ip_asset(nft, tokenId, metadata_hash, license_terms_hash, total_shares)
    function create_ip_asset(
        address nft_contract,
        uint256 token_id,
        bytes32 metadata_hash,
        bytes32 license_terms_hash,
        uint256 total_shares
    ) external {
        require(total_shares > 0, "SharesMustbeGreaterThanZero");

        address caller = msg.sender;
        IERC721Minimal nft = IERC721Minimal(nft_contract);
        require(nft.ownerOf(token_id) == caller, "Not Token Owner");

        IPMetadata memory metadata = IPMetadata({
            ipfs_hash: metadata_hash,
            license_terms: license_terms_hash,
            creator: caller,
            creation_date: uint64(block.timestamp),
            last_updated: uint64(block.timestamp),
            version: 1
        });

        FractionalOwnership memory fractional = FractionalOwnership({
            total_shares: total_shares,
            accrued_revenue: 0
        });

        _listings[nft_contract][token_id] = Listing({
            seller: caller,
            nft_contract: nft_contract,
            token_id: token_id,
            price: 0,
            currency: address(0),
            active: false,
            metadata: metadata,
            fractional: fractional
        });

        _fractional_shares[nft_contract][token_id][caller] = total_shares;
        _fractional_owner_index[nft_contract][token_id][0] = caller;
        _fractional_owner_count[nft_contract][token_id] = 1;
        _is_fractional_owner[nft_contract][token_id][caller] = true;

        // user assets
        uint256 count = _user_ip_asset_count[caller];
        _user_ip_assets[caller][count] = AssetRef({nft_contract: nft_contract, token_id: token_id});
        _user_ip_asset_count[caller] = count + 1;

        emit IPAssetCreated(nft_contract, token_id, caller);
    }

    // list_ip_asset(nft, tokenId, price, currency)
    function list_ip_asset(
        address nft_contract,
        uint256 token_id,
        uint256 price,
        address currency_address
    ) external {
        require(price > 0, "Price must be greater than zero");

        Listing memory listing = _listings[nft_contract][token_id];
        require(!listing.active, "Listing already active");

        address caller = msg.sender;
        IERC721Minimal nft = IERC721Minimal(nft_contract);
        require(nft.ownerOf(token_id) == caller, "Not token owner");
        require(
            nft.getApproved(token_id) == address(this) ||
            nft.isApprovedForAll(caller, address(this)),
            "Not approved for marketplace"
        );

        listing.price = price;
        listing.currency = currency_address;
        listing.active = true;
        _listings[nft_contract][token_id] = listing;
    }

    // remove_listing(nft, tokenId)
    function remove_listing(address nft_contract, uint256 token_id) external {
        address caller = msg.sender;
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.seller == caller, "Only seller");
        listing.active = false;
        _listings[nft_contract][token_id] = listing;
    }

    // claim_royalty(nft, tokenId)
    function claim_royalty(address nft_contract, uint256 token_id) external {
        address caller = msg.sender;
        uint256 shares = _fractional_shares[nft_contract][token_id][caller];
        require(shares > 0, "No shares held");

        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.token_id == token_id, "Invalid token_id");

        uint256 total_shares = listing.fractional.total_shares;
        uint256 total_revenue = listing.fractional.accrued_revenue;
        address currency_address = listing.currency;

        uint256 claimed_so_far = _claimed_revenue[nft_contract][token_id][caller];

        // (total_revenue * shares) / total_shares - claimed_so_far
        uint256 entitled = (total_revenue * shares) / total_shares;
        require(entitled > claimed_so_far, "No revenue to claim");
        uint256 claimable = entitled - claimed_so_far;

        IERC20Minimal currency = IERC20Minimal(currency_address);
        uint256 actual_balance = currency.balanceOf(address(this));
        require(actual_balance >= claimable, "Insufficient balance");

        // mirror "contract_balance" map as in Cairo
        _contract_balance[currency_address] = actual_balance - claimable;
        _claimed_revenue[nft_contract][token_id][caller] = claimed_so_far + claimable;

        require(currency.transfer(caller, claimable), "ERC20 transfer failed");

        emit RoyaltyClaimed(token_id, caller, claimable);
    }

    // record_sale_revenue(nft, tokenId, amount) – owner-only
    function record_sale_revenue(address nft_contract, uint256 token_id, uint256 amount) external onlyOwner {
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.token_id == token_id, "Invalid token_id");

        listing.fractional.accrued_revenue = listing.fractional.accrued_revenue + amount;
        address currency_address = listing.currency;
        _listings[nft_contract][token_id] = listing;

        // NOTE: fidèle au Cairo: envoie les fonds vers **le contrat NFT** (et pas vers ce contrat)
        // Cela rendra probablement claim_royalty inopérant si le contrat ici ne détient pas les fonds.
        IERC20Minimal currency = IERC20Minimal(currency_address);
        require(currency.transferFrom(msg.sender, nft_contract, amount), "ERC20 transferFrom failed");

        // met à jour le "compteur interne" comme dans Cairo
        _contract_balance[currency_address] = _contract_balance[currency_address] + amount;

        emit RevenueRecorded(token_id, amount);
    }

    // add_fractional_owner(nft, tokenId, ownerAddr)
    function add_fractional_owner(address nft_contract, uint256 token_id, address new_owner) external {
        address caller = msg.sender;
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.seller == caller || owner == caller, "Not authorized");
        require(listing.token_id == token_id, "Invalid token ID");

        require(!_is_fractional_owner[nft_contract][token_id][new_owner], "Owner already exists");

        uint32 count = _fractional_owner_count[nft_contract][token_id];
        _fractional_owner_index[nft_contract][token_id][count] = new_owner;
        _fractional_owner_count[nft_contract][token_id] = count + 1;
        _is_fractional_owner[nft_contract][token_id][new_owner] = true;
    }

    // update_fractional_shares(nft, tokenId, owner, new_shares)
    function update_fractional_shares(
        address nft_contract,
        uint256 token_id,
        address target_owner,
        uint256 new_shares
    ) external {
        address caller = msg.sender;
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.seller == caller || owner == caller, "Not authorized");
        require(listing.token_id == token_id, "Invalid token_id");

        uint256 caller_shares = _fractional_shares[nft_contract][token_id][caller];
        require(caller_shares >= new_shares, "Insufficient shares to transfer");

        uint32 count = _fractional_owner_count[nft_contract][token_id];
        uint256 total_assigned = 0;
        for (uint32 i = 0; i < count; i++) {
            address frac_owner = _fractional_owner_index[nft_contract][token_id][i];
            total_assigned += _fractional_shares[nft_contract][token_id][frac_owner];
        }

        uint256 owner_shares = _fractional_shares[nft_contract][token_id][target_owner];

        // total_after_update = total_assigned - caller_shares + (caller_shares - new_shares) + (owner_shares + new_shares)
        uint256 total_after_update = total_assigned - caller_shares + (caller_shares - new_shares) + (owner_shares + new_shares);
        require(total_after_update <= listing.fractional.total_shares, "Exceeds total shares");

        _fractional_shares[nft_contract][token_id][caller] = caller_shares - new_shares;
        _fractional_shares[nft_contract][token_id][target_owner] = owner_shares + new_shares;
    }

    // get_fractional_owner(nft, tokenId, index) -> address
    function get_fractional_owner(address nft_contract, uint256 token_id, uint32 index) external view returns (address) {
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.token_id == token_id, "Invalid token_id");
        uint32 count = _fractional_owner_count[nft_contract][token_id];
        require(index < count, "Index out of bounds");
        return _fractional_owner_index[nft_contract][token_id][index];
    }

    function get_fractional_owner_count(address nft_contract, uint256 token_id) external view returns (uint32) {
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.token_id == token_id, "Invalid token_id");
        return _fractional_owner_count[nft_contract][token_id];
    }

    function get_fractional_shares(address nft_contract, uint256 token_id, address who) external view returns (uint256) {
        Listing memory listing = _listings[nft_contract][token_id];
        require(listing.token_id == token_id, "Invalid token_id");
        return _fractional_shares[nft_contract][token_id][who];
    }

    function get_contract_balance(address currency) external view returns (uint256) {
        return _contract_balance[currency];
    }

    function get_claimed_revenue(address nft_contract, uint256 token_id, address who) external view returns (uint256) {
        return _claimed_revenue[nft_contract][token_id][who];
    }

    function get_user_ip_asset(address user, uint256 index) external view returns (address, uint256) {
        AssetRef memory r = _user_ip_assets[user][index];
        return (r.nft_contract, r.token_id);
    }

    function get_user_ip_asset_count(address user) external view returns (uint256) {
        return _user_ip_asset_count[user];
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
 *                                   Mediolano
 *   ERC-721 minimal : mint(), ownerOf(), getApproved(), isApprovedForAll()
 * ──────────────────────────────────────────────────────────────────────────── */

contract Mediolano {
    /* metadata */
    string public name;
    string public symbol;
    string private _baseURI;

    /* ownership */
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;

    /* approvals */
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed to, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    constructor(string memory base_uri_) {
        name = "Mediolano";
        symbol = "MED";
        _baseURI = base_uri_;
    }

    /* core views */
    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "Nonexistent");
        return o;
    }
    function balanceOf(address owner_) external view returns (uint256) { return _balanceOf[owner_]; }
    function tokenURI(uint256 /*id*/) external view returns (string memory) { return _baseURI; }

    /* approvals */
    function getApproved(uint256 tokenId) external view returns (address) { return _tokenApprovals[tokenId]; }
    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }
    function approve(address to, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "Not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }
    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /* mint (no access control, fidèle à l’exemple Cairo qui expose mint via composant) */
    function mint(address to, uint256 tokenId) external {
        require(to != address(0), "Zero to");
        require(_ownerOf[tokenId] == address(0), "Already minted");
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
 *                                   MockERC20
 *   ERC-20 minimal : constructor(name,symbol,fixed_supply,recipient)
 * ──────────────────────────────────────────────────────────────────────────── */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) private _balanceOf;
    mapping(address => mapping(address => uint256)) private _allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint256 fixed_supply, address recipient) {
        name = name_;
        symbol = symbol_;
        _mint(recipient, fixed_supply);
    }

    /* views */
    function balanceOf(address a) external view returns (uint256) { return _balanceOf[a]; }
    function allowance(address o, address s) external view returns (uint256) { return _allowance[o][s]; }

    /* core */
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = _allowance[from][msg.sender];
        require(a >= value, "insufficient allowance");
        _allowance[from][msg.sender] = a - value;
        _transfer(from, to, value);
        return true;
    }

    /* internals */
    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "zero to");
        uint256 b = _balanceOf[from];
        require(b >= value, "insufficient balance");
        _balanceOf[from] = b - value;
        _balanceOf[to]   += value;
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        require(to != address(0), "zero to");
        totalSupply += value;
        _balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}
