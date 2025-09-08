// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/* ========= Interfaces (miroir des traits Cairo) ========= */

interface IMIP {
    function mint_item(address recipient, string calldata uri) external returns (uint256);
}

interface IERC721Snake {
    function balance_of(address account) external view returns (uint256);
    function owner_of(uint256 token_id) external view returns (address);
    function safe_transfer_from(address from, address to, uint256 token_id, bytes calldata data) external;
    function transfer_from(address from, address to, uint256 token_id) external;
    function approve(address to, uint256 token_id) external;
    function set_approval_for_all(address operator, bool approved) external;
    function get_approved(uint256 token_id) external view returns (address);
    function is_approved_for_all(address owner, address operator) external view returns (bool);
}

interface IERC721CamelOnly {
    function balanceOf(address account) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

interface IERC721MetadataSnake {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function token_uri(uint256 token_id) external view returns (string memory);
}

interface IERC721MetadataCamelOnly {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC721EnumerableSnake {
    function total_supply() external view returns (uint256);
    function token_by_index(uint256 index) external view returns (uint256);
    function token_of_owner_by_index(address owner, uint256 index) external view returns (uint256);
}

interface IOwnableSnake {
    function owner() external view returns (address);
    function transfer_ownership(address new_owner) external;
    function renounce_ownership() external;
}

interface ICounter {
    function current() external view returns (uint256);
    function increment() external;
    function decrement() external;
}

interface ISRC5Snake {
    // felt252 -> on utilise uint256 et on le rabat sur bytes4 pour ERC165
    function supports_interface(uint256 interface_id) external view returns (bool);
}

/* ========= Contrat principal ========= */

contract MIP is
    ERC721,
    ERC721Enumerable,
    ERC721URIStorage,
    Ownable,
    IMIP,
    IERC721Snake,
    IERC721CamelOnly,
    IERC721MetadataSnake,
    IERC721MetadataCamelOnly,
    IERC721EnumerableSnake,
    IOwnableSnake,
    ICounter,
    ISRC5Snake
{
    // --- Storage équivalent ---
    // mapping token_id -> tokenURI (ByteArray en Cairo)
    // ERC721URIStorage gère déjà un mapping interne _tokenURIs
    uint256 private _counter;

    string private _baseTokenURI; // "ipfs://QmMIP/"

    // --- Events compteur (miroir Cairo) ---
    event CounterIncremented(uint256 value);
    event CounterDecremented(uint256 value);

    // --- Constructor (même init que Cairo) ---
    constructor(address owner_) ERC721("MIP Protocol", "MIP") {
        _transferOwnership(owner_);
        _baseTokenURI = "ipfs://QmMIP/";
    }

    /* ========= IMIP ========= */

    /// Mints a new IP token to the recipient with the specified URI. Returns token ID.
    function mint_item(address recipient, string calldata uri) external override returns (uint256) {
        require(recipient != address(0), "Invalid recipient");
        uint256 tokenId = _counter + 1;
        _counter = tokenId;
        emit CounterIncremented(tokenId); // le Cairo incremente puis émet; on reflète la valeur actuelle
        _safeMint(recipient, tokenId);
        _setTokenURI(tokenId, uri); // stocke l'URI fourni (comme Map<u256, ByteArray> write)
        return tokenId;
    }

    /* ========= ICounter ========= */

    function current() external view override returns (uint256) {
        return _counter;
    }

    function increment() external override {
        unchecked {
            _counter += 1;
        }
        emit CounterIncremented(_counter);
    }

    function decrement() external override {
        require(_counter > 0, "Counter cannot be negative");
        unchecked {
            _counter -= 1;
        }
        emit CounterDecremented(_counter);
    }

    /* ========= IERC721 snake_case (proxies vers ERC721 standard) ========= */

    function balance_of(address account) external view override returns (uint256) {
        return balanceOf(account);
    }

    function owner_of(uint256 token_id) external view override returns (address) {
        return ownerOf(token_id);
    }

    function safe_transfer_from(
        address from,
        address to,
        uint256 token_id,
        bytes calldata data
    ) external override {
        // Proxy vers la version standard (qui vérifie approvals)
        safeTransferFrom(from, to, token_id, data);
    }

    function transfer_from(address from, address to, uint256 token_id) external override {
        transferFrom(from, to, token_id);
    }

    // NOTE: nom identique à l'ERC721 standard "approve"
    function approve(address to, uint256 token_id) public override(ERC721, IERC721Snake) {
        ERC721.approve(to, token_id);
    }

    function set_approval_for_all(address operator, bool approved) external override {
        setApprovalForAll(operator, approved);
    }

    function get_approved(uint256 token_id) external view override returns (address) {
        return getApproved(token_id);
    }

    function is_approved_for_all(address _owner, address operator) external view override returns (bool) {
        return isApprovedForAll(_owner, operator);
    }

    /* ========= IERC721 camelCase (déjà fournis par ERC721, réexposés pour l'interface) ========= */

    // balanceOf, ownerOf, safeTransferFrom, transferFrom, setApprovalForAll,
    // getApproved, isApprovedForAll : hérités d’ERC721

    /* ========= IERC721Metadata snake + camel ========= */

    // name(), symbol() déjà fournis par ERC721

    function token_uri(uint256 token_id) external view override returns (string memory) {
        return tokenURI(token_id);
    }

    // tokenURI(uint256) : déjà fourni via ERC721URIStorage override ci-dessous

    /* ========= IERC721Enumerable (snake) ========= */

    function total_supply() external view override returns (uint256) {
        return totalSupply();
    }

    function token_by_index(uint256 index) external view override returns (uint256) {
        return tokenByIndex(index);
    }

    function token_of_owner_by_index(address _owner, uint256 index) external view override returns (uint256) {
        return tokenOfOwnerByIndex(_owner, index);
    }

    /* ========= IOwnable (snake) ========= */

    // owner() déjà fourni par Ownable

    function transfer_ownership(address new_owner) external override {
        transferOwnership(new_owner);
    }

    function renounce_ownership() external override {
        renounceOwnership();
    }

    /* ========= SRC5 analogue ========= */
    function supports_interface(uint256 interface_id) external view override returns (bool) {
        // on rabat felt252 -> bytes4 (comme ERC165)
        bytes4 iid = bytes4(uint32(interface_id));
        return supportsInterface(iid);
    }

    /* ========= Overrides OpenZeppelin nécessaires ========= */

    // ERC721Enumerable + ERC721URIStorage + ERC721

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return ERC721Enumerable._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        ERC721Enumerable._increaseBalance(account, value);
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        ERC721URIStorage._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        // ERC721URIStorage: renvoie l’URI stockée si définie, sinon fallback _baseURI + tokenId
        return ERC721URIStorage.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        // ERC721 + Enumerable couvrent ERC165, ERC721, ERC721Enumerable
        return super.supportsInterface(interfaceId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
