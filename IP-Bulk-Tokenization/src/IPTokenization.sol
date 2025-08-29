// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * Conversion "au plus proche" des fonctionnalités Cairo :
 * - Types & constantes (IPAssetData, enums, erreurs, limites)
 * - Contrat ERC721 "IPNFT" basique (owner-only mint), transferrable
 * - Contrat IPTokenizer (Ownable + Pausable) : bulk_tokenize, stockage des métadonnées,
 *   batch limit/status, update metadata/licences, transfer_token, gateway, get_hash, etc.
 * - Mini IPFSManager (get/set gateway + stubs)
 *
 * Notes :
 * - Enums sont mappées sur uint8 (0..3) comme dans Cairo.
 * - IPTokenizer attend que l’ERC721 expose `mint(address) returns (uint256)` qui mint l’ID suivant.
 * - Pour rester simple : tokenURI = baseURI commun (pas d’URI par token).
 */

/*//////////////////////////////////////////////////////////////
                       TYPES & CONSTANTES
//////////////////////////////////////////////////////////////*/

library IPTypes {
    // Enums (0..3)
    enum AssetType {
        Patent,      // 0
        Trademark,   // 1
        Copyright,   // 2
        TradeSecret  // 3
    }

    enum LicenseTerms {
        Standard, // 0
        Premium,  // 1
        Exclusive,// 2
        Custom    // 3
    }

    struct IPAssetData {
        string metadata_uri;
        string metadata_hash;    // présent dans la seconde version Cairo
        address owner;
        AssetType asset_type;
        LicenseTerms license_terms;
        uint64 expiry_date;
    }

    // Constantes d’erreur / config
    string internal constant INVALID_METADATA        = "Invalid metadata";
    string internal constant INVALID_ASSET_TYPE      = "Invalid asset type";
    string internal constant INVALID_LICENSE_TERMS   = "Invalid license terms";
    string internal constant UNAUTHORIZED            = "Unauthorized";
    string internal constant ERROR_BATCH_TOO_LARGE   = "Batch size exceeds limit";
    string internal constant ERROR_EMPTY_BATCH       = "Empty batch";

    uint32 internal constant DEFAULT_BATCH_LIMIT = 50;

    // Helpers de validation
    function isValidAssetType(AssetType t) internal pure returns (bool) {
        return uint8(t) <= uint8(AssetType.TradeSecret);
    }

    function isValidLicenseTerms(LicenseTerms t) internal pure returns (bool) {
        return uint8(t) <= uint8(LicenseTerms.Custom);
    }
}

/*//////////////////////////////////////////////////////////////
                       INTERFACE ERC721 LITE
//////////////////////////////////////////////////////////////*/

