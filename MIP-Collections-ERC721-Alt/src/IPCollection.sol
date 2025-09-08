// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Interface équivalente à la version Cairo/Starknet (mêmes noms de fonctions).
interface IIPCollection {
    struct Collection {
        string name;
        string symbol;
        string base_uri;
        address owner;
        bool is_active;
    }

    struct Token {
        uint256 collection_id;
        uint256 token_id;
        address owner;
        string metadata_uri;
    }

    function create_collection(
        string calldata name,
        string calldata symbol,
        string calldata base_uri
    ) external returns (uint256);

    function mint(uint256 collection_id, address recipient) external returns (uint256);

    function burn(uint256 token_id) external;

    function list_user_tokens(address owner) external view returns (uint256[] memory);

    function transfer_token(address from, address to, uint256 token_id) external;

    function list_user_collections(address owner) external view returns (uint256[] memory);

    function get_collection(uint256 collection_id) external view returns (Collection memory);

    function get_token(uint256 token_id) external view returns (Token memory);

    function list_all_tokens() external view returns (uint256[] memory);

    function list_collection_tokens(uint256 collection_id) external view returns (uint256[] memory);
}

/// @title IPCollection (Solidity port)
/// @notice ERC721 unique qui gère des "collections" logiques + indexations utilisateur/collection
///         et expose les mêmes méthodes que la version Cairo.
contract IPCollection is ERC721, Ownable(msg.sender), IIPCollection {
    using Strings for uint256;

    // ---------- Storage structures ----------

    // Collections (id => data)
    mapping(uint256 => Collection) private _collections;
    uint256 public collection_count;

    // Token data (tokenId => data)
    mapping(uint256 => Token) private _tokenData;
    uint256 public token_id_count;

    // (owner, index) -> collection_id ; et compte par owner
    mapping(address => mapping(uint256 => uint256)) private _ownedCollections;
    mapping(address => uint256) private _ownedCollectionCount;

    // (owner, index) -> token_id ; et compte par owner
    mapping(address => mapping(uint256 => uint256)) private _userTokens;
    mapping(address => uint256) private _userTokenCount;

    // index -> token_id (liste globale)
    mapping(uint256 => uint256) private _allTokens;
    uint256 private _allTokenCount;

    // (collection_id, index) -> token_id ; et compte par collection
    mapping(uint256 => mapping(uint256 => uint256)) private _collectionTokens;
    mapping(uint256 => uint256) private _collectionTokenCount;

    // ---------- Events (mêmes noms que Cairo) ----------

    event CollectionCreated(
        uint256 indexed collection_id,
        address indexed owner,
        string name,
        string symbol,
        string base_uri
    );

    event TokenMinted(
        uint256 indexed collection_id,
        uint256 indexed token_id,
        address indexed owner,
        string metadata_uri
    );

    // ---------- Constructor ----------

    /// @param name_  Nom ERC721 (visuel)
    /// @param symbol_ Symbole ERC721 (visuel)
    /// @param base_uri_ (optionnel, non utilisé pour composer les URIs; chaque collection a son base_uri)
    /// @param owner_ Propriétaire Ownable (exige "onlyOwner" sur mint)
    constructor(string memory name_, string memory symbol_, string memory base_uri_, address owner_)
        ERC721(name_, symbol_)
    {
        // base_uri_ n'est pas utilisé, chaque collection a son propre base_uri
        _transferOwnership(owner_);
        token_id_count = 0;
        collection_count = 0;
    }

    // ---------- Internal helpers ----------

    function _composeTokenURI(string memory baseUri, uint256 tokenId) internal pure returns (string memory) {
        // base_uri + tokenId + ".json"
        return string.concat(baseUri, tokenId.toString(), ".json");
    }

    function _addTokenToOwnerList(address owner_, uint256 tokenId) internal {
        uint256 idx = _userTokenCount[owner_];
        _userTokens[owner_][idx] = tokenId;
        _userTokenCount[owner_] = idx + 1;
    }

    function _removeTokenFromOwnerList(address owner_, uint256 tokenId) internal {
        uint256 count = _userTokenCount[owner_];
        if (count == 0) return;

        for (uint256 i = 0; i < count; i++) {
            if (_userTokens[owner_][i] == tokenId) {
                uint256 lastIndex = count - 1;
                if (i != lastIndex) {
                    uint256 lastTokenId = _userTokens[owner_][lastIndex];
                    _userTokens[owner_][i] = lastTokenId;
                }
                delete _userTokens[owner_][lastIndex];
                _userTokenCount[owner_] = lastIndex;
                break;
            }
        }
    }

    /// @dev Hook ERC721 pour maintenir nos index user_tokens et _tokenData.owner
    function _afterTokenTransfer(address from, address to, uint256 tokenId, uint256 /*batchSize*/ )
        internal
        override
    {
        super._afterTokenTransfer(from, to, tokenId, 1);

        if (from != address(0)) {
            _removeTokenFromOwnerList(from, tokenId);
        }
        if (to != address(0)) {
            _addTokenToOwnerList(to, tokenId);
            _tokenData[tokenId].owner = to; // garder le champ owner en phase
        } else {
            // burn: on efface la fiche token
            delete _tokenData[tokenId];
        }
    }

    // ---------- Public/external API (mêmes noms/signatures que Cairo) ----------

    /// @notice Crée une collection (stockée dans le même contrat).
    function create_collection(
        string calldata name_,
        string calldata symbol_,
        string calldata base_uri_
    ) external override returns (uint256) {
        require(msg.sender != address(0), "Caller is zero address");

        uint256 collectionId = ++collection_count;

        _collections[collectionId] = Collection({
            name: name_,
            symbol: symbol_,
            base_uri: base_uri_,
            owner: msg.sender,
            is_active: true
        });

        // indexer pour l'owner
        uint256 idx = _ownedCollectionCount[msg.sender];
        _ownedCollections[msg.sender][idx] = collectionId;
        _ownedCollectionCount[msg.sender] = idx + 1;

        emit CollectionCreated(collectionId, msg.sender, name_, symbol_, base_uri_);
        return collectionId;
    }

    /// @notice Mint d'un token dans une collection. Réservé au propriétaire du contrat (Ownable).
    function mint(uint256 collection_id, address recipient)
        external
        override
        onlyOwner
        returns (uint256)
    {
        require(recipient != address(0), "Recipient is zero address");

        Collection memory col = _collections[collection_id];
        require(col.owner != address(0) && col.is_active, "Invalid collection");

        uint256 tokenId = ++token_id_count;

        _safeMint(recipient, tokenId);

        string memory uri = _composeTokenURI(col.base_uri, tokenId);

        _tokenData[tokenId] = Token({
            collection_id: collection_id,
            token_id: tokenId,
            owner: recipient,
            metadata_uri: uri
        });

        // indexations
        // - par user
        _addTokenToOwnerList(recipient, tokenId);
        // - globale
        _allTokens[_allTokenCount] = tokenId;
        _allTokenCount += 1;
        // - par collection
        uint256 cidx = _collectionTokenCount[collection_id];
        _collectionTokens[collection_id][cidx] = tokenId;
        _collectionTokenCount[collection_id] = cidx + 1;

        emit TokenMinted(collection_id, tokenId, recipient, uri);
        return tokenId;
    }

    /// @notice Burn ; nécessite d'être owner ou approuvé (semantique ERC721).
    function burn(uint256 token_id) external override {
        require(_isApprovedOrOwner(msg.sender, token_id), "Not owner nor approved");
        _burn(token_id);
        // _afterTokenTransfer gère la purge des index + _tokenData
        // NB: on ne retire pas des listes globales/collection pour coller au port 1:1 (Cairo ne le faisait pas)
    }

    /// @notice Retourne la liste des tokenIds détenus par `owner`.
    function list_user_tokens(address owner_) external view override returns (uint256[] memory) {
        uint256 count = _userTokenCount[owner_];
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = _userTokens[owner_][i];
        }
        return out;
    }

    /// @notice Transfert déclenché par le contrat ; exige l'approbation du token pour le contrat.
    function transfer_token(address from, address to, uint256 token_id) external override {
        require(msg.sender != address(0), "Caller is zero address");
        // Spécifique au port Cairo : on exige que le contrat soit approuvé pour ce token
        require(getApproved(token_id) == address(this), "Contract not approved");
        safeTransferFrom(from, to, token_id);
    }

    /// @notice Retourne les collections appartenant à `owner`.
    function list_user_collections(address owner_) external view override returns (uint256[] memory) {
        uint256 count = _ownedCollectionCount[owner_];
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = _ownedCollections[owner_][i];
        }
        return out;
    }

    /// @notice Récupère une collection.
    function get_collection(uint256 collection_id) external view override returns (Collection memory) {
        return _collections[collection_id];
    }

    /// @notice Récupère la fiche d’un token.
    function get_token(uint256 token_id) external view override returns (Token memory) {
        return _tokenData[token_id];
    }

    /// @notice Liste globale de tous les tokenIds (inclut possiblement des tokens burnés, comme le port Cairo).
    function list_all_tokens() external view override returns (uint256[] memory) {
        uint256 count = _allTokenCount;
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = _allTokens[i];
        }
        return out;
    }

    /// @notice Liste les tokenIds d’une collection donnée (peut inclure des tokens burnés, cf. port 1:1).
    function list_collection_tokens(uint256 collection_id)
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256 count = _collectionTokenCount[collection_id];
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = _collectionTokens[collection_id][i];
        }
        return out;
    }

    // ---------- ERC721 overrides ----------

    /// @dev optionnel : renvoyer l'URI stockée à l'émission
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _tokenData[tokenId].metadata_uri;
    }
}
