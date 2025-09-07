// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ─────────────────────────────────────────────────────────────────────────────
 * Types & Interfaces (minimales) 
 * ─────────────────────────────────────────────────────────────────────────────
 */

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address owner, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IIPNFT {
    // ERC721 minimal + une fonction mint(owner) -> tokenId (pour le tokenizer)
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function mint(address to) external returns (uint256);
}

interface IIPTokenizerMinimal {
    // Utilisé par le marketplace pour retrouver le propriétaire on-chain d’un token
    function getTokenOwner(uint256 tokenId) external view returns (address);
}

/**
 * ─────────────────────────────────────────────────────────────────────────────
 * Libs OZ
 * ─────────────────────────────────────────────────────────────────────────────
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * ─────────────────────────────────────────────────────────────────────────────
 * Types / Enums / Constantes (version Solidity)
 * ─────────────────────────────────────────────────────────────────────────────
 */

enum AssetType {
    Patent,
    Trademark,
    Copyright,
    TradeSecret
}

enum LicenseTerms {
    Standard,
    Premium,
    Exclusive,
    Custom
}

struct IPAssetData {
    string       metadataURI;
    address      owner;
    AssetType    assetType;
    LicenseTerms licenseTerms;
    uint64       expiryDate;
    bytes32      metadataHash; // ajout pour get_hash()
}

// erreurs / messages (alignés proche de l’intention Cairo)
string constant ERROR_INVALID_PAYMENT       = "Invalid payment amount";
string constant ERROR_INVALID_ASSET         = "Invalid asset";
string constant ERROR_TRANSFER_FAILED       = "Transfer failed";
string constant ERROR_EMPTY_BATCH           = "Empty batch";
string constant ERROR_BATCH_TOO_LARGE       = "Batch too large";
string constant ERROR_INVALID_METADATA      = "Invalid metadata";
string constant ERROR_TOKEN_ID_MISMATCH     = "Token ID mismatch";

// paramètres par défaut
uint32 constant DEFAULT_BATCH_LIMIT = 100;
uint256 constant COMMISSION_FEE_PERCENTAGE = 5; // 5%

/**
 * ─────────────────────────────────────────────────────────────────────────────
 * Marketplace (bulk purchase)
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract IPMarketplace is Ownable, Pausable {
    // Addresses de configuration
    address public tokenizerContract;     // contrat tokenizer (pour getTokenOwner)
    address public acceptedToken;         // ex: STRK/ETH wrapper ERC20
    address public commissionWallet;      // wallet de commission Mediolano

    event BulkPurchaseCompleted(
        address indexed buyer,
        uint256[] assetIds,
        uint256   totalAmount
    );

    event PaymentProcessed(
        address indexed seller,
        uint256 amount,
        uint256 commissionShare
    );

    constructor(
        address owner_,
        address tokenizer_,
        address acceptedToken_,
        address commissionWallet_
    ) Ownable(owner_) {
        tokenizerContract = tokenizer_;
        acceptedToken     = acceptedToken_;
        commissionWallet  = commissionWallet_;
    }

    /**
     * Achat groupé d’actifs tokenisés.
     * - prélève la commission globale,
     * - répartit le reste équitablement entre les vendeurs (propriétaires actuels des tokens).
     */
    function bulk_purchase(
        uint256[] calldata asset_ids,
        uint256 total_amount
    ) external whenNotPaused {
        require(total_amount > 0, ERROR_INVALID_PAYMENT);
        require(asset_ids.length > 0, ERROR_INVALID_ASSET);

        IERC20 pay = IERC20(acceptedToken);
        IIPTokenizerMinimal tokz = IIPTokenizerMinimal(tokenizerContract);

        // Commission globale
        uint256 commission = (total_amount * COMMISSION_FEE_PERCENTAGE) / 100;
        uint256 toDistribute = total_amount - commission;

        // Encaisse la commission
        require(
            pay.transferFrom(msg.sender, commissionWallet, commission),
            ERROR_TRANSFER_FAILED
        );

        // Part égale par asset
        uint256 share = toDistribute / asset_ids.length;

        for (uint256 i = 0; i < asset_ids.length; i++) {
            address seller = tokz.getTokenOwner(asset_ids[i]);
            require(
                pay.transferFrom(msg.sender, seller, share),
                ERROR_TRANSFER_FAILED
            );
            // commission “pro-rata” (facultatif, info event)
            uint256 commissionShare = commission / asset_ids.length;
            emit PaymentProcessed(seller, share, commissionShare);
        }

        emit BulkPurchaseCompleted(msg.sender, asset_ids, total_amount);
    }

    // --- Admin ---

    function set_accepted_token(address token_address) external onlyOwner {
        acceptedToken = token_address;
    }

    function set_commission_wallet(address wallet) external onlyOwner {
        commissionWallet = wallet;
    }

    function set_paused(bool paused) external onlyOwner {
        if (paused) _pause();
        else _unpause();
    }
}