interface IIPNFT {
    function mint(address to) external returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/*//////////////////////////////////////////////////////////////
                        IMPORTS OPENZEPPELIN
//////////////////////////////////////////////////////////////*/

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/*//////////////////////////////////////////////////////////////
                             IPNFT
 - ERC721 simple :
   * owner-only mint (auto-incrément des IDs à partir de 1)
   * transferrable (standard)
   * baseURI commun retourné par tokenURI
//////////////////////////////////////////////////////////////*/

contract IPNFT is ERC721, Ownable, IIPNFT {
    using Strings for uint256;

    string private _baseUri;
    uint256 private _nextId = 1;

    event BaseURISet(string newBaseUri);

    constructor(address initialOwner, string memory name_, string memory symbol_, string memory baseUri_)
        ERC721(name_, symbol_)
        Ownable(initialOwner)
    {
        _baseUri = baseUri_;
    }

    function mint(address to) external override onlyOwner returns (uint256 tokenId) {
        tokenId = _nextId;
        _nextId = _nextId + 1;
        _safeMint(to, tokenId);
    }

    function setBaseURI(string memory newBase) external onlyOwner {
        _baseUri = newBase;
        emit BaseURISet(newBase);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseUri;
    }

    // Optionnel : tokenURI = baseURI sans suffixe (comme la version Cairo simplifiée)
    function tokenURI(uint256 /*tokenId*/) public view override returns (string memory) {
        return _baseUri;
    }
    function ownerOf(uint256 tokenId)
        public
        view
        override(ERC721, IIPNFT)
        returns (address)
    {
        return super.ownerOf(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId)
        public
        override(ERC721, IIPNFT)
    {
        super.transferFrom(from, to, tokenId);
    }
}

/*//////////////////////////////////////////////////////////////
                          IPFSManager (stub)
//////////////////////////////////////////////////////////////*/

contract IPFSManager {
    string private _gateway;

    constructor(string memory gateway_) {
        _gateway = gateway_;
    }

    function pin_to_ipfs(string memory data) external pure returns (string memory) {
        // Stub : retourne tel quel
        return data;
    }

    function validate_ipfs_hash(string memory /*hash_*/) external pure returns (bool) {
        // Stub : toujours vrai (comme dans le Cairo)
        return true;
    }

    function get_ipfs_gateway() external view returns (string memory) {
        return _gateway;
    }

    function set_ipfs_gateway(string memory gateway_) external {
        _gateway = gateway_;
    }
}

/*//////////////////////////////////////////////////////////////
                           IPTokenizer
 - Ownable + Pausable
 - batch tokenize (avec validations)
 - stockage des IPAssetData par tokenId
 - batch status / limit
 - update metadata / license terms
 - transfer_token (owner-only) => appelle l’ERC721
 - gateway (copie simple; indépendante d’IPFSManager)
 - get_hash(tokenId) => renvoie metadata_hash
//////////////////////////////////////////////////////////////*/

contract IPTokenizer is Ownable, Pausable {
    using IPTypes for IPTypes.IPAssetData;

    // État
    IIPNFT public nft_contract;
    uint32 public batch_limit;
    uint256 public batch_counter;  // batch ids (1..)
    mapping(uint256 => uint8) public batch_status; // 0=pending,1=processing,2=completed,3=failed

    mapping(uint256 => IPTypes.IPAssetData) public tokens; // tokenId => metadata
    uint256 public token_counter; // dernier token ID "attendu" côté tokenizer

    string private _gateway;

    // Events
    event BatchProcessed(uint256 indexed batch_id, uint256[] token_ids);
    event BatchFailed(uint256 indexed batch_id, string reason);
    event TokenTransferred(uint256 indexed token_id, address indexed from, address indexed to);
    event TokenMinted(uint256 indexed token_id, address indexed owner);
    event GatewaySet(string newGateway);
    event BatchLimitSet(uint32 newLimit);

    constructor(
        address initialOwner,
        address nft_contract_address,
        string memory gateway_
    ) Ownable(initialOwner) {
        nft_contract = IIPNFT(nft_contract_address);
        _gateway = gateway_;
        batch_limit = IPTypes.DEFAULT_BATCH_LIMIT;
        token_counter = 0;
    }

    /*---------------------------- Admin ----------------------------*/

    function set_batch_limit(uint32 new_limit) external onlyOwner {
        batch_limit = new_limit;
        emit BatchLimitSet(new_limit);
    }

    function set_paused(bool paused_) external onlyOwner {
        if (paused_) _pause();
        else _unpause();
    }

    function set_ipfs_gateway(string memory gateway_) external onlyOwner {
        _gateway = gateway_;
        emit GatewaySet(gateway_);
    }

    /*---------------------------- Reads ----------------------------*/

    function get_batch_status(uint256 batch_id) external view returns (uint8) {
        return batch_status[batch_id];
    }

    function get_batch_limit() external view returns (uint32) {
        return batch_limit;
    }

    function get_token_metadata(uint256 token_id) external view returns (IPTypes.IPAssetData memory) {
        return tokens[token_id];
    }

    function get_token_owner(uint256 token_id) external view returns (address) {
        return nft_contract.ownerOf(token_id);
    }

    function get_token_expiry(uint256 token_id) external view returns (uint64) {
        return tokens[token_id].expiry_date;
    }

    function get_ipfs_gateway() external view returns (string memory) {
        return _gateway;
    }

    function get_hash(uint256 token_id) external view returns (string memory) {
        return tokens[token_id].metadata_hash;
    }

    /*---------------------------- Writes ----------------------------*/

    function bulk_tokenize(IPTypes.IPAssetData[] calldata assets)
        external
        whenNotPaused
        onlyOwner
        returns (uint256[] memory token_ids)
    {
        uint256 batch_size = assets.length;
        require(batch_size > 0, IPTypes.ERROR_EMPTY_BATCH);
        require(batch_size <= batch_limit, IPTypes.ERROR_BATCH_TOO_LARGE);

        uint256 batch_id = ++batch_counter;
        batch_status[batch_id] = 1; // processing

        token_ids = new uint256[](batch_size);

        // Process
        for (uint256 i = 0; i < batch_size; i++) {
            token_ids[i] = _mint(assets[i]);
        }

        batch_status[batch_id] = 2; // completed
        emit BatchProcessed(batch_id, token_ids);
    }

    function update_metadata(uint256 token_id, string calldata new_metadata_uri) external onlyOwner {
        require(bytes(new_metadata_uri).length != 0, IPTypes.INVALID_METADATA);
        IPTypes.IPAssetData storage asset = tokens[token_id];
        asset.metadata_uri = new_metadata_uri;
        // (on laisse metadata_hash inchangé ici)
    }

    function update_license_terms(uint256 token_id, IPTypes.LicenseTerms new_terms) external onlyOwner {
        require(IPTypes.isValidLicenseTerms(new_terms), IPTypes.INVALID_LICENSE_TERMS);
        tokens[token_id].license_terms = new_terms;
    }

    function transfer_token(uint256 token_id, address to) external onlyOwner {
        IPTypes.IPAssetData storage asset = tokens[token_id];
        address from = asset.owner;

        // Transfert ERC721
        nft_contract.transferFrom(from, to, token_id);

        // MÀJ propriétaire dans nos métadonnées
        asset.owner = to;

        emit TokenTransferred(token_id, from, to);
    }

    /*---------------------------- Internes ----------------------------*/

    function _mint(IPTypes.IPAssetData calldata asset) internal returns (uint256 token_id) {
        require(bytes(asset.metadata_uri).length != 0, IPTypes.INVALID_METADATA);
        require(IPTypes.isValidAssetType(asset.asset_type), IPTypes.INVALID_ASSET_TYPE);
        require(IPTypes.isValidLicenseTerms(asset.license_terms), IPTypes.INVALID_LICENSE_TERMS);
        require(asset.owner != address(0), IPTypes.UNAUTHORIZED);

        // ID attendu côté tokenizer
        token_id = ++token_counter;

        // Stockage metadata AVANT mint (pour éviter reentrancy changement d’état post-mint)
        tokens[token_id] = IPTypes.IPAssetData({
            metadata_uri: asset.metadata_uri,
            metadata_hash: asset.metadata_hash,
            owner: asset.owner,
            asset_type: asset.asset_type,
            license_terms: asset.license_terms,
            expiry_date: asset.expiry_date
        });

        // Mint côté ERC721 et vérifier cohérence de l’ID retourné
        uint256 minted = nft_contract.mint(asset.owner);
        require(minted == token_id, "Token ID mismatch");

        emit TokenMinted(token_id, asset.owner);
    }
}
