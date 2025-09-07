// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20}  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* //////////////////////////////////////////////////////////////
                            INTERFACE
////////////////////////////////////////////////////////////// */
interface IIPMarketplace {
    struct IPUsageRights {
        bool    commercial_use;
        bool    modifications_allowed;
        bool    attribution_required;
        bytes32 geographic_restrictions; // felt252 -> bytes32
        uint64  usage_duration;
        bool    sublicensing_allowed;
        bytes32 industry_restrictions;   // felt252 -> bytes32
    }

    struct DerivativeRights {
        bool    allowed;
        uint16  royalty_share;
        bool    requires_approval;
        uint32  max_derivatives;
    }

    struct IPMetadata {
        bytes32 ipfs_hash;          // felt252 -> bytes32
        bytes32 license_terms;      // felt252 -> bytes32
        address creator;
        uint64  creation_date;
        uint64  last_updated;
        uint32  version;
        bytes32 content_type;       // felt252 -> bytes32
        uint256 derivative_of;
    }

    struct Listing {
        address seller;
        address nft_contract;
        uint256 price;
        address currency; // ERC20 de paiement
        bool    active;
        IPMetadata       metadata;
        uint16           royalty_percentage;      // ex: 250 = 2.5%
        IPUsageRights    usage_rights;
        DerivativeRights derivative_rights;
        uint64           minimum_purchase_duration;
        uint16           bulk_discount_rate;
    }

    // Actions
    function list_item(
        address nft_contract,
        uint256 token_id,
        uint256 price,
        address currency_address,
        bytes32 metadata_hash,
        bytes32 license_terms_hash,
        IPUsageRights calldata usage_rights,
        DerivativeRights calldata derivative_rights
    ) external;

    function unlist_item(address nft_contract, uint256 token_id) external;

    function buy_item(address nft_contract, uint256 token_id) external;

    function update_listing(address nft_contract, uint256 token_id, uint256 new_price) external;

    function update_metadata(
        address nft_contract,
        uint256 token_id,
        bytes32 new_metadata_hash,
        bytes32 new_license_terms_hash
    ) external;

    function register_derivative(
        address nft_contract,
        uint256 parent_token_id,
        bytes32 metadata_hash,
        bytes32 license_terms_hash
    ) external returns (uint256);

    // Views
    function get_listing(address nft_contract, uint256 token_id)
        external
        view
        returns (Listing memory);
}

