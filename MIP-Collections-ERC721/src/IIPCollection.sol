// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/*//////////////////////////////////////////////////////////////
///////////////////////  TYPES & LIB  //////////////////////////
//////////////////////////////////////////////////////////////*/

library TokenLib {
    struct Token {
        uint256 collectionId;
        uint256 tokenId;
    }

    /// @notice Parse "collectionId:tokenId" (decimal ASCII) -> Token
    function fromString(string memory s) internal pure returns (Token memory t) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        require(n > 0, "empty token string");

        // find ':'
        uint256 sep = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (b[i] == bytes1(uint8(58))) { // ':'
                sep = i;
                break;
            }
        }
        require(sep != type(uint256).max && sep > 0 && sep < n - 1, "bad token format");

        t.collectionId = _dec(b, 0, sep);
        t.tokenId      = _dec(b, sep + 1, n);
    }

    function _dec(bytes memory b, uint256 start, uint256 end) private pure returns (uint256 v) {
        require(end > start, "empty number");
        unchecked {
            for (uint256 i = start; i < end; i++) {
                uint8 c = uint8(b[i]);
                require(c >= 48 && c <= 57, "non-digit");
                v = v * 10 + (c - 48);
            }
        }
    }
}

struct Collection {
    string  name;
    string  symbol;
    string  baseURI;
    address owner;
    address ipNft;
    bool    isActive;
}

struct TokenData {
    uint256 collectionId;
    uint256 tokenId;
    address owner;
    string  metadataURI;
}

struct CollectionStats {
    uint256 totalMinted;
    uint256 totalBurned;
    uint256 totalTransfers;
    uint64  lastMintTime;
    uint64  lastBurnTime;
    uint64  lastTransferTime;
}

/*//////////////////////////////////////////////////////////////
////////////////////////  INTERFACES  //////////////////////////
//////////////////////////////////////////////////////////////*/

interface IIPNft {
    function mint(address recipient, uint256 tokenId, string calldata tokenUri) external;
    function burn(uint256 tokenId) external;
    function transfer(address from, address to, uint256 tokenId) external;

    function get_collection_id() external view returns (uint256);
    function get_collection_manager() external view returns (address);

    function get_all_user_tokens(address user) external view returns (uint256[] memory);
    function get_total_supply() external view returns (uint256);
    function get_token_uri(uint256 tokenId) external view returns (string memory);
    function get_token_owner(uint256 tokenId) external view returns (address);
    function is_approved_for_token(uint256 tokenId, address spender) external view returns (bool);
}

interface IIPCollection {
    function create_collection(
        string calldata name,
        string calldata symbol,
        string calldata base_uri
    ) external returns (uint256);

    function mint(
        uint256 collection_id,
        address recipient,
        string calldata token_uri
    ) external returns (uint256);

    function batch_mint(
        uint256 collection_id,
        address[] calldata recipients,
        string[] calldata token_uris
    ) external returns (uint256[] memory tokenIds);

    function burn(string calldata token) external;
    function batch_burn(string[] calldata tokens) external;

    function transfer_token(address from, address to, string calldata token) external;
    function batch_transfer(address from, address to, string[] calldata tokens) external;

    function list_user_tokens_per_collection(uint256 collection_id, address user)
        external view returns (uint256[] memory);

    function list_user_collections(address user) external view returns (uint256[] memory);

    function get_collection(uint256 collection_id) external view returns (Collection memory);
    function is_valid_collection(uint256 collection_id) external view returns (bool);

    function get_collection_stats(uint256 collection_id) external view returns (CollectionStats memory);
    function is_collection_owner(uint256 collection_id, address owner) external view returns (bool);

    function get_token(string calldata token) external view returns (TokenData memory);
    function is_valid_token(string calldata token) external view returns (bool);
}

/*//////////////////////////////////////////////////////////////
///////////////////////////  IPNFT  ////////////////////////////
//////////////////////////////////////////////////////////////*/

