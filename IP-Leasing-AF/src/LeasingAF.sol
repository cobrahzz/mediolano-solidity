// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IIPLeasing} from "./IPLeasingAF.sol";

/**
 * Port Solidity du contrat Cairo `IPLeasing`.
 * - Le token est un ERC1155 interne au contrat.
 * - Les transferts d'IDs en cours de lease sont bloqués via _update (OZ v5),
 *   sauf lorsqu'ils sont initiés « de force » par le contrat (expire/terminate/cancel).
 */
contract IPLeasing is ERC1155, Ownable, ERC1155Holder, IIPLeasing {
    // --- Storage ---

    mapping(uint256 => Lease) private _leases;        // tokenId => lease actif
    mapping(uint256 => LeaseOffer) private _offers;   // tokenId => offre courante

    // indexation simple pour les vues (filtrée à la lecture)
    mapping(address => uint256[]) private _ownerIndexedTokenIds;   // create_lease_offer
    mapping(address => uint256[]) private _lesseeIndexedTokenIds;  // start_lease

    // drapeau interne pour autoriser des transferts « administratifs »
    bool private _forceTransfer;

    // --- Events (mêmes que Cairo) ---
    event LeaseOfferCreated(
        uint256 token_id,
        address owner,
        uint256 amount,
        uint256 lease_fee,
        uint64  duration,
        string  license_terms_uri
    );
    event LeaseOfferCancelled(uint256 token_id, address owner);
    event LeaseStarted(uint256 token_id, address lessee, uint256 amount, uint64 start_time, uint64 end_time);
    event LeaseRenewed(uint256 token_id, address lessee, uint64 new_end_time);
    event LeaseExpired(uint256 token_id, address lessee);
    event LeaseTerminated(uint256 token_id, address lessee, string reason);

    // --- Messages d'erreur (alignés avec Cairo) ---
    string constant INVALID_TOKEN_ID     = "Invalid token ID";
    string constant NOT_TOKEN_OWNER      = "Not token owner";
    string constant INSUFFICIENT_AMOUNT  = "Insufficient amount";
    string constant INVALID_LEASE_FEE    = "Invalid lease fee";
    string constant INVALID_DURATION     = "Invalid duration";
    string constant LEASE_ALREADY_ACTIVE = "Lease already active";
    string constant NO_ACTIVE_LEASE      = "No active lease";
    string constant LEASE_EXPIRED        = "Lease expired";
    string constant NOT_LESSEE           = "Not lessee";
    string constant NO_ACTIVE_OFFER      = "No active offer";
    string constant LEASE_NOT_EXPIRED    = "Lease not expired";

    // --- Constructor ---
    constructor(address owner_, string memory uri_) ERC1155(uri_) Ownable(owner_) {}

    // --- Core logic ---

    function create_lease_offer(
        uint256 token_id,
        uint256 amount,
        uint256 lease_fee,
        uint64  duration,
        string calldata license_terms_uri
    ) external override {
        require(balanceOf(msg.sender, token_id) >= amount, NOT_TOKEN_OWNER);
        require(amount > 0, INSUFFICIENT_AMOUNT);
        require(lease_fee > 0, INVALID_LEASE_FEE);
        require(duration > 0, INVALID_DURATION);
        require(!_leases[token_id].is_active, LEASE_ALREADY_ACTIVE);

        _offers[token_id] = LeaseOffer({
            owner: msg.sender,
            amount: amount,
            lease_fee: lease_fee,
            duration: duration,
            license_terms_uri: license_terms_uri,
            is_active: true
        });

        // Escrow des tokens: vers le contrat
        _safeTransferFrom(msg.sender, address(this), token_id, amount, "");

        // Indexation côté owner
        _ownerIndexedTokenIds[msg.sender].push(token_id);

        emit LeaseOfferCreated(token_id, msg.sender, amount, lease_fee, duration, license_terms_uri);
    }

    function cancel_lease_offer(uint256 token_id) external override {
        LeaseOffer memory offer = _offers[token_id];
        require(offer.is_active, NO_ACTIVE_OFFER);
        require(offer.owner == msg.sender, NOT_TOKEN_OWNER);

        _offers[token_id].is_active = false;

        _forceTransfer = true;
        _safeTransferFrom(address(this), msg.sender, token_id, offer.amount, "");
        _forceTransfer = false;

        emit LeaseOfferCancelled(token_id, msg.sender);
    }

    function start_lease(uint256 token_id) external override {
        LeaseOffer memory offer = _offers[token_id];
        require(offer.is_active, NO_ACTIVE_OFFER);
        require(!_leases[token_id].is_active, LEASE_ALREADY_ACTIVE);

        uint64 start = uint64(block.timestamp);
        uint64 end   = start + offer.duration;

        _leases[token_id] = Lease({
            lessee: msg.sender,
            amount: offer.amount,
            start_time: start,
            end_time: end,
            is_active: true
        });

        _forceTransfer = true;
        _safeTransferFrom(address(this), msg.sender, token_id, offer.amount, "");
        _forceTransfer = false;

        _offers[token_id].is_active = false;

        _lesseeIndexedTokenIds[msg.sender].push(token_id);

        emit LeaseStarted(token_id, msg.sender, offer.amount, start, end);
    }

    function renew_lease(uint256 token_id, uint64 additional_duration) external override {
        Lease memory l = _leases[token_id];
        require(l.is_active, NO_ACTIVE_LEASE);
        require(l.lessee == msg.sender, NOT_LESSEE);
        require(block.timestamp <= l.end_time, LEASE_EXPIRED);
        require(additional_duration > 0, INVALID_DURATION);

        uint64 newEnd = l.end_time + additional_duration;
        _leases[token_id].end_time = newEnd;

        emit LeaseRenewed(token_id, msg.sender, newEnd);
    }

    function expire_lease(uint256 token_id) external override {
        Lease memory l = _leases[token_id];
        require(l.is_active, NO_ACTIVE_LEASE);
        require(block.timestamp > l.end_time, LEASE_NOT_EXPIRED);

        LeaseOffer memory offer = _offers[token_id];
        address owner_ = offer.owner;
        require(owner_ != address(0), INVALID_TOKEN_ID);

        _forceTransfer = true;
        _safeTransferFrom(l.lessee, owner_, token_id, l.amount, "");
        _forceTransfer = false;

        _leases[token_id].is_active = false;

        emit LeaseExpired(token_id, l.lessee);
    }

    function terminate_lease(uint256 token_id, string calldata reason) external override {
        Lease memory l = _leases[token_id];
        require(l.is_active, NO_ACTIVE_LEASE);

        LeaseOffer memory offer = _offers[token_id];
        require(offer.owner == msg.sender, NOT_TOKEN_OWNER);

        _forceTransfer = true;
        _safeTransferFrom(l.lessee, msg.sender, token_id, l.amount, "");
        _forceTransfer = false;

        _leases[token_id].is_active = false;

        emit LeaseTerminated(token_id, l.lessee, reason);
    }

    function mint_ip(address to, uint256 token_id, uint256 amount) external override onlyOwner {
        require(amount > 0, INSUFFICIENT_AMOUNT);
        _mint(to, token_id, amount, "");
    }

    // --- Views ---

    function get_lease(uint256 token_id) external view override returns (Lease memory) {
        return _leases[token_id];
    }

    function get_lease_offer(uint256 token_id) external view override returns (LeaseOffer memory) {
        return _offers[token_id];
    }

    function get_active_leases_by_owner(address owner_) external view override returns (uint256[] memory) {
        uint256[] memory all = _ownerIndexedTokenIds[owner_];
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            if (_leases[all[i]].is_active) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (_leases[all[i]].is_active) out[j++] = all[i];
        }
        return out;
    }

    function get_active_leases_by_lessee(address lessee) external view override returns (uint256[] memory) {
        uint256[] memory all = _lesseeIndexedTokenIds[lessee];
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            if (_leases[all[i]].is_active) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (_leases[all[i]].is_active) out[j++] = all[i];
        }
        return out;
    }

    // --- Hooks (OZ v5) ---

    // Bloque les transferts d’un token loué (hors mint/burn et transferts « administratifs »)
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        if (!_forceTransfer && from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                if (_leases[ids[i]].is_active) {
                    revert("Leased IP cannot be transferred");
                }
            }
        }
        super._update(from, to, ids, values);
    }

    // ERC165 resolution (ERC1155 + ERC1155Holder)
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