/* //////////////////////////////////////////////////////////////
                           IMPLEMENTATION
////////////////////////////////////////////////////////////// */
contract IPMarketplace is IIPMarketplace, Ownable, ReentrancyGuard {
    /* ----------------------------- Events ----------------------------- */

    event ItemListed(
        uint256 indexed token_id,
        address indexed nft_contract,
        address seller,
        uint256 price,
        address currency
    );

    event ItemUnlisted(
        uint256 indexed token_id,
        address indexed nft_contract
    );

    event ItemSold(
        uint256 indexed token_id,
        address indexed nft_contract,
        address seller,
        address buyer,
        uint256 price
    );

    event ListingUpdated(
        uint256 indexed token_id,
        address indexed nft_contract,
        uint256 new_price
    );

    event MetadataUpdated(
        uint256 indexed token_id,
        address indexed nft_contract,
        bytes32 new_metadata_hash,
        bytes32 new_license_terms_hash,
        address updater
    );

    event DerivativeRegistered(
        uint256 indexed token_id,
        address indexed nft_contract,
        uint256 parent_token_id,
        address creator
    );

    /* ----------------------------- Storage ---------------------------- */

    // listings[nft][tokenId] => Listing
    mapping(address => mapping(uint256 => Listing)) private _listings;

    // parent ref d’un dérivé: derivatives[nft][tokenId] => (parentNft, parentId)
    struct ParentRef { address nft; uint256 tokenId; }
    mapping(address => mapping(uint256 => ParentRef)) private _derivatives;

    // Frais du marketplace en basis points (ex: 250 = 2.5%)
    uint256 public marketplaceFeeBps;

    // Compteur pour IDs “dérivés” renvoyés par register_derivative (optionnel)
    uint256 public nextTokenId;

    /* ---------------------------- Constructor ------------------------- */

    constructor(uint256 marketplaceFeeBps_) Ownable(msg.sender) {
        marketplaceFeeBps = marketplaceFeeBps_;
        nextTokenId = 0;
    }

    /* -------------------------- Owner controls ------------------------ */

    function setMarketplaceFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= 10_000, "BPS_OOB");
        marketplaceFeeBps = newBps;
    }

    /* ------------------------------ Actions --------------------------- */

    function list_item(
        address nft_contract,
        uint256 token_id,
        uint256 price,
        address currency_address,
        bytes32 metadata_hash,
        bytes32 license_terms_hash,
        IPUsageRights calldata usage_rights,
        DerivativeRights calldata derivative_rights
    ) external override {
        IERC721 nft = IERC721(nft_contract);

        // Vérifier la propriété & l’approbation marketplace
        require(nft.ownerOf(token_id) == msg.sender, "Not token owner");
        require(
            nft.getApproved(token_id) == address(this) ||
            nft.isApprovedForAll(msg.sender, address(this)),
            "Not approved for marketplace"
        );

        // Composer la metadata
        IPMetadata memory md = IPMetadata({
            ipfs_hash:      metadata_hash,
            license_terms:  license_terms_hash,
            creator:        msg.sender,
            creation_date:  uint64(block.timestamp),
            last_updated:   uint64(block.timestamp),
            version:        1,
            content_type:   bytes32(0),
            derivative_of:  0
        });

        // Enregistrer l’annonce
        Listing memory l = Listing({
            seller:       msg.sender,
            nft_contract: nft_contract,
            price:        price,
            currency:     currency_address,
            active:       true,
            metadata:     md,
            royalty_percentage: 250, // 2.5% par défaut (stocké mais non appliqué ici)
            usage_rights: usage_rights,
            derivative_rights: derivative_rights,
            minimum_purchase_duration: 0,
            bulk_discount_rate: 0
        });

        _listings[nft_contract][token_id] = l;

        emit ItemListed(token_id, nft_contract, msg.sender, price, currency_address);
    }

    function unlist_item(address nft_contract, uint256 token_id) external override {
        Listing storage l = _listings[nft_contract][token_id];
        require(l.active, "Listing not active");
        require(l.seller == msg.sender, "Not the seller");

        l.active = false;
        emit ItemUnlisted(token_id, nft_contract);
    }

    function buy_item(address nft_contract, uint256 token_id)
        external
        override
        nonReentrant
    {
        Listing storage l = _listings[nft_contract][token_id];
        require(l.active, "Listing not active");
        require(msg.sender != l.seller, "Seller cannot buy");

        // Paiement ERC20 (price = montant total)
        IERC20 currency = IERC20(l.currency);
        uint256 fee = (l.price * marketplaceFeeBps) / 10_000;
        uint256 toSeller = l.price - fee;

        // Transferts (revert si allowance insuffisante)
        require(currency.transferFrom(msg.sender, l.seller, toSeller), "pay seller failed");
        require(currency.transferFrom(msg.sender, owner(), fee), "pay fee failed");

        // Transfert NFT vendeur -> acheteur
        IERC721(nft_contract).safeTransferFrom(l.seller, msg.sender, token_id);

        l.active = false;

        emit ItemSold(token_id, nft_contract, l.seller, msg.sender, l.price);
    }

    function update_listing(address nft_contract, uint256 token_id, uint256 new_price) external override {
        Listing storage l = _listings[nft_contract][token_id];
        require(l.active, "Listing not active");
        require(l.seller == msg.sender, "Not the seller");

        l.price = new_price;
        emit ListingUpdated(token_id, nft_contract, new_price);
    }

    function update_metadata(
        address nft_contract,
        uint256 token_id,
        bytes32 new_metadata_hash,
        bytes32 new_license_terms_hash
    ) external override {
        Listing storage l = _listings[nft_contract][token_id];
        require(l.metadata.creator == msg.sender, "Not the creator");

        l.metadata.ipfs_hash     = new_metadata_hash;
        l.metadata.license_terms = new_license_terms_hash;
        l.metadata.last_updated  = uint64(block.timestamp);
        unchecked { l.metadata.version += 1; }

        emit MetadataUpdated(
            token_id,
            nft_contract,
            new_metadata_hash,
            new_license_terms_hash,
            msg.sender
        );
    }

    function register_derivative(
        address nft_contract,
        uint256 parent_token_id,
        bytes32 /*metadata_hash*/,
        bytes32 /*license_terms_hash*/
    ) external override returns (uint256) {
        Listing storage parent = _listings[nft_contract][parent_token_id];
        require(parent.derivative_rights.allowed, "Derivatives not allowed");
        require(parent.active, "Parent listing not active");

        uint256 newId = ++nextTokenId;
        _derivatives[nft_contract][newId] = ParentRef({ nft: nft_contract, tokenId: parent_token_id });

        emit DerivativeRegistered(newId, nft_contract, parent_token_id, msg.sender);
        return newId;
    }

    /* ------------------------------- Views ----------------------------- */

    function get_listing(address nft_contract, uint256 token_id)
        external
        view
        override
        returns (Listing memory)
    {
        return _listings[nft_contract][token_id];
    }
}