contract IPNft is ERC721, ERC721Enumerable, Ownable, AccessControl, IIPNft {
    bytes32 public constant DEFAULT_ADMIN_ROLE_ALIAS = DEFAULT_ADMIN_ROLE;

    uint256 private _collectionId;
    address private _collectionManager;
    string  private _baseTokenURI;

    mapping(uint256 => string) private _tokenURIs;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address owner_,
        uint256 collectionId_,
        address collectionManager_
    ) ERC721(name_, symbol_) Ownable(owner_) {
        _baseTokenURI = baseURI_;
        _collectionId = collectionId_;
        _collectionManager = collectionManager_;
        _grantRole(DEFAULT_ADMIN_ROLE, collectionManager_);
    }

    /*---------------------- IIPNft ----------------------*/

    function mint(address recipient, uint256 tokenId, string calldata tokenUri)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _safeMint(recipient, tokenId);
        _tokenURIs[tokenId] = tokenUri;
    }

    function burn(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _burn(tokenId);
        delete _tokenURIs[tokenId];
    }

    function transfer(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
    }

    function get_collection_id() external view returns (uint256) {
        return _collectionId;
    }

    function get_collection_manager() external view returns (address) {
        return _collectionManager;
    }

    function get_all_user_tokens(address user) external view returns (uint256[] memory arr) {
        uint256 bal = balanceOf(user);
        arr = new uint256[](bal);
        for (uint256 i = 0; i < bal; i++) {
            arr[i] = tokenOfOwnerByIndex(user, i);
        }
    }

    function get_total_supply() external view returns (uint256) {
        return totalSupply();
    }

    function get_token_uri(uint256 tokenId) external view returns (string memory) {
        return tokenURI(tokenId);
    }

    function get_token_owner(uint256 tokenId) external view returns (address) {
        return ownerOf(tokenId);
    }

    function is_approved_for_token(uint256 tokenId, address spender) external view returns (bool) {
        address owner = ownerOf(tokenId);
        return (getApproved(tokenId) == spender) || isApprovedForAll(owner, spender);
    }

    /*-------------------- ERC721 overrides --------------------*/

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721)
        returns (string memory)
    {
        _requireOwned(tokenId);
        string memory specific = _tokenURIs[tokenId];
        if (bytes(specific).length != 0) return specific;
        return string.concat(_baseTokenURI, _toString(tokenId));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    /*---------------------- utils ----------------------*/

    function _toString(uint256 x) private pure returns (string memory) {
        if (x == 0) return "0";
        uint256 tmp = x; uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory b = new bytes(len);
        while (x != 0) {
            len--;
            b[len] = bytes1(uint8(48 + (x % 10)));
            x /= 10;
        }
        return string(b);
    }
}

/*//////////////////////////////////////////////////////////////
///////////////////////  IPCOLLECTION  /////////////////////////
//////////////////////////////////////////////////////////////*/

