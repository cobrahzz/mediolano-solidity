// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// ─────────────────────────────────────────────────────────────────────────────
/// Minimal ERC20 / ERC721 interfaces
/// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    /// NOTE: spender is msg.sender
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// ─────────────────────────────────────────────────────────────────────────────
/// Offer model & status
/// ─────────────────────────────────────────────────────────────────────────────

enum OfferStatus {
    Active,
    Accepted,
    Rejected,
    Cancelled
}

struct Offer {
    uint256 id;
    uint256 ip_token_id;
    address creator;
    address owner;
    uint256 payment_amount;
    address payment_token;
    string  license_terms;
    OfferStatus status;
    uint64  created_at;
    uint64  updated_at;
}

/// ─────────────────────────────────────────────────────────────────────────────
/// IPOfferLicensing
/// ─────────────────────────────────────────────────────────────────────────────

contract IPOfferLicensing {
    // Storage
    IERC721 public immutable ipTokenContract;

    // Offers
    mapping(uint256 => Offer) private _offers;        // offerId => Offer
    uint256 public offer_count;                       // starts at 0

    // Indexes
    // ip_token_id => array of offerIds
    mapping(uint256 => uint256[]) private _ipOffers;
    // creator => array of offerIds
    mapping(address => uint256[]) private _creatorOffers;
    // owner   => array of offerIds
    mapping(address => uint256[]) private _ownerOffers;

    // ─── Events (alignés avec Cairo) ─────────────────────────────────────────
    event OfferCreated(
        uint256 indexed offer_id,
        uint256 indexed ip_token_id,
        address indexed creator,
        address owner,
        uint256 payment_amount,
        address payment_token
    );

    event OfferAccepted(
        uint256 indexed offer_id,
        uint256 indexed ip_token_id,
        address indexed creator,
        address owner,
        uint256 payment_amount
    );

    event OfferRejected(
        uint256 indexed offer_id,
        uint256 indexed ip_token_id,
        address indexed creator,
        address owner
    );

    event OfferCancelled(
        uint256 indexed offer_id,
        uint256 indexed ip_token_id,
        address indexed creator
    );

    event RefundClaimed(
        uint256 indexed offer_id,
        uint256 indexed ip_token_id,
        address indexed creator,
        uint256 amount
    );

    constructor(address ipTokenContract_) {
        require(ipTokenContract_ != address(0), "ip token addr zero");
        ipTokenContract = IERC721(ipTokenContract_);
        offer_count = 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: Offer Management
    // ─────────────────────────────────────────────────────────────────────────

    /// Create a new offer (caller must own the IP token).
    function create_offer(
        uint256 ip_token_id,
        uint256 payment_amount,
        address payment_token,
        string calldata license_terms
    ) external returns (uint256) {
        // Validate IP token ownership
        address ownerAddr = ipTokenContract.ownerOf(ip_token_id);
        require(ownerAddr == msg.sender, "Not IP owner");

        uint256 offerId = offer_count;
        unchecked { offer_count = offer_count + 1; }

        Offer memory offer = Offer({
            id: offerId,
            ip_token_id: ip_token_id,
            creator: msg.sender,
            owner: ownerAddr,
            payment_amount: payment_amount,
            payment_token: payment_token,
            license_terms: license_terms,
            status: OfferStatus.Active,
            created_at: uint64(block.timestamp),
            updated_at: uint64(block.timestamp)
        });

        _offers[offerId] = offer;

        // Indexes
        _ipOffers[ip_token_id].push(offerId);
        _creatorOffers[msg.sender].push(offerId);
        _ownerOffers[ownerAddr].push(offerId);

        emit OfferCreated(
            offerId,
            ip_token_id,
            msg.sender,
            ownerAddr,
            payment_amount,
            payment_token
        );

        return offerId;
    }

    /// Accept an active offer (caller must be IP owner).
    /// NOTE: Mirrors the Cairo code: pulls funds from creator -> owner via ERC20.transferFrom.
    function accept_offer(uint256 offer_id) external {
        Offer memory ofr = _mustBeActive(offer_id);
        require(ofr.owner == msg.sender, "Not IP owner");

        IERC20 token = IERC20(ofr.payment_token);
        // Creator must have approved this contract beforehand.
        require(token.transferFrom(ofr.creator, ofr.owner, ofr.payment_amount), "ERC20 transferFrom failed");

        // writeback status
        _setStatus(offer_id, OfferStatus.Accepted);

        emit OfferAccepted(offer_id, ofr.ip_token_id, ofr.creator, ofr.owner, ofr.payment_amount);
    }

    /// Reject an active offer (caller must be IP owner).
    /// NOTE: Kept identical to your Cairo logic (also transfers creator->owner).
    function reject_offer(uint256 offer_id) external {
        Offer memory ofr = _mustBeActive(offer_id);
        require(ofr.owner == msg.sender, "Not IP owner");

        IERC20 token = IERC20(ofr.payment_token);
        require(token.transferFrom(ofr.creator, ofr.owner, ofr.payment_amount), "ERC20 transferFrom failed");

        _setStatus(offer_id, OfferStatus.Rejected);

        emit OfferRejected(offer_id, ofr.ip_token_id, ofr.creator, ofr.owner);
    }

    /// Cancel an active offer (caller must be the creator).
    /// NOTE: Kept identical to your Cairo logic (also transfers creator->owner).
    function cancel_offer(uint256 offer_id) external {
        Offer memory ofr = _mustBeActive(offer_id);
        require(ofr.creator == msg.sender, "Not offer creator");

        IERC20 token = IERC20(ofr.payment_token);
        require(token.transferFrom(ofr.creator, ofr.owner, ofr.payment_amount), "ERC20 transferFrom failed");

        _setStatus(offer_id, OfferStatus.Cancelled);

        emit OfferCancelled(offer_id, ofr.ip_token_id, ofr.creator);
    }

    /// Claim refund for a rejected/cancelled offer (caller must be creator).
    /// NOTE: Mirrors your Cairo code: pays from contract -> creator (requires contract to hold funds).
    function claim_refund(uint256 offer_id) external {
        Offer memory ofr = _offers[offer_id];
        require(ofr.status == OfferStatus.Rejected || ofr.status == OfferStatus.Cancelled, "Offer not refundable");
        require(ofr.creator == msg.sender, "Not offer creator");

        IERC20 token = IERC20(ofr.payment_token);
        require(token.transfer(ofr.creator, ofr.payment_amount), "ERC20 transfer failed");

        emit RefundClaimed(offer_id, ofr.ip_token_id, ofr.creator, ofr.payment_amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    function get_offer(uint256 offer_id) external view returns (Offer memory) {
        return _offers[offer_id];
    }

    function get_offers_by_ip(uint256 ip_token_id) external view returns (uint256[] memory) {
        return _ipOffers[ip_token_id];
    }

    function get_offers_by_creator(address creator) external view returns (uint256[] memory) {
        return _creatorOffers[creator];
    }

    function get_offers_by_owner(address owner) external view returns (uint256[] memory) {
        return _ownerOffers[owner];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _mustBeActive(uint256 offer_id) internal view returns (Offer memory ofr) {
        ofr = _offers[offer_id];
        require(ofr.status == OfferStatus.Active, "Offer not active");
    }

    function _setStatus(uint256 offer_id, OfferStatus s) internal {
        Offer storage ref = _offers[offer_id];
        ref.status = s;
        ref.updated_at = uint64(block.timestamp);
    }
}