/**
 * ─────────────────────────────────────────────────────────────────────────────
 * Tokenizer (batch tokenize + gestion des métadonnées)
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract IPTokenizer is Ownable, Pausable {
    // Contrat NFT backing (doit exposer mint(owner)->tokenId)
    address public nftContract;

    // Batch controls
    uint32  public batchLimit;
    uint256 public batchCounter;
    mapping(uint256 => uint8) public batchStatus; // 0=pending,1=processing,2=completed,3=failed

    // Données des tokens
    mapping(uint256 => IPAssetData) private _tokens;
    uint256 public tokenCounter;

    // Passerelle IPFS
    string public gateway;

    // Events
    event BatchProcessed(uint256 indexed batchId, uint256[] tokenIds);
    event BatchFailed(uint256 indexed batchId, string reason);
    event TokenTransferred(uint256 indexed tokenId, address from, address to);
    event TokenMinted(uint256 indexed tokenId, address owner);

    constructor(
        address owner_,
        address nft_contract_address,
        string memory gateway_
    ) Ownable(owner_) {
        nftContract = nft_contract_address;
        gateway = gateway_;
        batchLimit = DEFAULT_BATCH_LIMIT;
        tokenCounter = 0;
    }

    /**
     * Tokenisation en lot : crée des NFTs et stocke les métadonnées.
     * assets[i].owner recevra le NFT (via IIPNFT.mint) et sera la source pour ownerOf().
     */
    function bulk_tokenize(
        IPAssetData[] calldata assets // metadataURI/owner/assetType/licenseTerms/expiryDate/metadataHash ignoré en entrée
    ) external whenNotPaused returns (uint256[] memory tokenIds) {
        uint256 n = assets.length;
        require(n > 0, ERROR_EMPTY_BATCH);
        require(n <= batchLimit, ERROR_BATCH_TOO_LARGE);

        uint256 batchId = ++batchCounter;
        batchStatus[batchId] = 1; // processing

        tokenIds = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            IPAssetData calldata a = assets[i];
            tokenIds[i] = _mint(a);
        }

        batchStatus[batchId] = 2; // completed
        emit BatchProcessed(batchId, tokenIds);
    }

    // --- Lectures publiques ---

    function get_token_metadata(uint256 tokenId) external view returns (IPAssetData memory) {
        return _tokens[tokenId];
    }

    function get_token_owner(uint256 tokenId) public view returns (address) {
        return IIPNFT(nftContract).ownerOf(tokenId);
    }

    function get_token_expiry(uint256 tokenId) external view returns (uint64) {
        return _tokens[tokenId].expiryDate;
    }

    function get_batch_status(uint256 batch_id) external view returns (uint8) {
        return batchStatus[batch_id];
    }

    function get_batch_limit() external view returns (uint32) {
        return batchLimit;
    }

    function get_ipfs_gateway() external view returns (string memory) {
        return gateway;
    }

    function get_hash(uint256 tokenId) external view returns (bytes32) {
        return _tokens[tokenId].metadataHash;
    }

    // --- Admin / Mutateurs ---

    function set_batch_limit(uint32 new_limit) external onlyOwner {
        batchLimit = new_limit;
    }

    function set_paused(bool paused) external onlyOwner {
        if (paused) _pause();
        else _unpause();
    }

    function set_ipfs_gateway(string calldata gateway_) external onlyOwner {
        gateway = gateway_;
    }

    function update_metadata(uint256 tokenId, string calldata new_metadata) external onlyOwner {
        require(bytes(new_metadata).length != 0, ERROR_INVALID_METADATA);
        IPAssetData storage a = _tokens[tokenId];
        a.metadataURI = new_metadata;
        a.metadataHash = keccak256(bytes(new_metadata));
        // pas d’event dédié dans la version Cairo fournie
    }

    function update_license_terms(uint256 tokenId, LicenseTerms new_terms) external onlyOwner {
        IPAssetData storage a = _tokens[tokenId];
        a.licenseTerms = new_terms;
        // pas d’event dédié dans la version Cairo fournie
    }

    /**
     * Transfert “administratif” (déclenché par l’owner du tokenizer).
     * On délègue au contrat NFT et on synchronise l’owner stocké.
     */
    function transfer_token(uint256 tokenId, address to) external onlyOwner {
        address from = get_token_owner(tokenId);
        IIPNFT(nftContract).transferFrom(from, to, tokenId);

        // sync de l’owner dans les métadonnées internes
        _tokens[tokenId].owner = to;

        emit TokenTransferred(tokenId, from, to);
    }

    // --- Interne ---

    function _mint(IPAssetData calldata asset) internal returns (uint256 tokenId) {
        // validations de base
        require(bytes(asset.metadataURI).length != 0, ERROR_INVALID_METADATA);

        // incrément
        tokenId = ++tokenCounter;

        // Ecrit les métadonnées internes (metadataHash dérivé)
        _tokens[tokenId] = IPAssetData({
            metadataURI: asset.metadataURI,
            owner: asset.owner,
            assetType: asset.assetType,
            licenseTerms: asset.licenseTerms,
            expiryDate: asset.expiryDate,
            metadataHash: keccak256(bytes(asset.metadataURI))
        });

        // Mint du NFT via le contrat cible (doit renvoyer le tokenId)
        uint256 mintedId = IIPNFT(nftContract).mint(asset.owner);
        require(mintedId == tokenId, ERROR_TOKEN_ID_MISMATCH);

        emit TokenMinted(tokenId, asset.owner);
    }
}