contract IPCollection is IIPCollection {
    using TokenLib for string;

    mapping(uint256 => Collection) private _collections;
    mapping(uint256 => CollectionStats) private _stats;
    mapping(address => uint256[]) private _userCollections;
    uint256 private _collectionCount;

    /*------------- Events (alignés avec la version Cairo) -------------*/

    event CollectionCreated(
        uint256 indexed collection_id,
        address indexed owner,
        string name,
        string symbol,
        string base_uri
    );

    event CollectionUpdated( // gardé pour compat future (non utilisé ici)
        uint256 indexed collection_id,
        address indexed owner,
        string name,
        string symbol,
        string base_uri,
        uint64  timestamp
    );

    event TokenMinted(
        uint256 indexed collection_id,
        uint256 indexed token_id,
        address indexed owner,
        string metadata_uri
    );

    event TokenMintedBatch(
        uint256 indexed collection_id,
        uint256[] token_ids,
        address[] owners,
        address operator,
        uint64 timestamp
    );

    event TokenBurned(
        uint256 indexed collection_id,
        uint256 indexed token_id,
        address operator,
        uint64 timestamp
    );

    event TokenBurnedBatch(string[] tokens, address operator, uint64 timestamp);

    event TokenTransferred(
        uint256 indexed collection_id,
        uint256 indexed token_id,
        address operator,
        uint64 timestamp
    );

    event TokenTransferredBatch(
        address from,
        address to,
        string[] tokens,
        address operator,
        uint64 timestamp
    );

    /*------------------- IIPCollection impl -------------------*/

    function create_collection(
        string calldata name_,
        string calldata symbol_,
        string calldata base_uri_
    ) external returns (uint256) {
        require(msg.sender != address(0), "zero caller");

        uint256 collectionId = ++_collectionCount;

        // Déploie un IPNft dédié
        address ipNft = address(
            new IPNft(
                name_,
                symbol_,
                base_uri_,
                msg.sender,
                collectionId,
                address(this)
            )
        );

        _collections[collectionId] = Collection({
            name: name_,
            symbol: symbol_,
            baseURI: base_uri_,
            owner: msg.sender,
            ipNft: ipNft,
            isActive: true
        });

        _userCollections[msg.sender].push(collectionId);

        emit CollectionCreated(collectionId, msg.sender, name_, symbol_, base_uri_);
        return collectionId;
    }

    function mint(
        uint256 collection_id,
        address recipient,
        string calldata token_uri
    ) external returns (uint256) {
        require(recipient != address(0), "zero recipient");

        Collection memory col = _collections[collection_id];
        require(col.isActive, "collection inactive");
        require(msg.sender == col.owner, "only owner");

        CollectionStats memory st = _stats[collection_id];
        uint256 nextId = st.totalMinted;

        IIPNft(col.ipNft).mint(recipient, nextId, token_uri);

        st.totalMinted = nextId + 1;
        st.lastMintTime = uint64(block.timestamp);
        _stats[collection_id] = st;

        emit TokenMinted(collection_id, nextId, recipient, token_uri);
        return nextId;
    }

    function batch_mint(
        uint256 collection_id,
        address[] calldata recipients,
        string[] calldata token_uris
    ) external returns (uint256[] memory tokenIds) {
        require(recipients.length > 0, "empty recipients");
        require(recipients.length == token_uris.length, "length mismatch");

        Collection memory col = _collections[collection_id];
        require(col.isActive, "collection inactive");
        require(msg.sender == col.owner, "only owner");

        CollectionStats memory st = _stats[collection_id];
        uint256 n = recipients.length;

        tokenIds = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            require(recipients[i] != address(0), "zero recipient");
            uint256 id = st.totalMinted + i;
            IIPNft(col.ipNft).mint(recipients[i], id, token_uris[i]);
            tokenIds[i] = id;
        }

        st.totalMinted += n;
        st.lastMintTime = uint64(block.timestamp);
        _stats[collection_id] = st;

        emit TokenMintedBatch(collection_id, tokenIds, recipients, msg.sender, uint64(block.timestamp));
    }

    function burn(string calldata token) external {
        TokenLib.Token memory t = token.fromString();
        Collection memory col = _collections[t.collectionId];
        require(col.isActive, "collection inactive");

        address owner = _tokenOwnerOrZero(col.ipNft, t.tokenId);
        require(owner == msg.sender, "not token owner");

        IIPNft(col.ipNft).burn(t.tokenId);

        CollectionStats memory st = _stats[t.collectionId];
        st.totalBurned += 1;
        st.lastBurnTime = uint64(block.timestamp);
        _stats[t.collectionId] = st;

        emit TokenBurned(t.collectionId, t.tokenId, msg.sender, uint64(block.timestamp));
    }

    function batch_burn(string[] calldata tokens) external {
        require(tokens.length > 0, "empty tokens");

        for (uint256 i = 0; i < tokens.length; i++) {
            TokenLib.Token memory t = tokens[i].fromString();
            Collection memory col = _collections[t.collectionId];
            require(col.isActive, "collection inactive");

            address owner = _tokenOwnerOrZero(col.ipNft, t.tokenId);
            require(owner == msg.sender, "not token owner");

            IIPNft(col.ipNft).burn(t.tokenId);

            CollectionStats memory st = _stats[t.collectionId];
            st.totalBurned += 1;
            st.lastBurnTime = uint64(block.timestamp);
            _stats[t.collectionId] = st;
        }

        emit TokenBurnedBatch(tokens, msg.sender, uint64(block.timestamp));
    }

    function transfer_token(address from, address to, string calldata token) external {
        TokenLib.Token memory t = token.fromString();
        Collection memory col = _collections[t.collectionId];
        require(col.isActive, "collection inactive");

        bool approved = IIPNft(col.ipNft).is_approved_for_token(t.tokenId, address(this));
        require(approved, "contract not approved");

        IIPNft(col.ipNft).transfer(from, to, t.tokenId);

        CollectionStats memory st = _stats[t.collectionId];
        st.totalTransfers += 1;
        st.lastTransferTime = uint64(block.timestamp);
        _stats[t.collectionId] = st;

        emit TokenTransferred(t.collectionId, t.tokenId, msg.sender, uint64(block.timestamp));
    }

    function batch_transfer(address from, address to, string[] calldata tokens) external {
        require(tokens.length > 0, "empty tokens");

        for (uint256 i = 0; i < tokens.length; i++) {
            TokenLib.Token memory t = tokens[i].fromString();
            Collection memory col = _collections[t.collectionId];
            require(col.isActive, "collection inactive");

            bool approved = IIPNft(col.ipNft).is_approved_for_token(t.tokenId, address(this));
            require(approved, "contract not approved");

            IIPNft(col.ipNft).transfer(from, to, t.tokenId);

            CollectionStats memory st = _stats[t.collectionId];
            st.totalTransfers += 1;
            st.lastTransferTime = uint64(block.timestamp);
            _stats[t.collectionId] = st;
        }

        emit TokenTransferredBatch(from, to, tokens, msg.sender, uint64(block.timestamp));
    }

    function list_user_tokens_per_collection(uint256 collection_id, address user)
        external view returns (uint256[] memory)
    {
        Collection memory col = _collections[collection_id];
        if (!col.isActive) return new uint256;
        return IIPNft(col.ipNft).get_all_user_tokens(user);
    }

    function list_user_collections(address user)
        external
        view
        returns (uint256[] memory)
    {
        return _userCollections[user];
    }

    function get_collection(uint256 collection_id)
        external
        view
        returns (Collection memory)
    {
        return _collections[collection_id];
    }

    function get_collection_stats(uint256 collection_id)
        external
        view
        returns (CollectionStats memory)
    {
        return _stats[collection_id];
    }

    function is_valid_collection(uint256 collection_id) external view returns (bool) {
        return _collections[collection_id].isActive;
    }

    function is_valid_token(string calldata token) external view returns (bool) {
        TokenLib.Token memory t = token.fromString();
        Collection memory col = _collections[t.collectionId];
        if (!col.isActive) return false;
        return _tokenOwnerOrZero(col.ipNft, t.tokenId) != address(0);
    }

    function get_token(string calldata token)
        external
        view
        returns (TokenData memory td)
    {
        TokenLib.Token memory t = token.fromString();
        Collection memory col = _collections[t.collectionId];

        if (!col.isActive) {
            return TokenData({collectionId: 0, tokenId: 0, owner: address(0), metadataURI: ""});
        }

        address owner = _tokenOwnerOrZero(col.ipNft, t.tokenId);
        if (owner == address(0)) {
            return TokenData({collectionId: 0, tokenId: 0, owner: address(0), metadataURI: ""});
        }

        string memory uri = IIPNft(col.ipNft).get_token_uri(t.tokenId);

        td = TokenData({
            collectionId: t.collectionId,
            tokenId: t.tokenId,
            owner: owner,
            metadataURI: uri
        });
    }

    /*--------------------- helpers ---------------------*/

    function _tokenOwnerOrZero(address ipnft, uint256 tokenId) private view returns (address) {
        // catch reverts from ownerOf via interface
        try IIPNft(ipnft).get_token_owner(tokenId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }
}
