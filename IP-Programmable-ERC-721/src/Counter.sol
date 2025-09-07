// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ---------------------------------------------------------- */
/*                      Counter (ICounter)                    */
/* ---------------------------------------------------------- */
interface ICounter {
    function current() external view returns (uint256);
    function increment() external;
    function decrement() external;
}

contract Counter is ICounter {
    uint256 private _value;

    function current() external view override returns (uint256) {
        return _value;
    }

    // Cairo u256 ne revert pas sur overflow/underflow ; on reproduit
    // ce comportement avec unchecked (wrap-around 2^256).
    function increment() external override {
        unchecked { _value += 1; }
    }

    function decrement() external override {
        unchecked { _value -= 1; }
    }
}

/* ---------------------------------------------------------- */
/*       ERC721 minimal + Enumerable (2 lectures Cairo)       */
/*    - expose: token_of_owner_by_index, total_supply         */
/*    - mint/transfer/burn pour maintenir l’énumération       */
/* ---------------------------------------------------------- */

interface IERC721Minimal {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);

    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;

    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

/**
 * @title ERC721EnumerableMinimal
 * @notice ERC-721 monolithique (pas d’imports) + énumération.
 * @dev Les deux fonctions exposées correspondent aux signatures Cairo :
 *      - token_of_owner_by_index(owner, index) -> tokenId
 *      - total_supply() -> supply
 */
contract ERC721EnumerableMinimal is IERC721Minimal {
    /* ---------------------------- Métadonnées ---------------------------- */
    string private _name;
    string private _symbol;

    /* ----------------------------- Propriété ----------------------------- */
    mapping(uint256 => address) private _ownerOf;
    mapping(address  => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /* --------------------------- Énumération CAIRO ----------------------- */
    // Mapping from (owner, index) -> tokenId
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    // Mapping tokenId -> index dans la liste du propriétaire
    mapping(uint256 => uint256) private _ownedTokensIndex;
    // all_tokens : index -> tokenId
    mapping(uint256 => uint256) private _allTokens;
    // all_tokens_length
    uint256 private _allTokensLength;
    // tokenId -> index dans all_tokens
    mapping(uint256 => uint256) private _allTokensIndex;

    /* ------------------------------- Ctor -------------------------------- */
    constructor(string memory name_, string memory symbol_) {
        _name   = name_;
        _symbol = symbol_;
    }

    /* ------------------------ Lecture métadonnées ------------------------ */
    function name() external view override returns (string memory) { return _name; }
    function symbol() external view override returns (string memory) { return _symbol; }

    /* --------------------------- Lecture base ---------------------------- */
    function balanceOf(address owner) public view override returns (uint256) {
        require(owner != address(0), "Zero owner");
        return _balanceOf[owner];
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        address owner = _ownerOf[tokenId];
        require(owner != address(0), "Nonexistent token");
        return owner;
    }

    /* --------------------------- Approvals base -------------------------- */
    function getApproved(uint256 tokenId) public view override returns (address) {
        require(_exists(tokenId), "Nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) public view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external override {
        address owner = ownerOf(tokenId);
        require(to != owner, "Approve to owner");
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "Not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external override {
        require(operator != msg.sender, "Approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /* ---------------------------- Transferts ----------------------------- */
    function transferFrom(address from, address to, uint256 tokenId) public override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not authorized");
        require(ownerOf(tokenId) == from, "From mismatch");
        require(to != address(0), "Zero to");

        _clearApproval(tokenId);
        _beforeTokenTransfer(from, to, tokenId);

        // Mise à jour des soldes / propriétaire
        _balanceOf[from] -= 1;
        _balanceOf[to]   += 1;
        _ownerOf[tokenId] = to;

        // Énumération propriétaire
        _removeTokenFromOwnerEnumeration(from, tokenId);
        _addTokenToOwnerEnumeration(to, tokenId);

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
        transferFrom(from, to, tokenId);
        require(_checkOnERC721Received(msg.sender, from, to, tokenId, data), "Receiver rejected");
    }

    /* ------------------------------ Mint/Burn ---------------------------- */
    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "Zero to");
        require(!_exists(tokenId), "Already minted");

        _beforeTokenTransfer(address(0), to, tokenId);

        // Propriété
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;

        // Énumération propriétaire
        _addTokenToOwnerEnumeration(to, tokenId);
        // Énumération globale
        _addTokenToAllTokensEnumeration(tokenId);

        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal {
        address owner = ownerOf(tokenId);

        _clearApproval(tokenId);
        _beforeTokenTransfer(owner, address(0), tokenId);

        // Énumération propriétaire / globale
        _removeTokenFromOwnerEnumeration(owner, tokenId);
        _removeTokenFromAllTokensEnumeration(tokenId);

        _balanceOf[owner] -= 1;
        delete _ownerOf[tokenId];

        emit Transfer(owner, address(0), tokenId);
    }

    /* -------------------------- Hooks / Internes ------------------------- */
    function _beforeTokenTransfer(address /*from*/, address /*to*/, uint256 /*tokenId*/) internal virtual {
        // hook extensible si besoin
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return (spender == owner ||
                getApproved(tokenId) == spender ||
                isApprovedForAll(owner, spender));
    }

    function _clearApproval(uint256 tokenId) internal {
        if (_tokenApprovals[tokenId] != address(0)) {
            delete _tokenApprovals[tokenId];
        }
    }

    function _checkOnERC721Received(
        address operator,
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private returns (bool) {
        if (to.code.length == 0) return true;
        try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (bytes4 v) {
            return v == IERC721Receiver.onERC721Received.selector;
        } catch { return false; }
    }

    /* ---------------------- Gestion de l’énumération --------------------- */
    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) private {
        uint256 length = _balanceOf[to]; // index = balance avant incrément
        _ownedTokens[to][length] = tokenId;
        _ownedTokensIndex[tokenId] = length;
    }

    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) private {
        uint256 lastIndex = _balanceOf[from] - 1; // index max courant
        uint256 index = _ownedTokensIndex[tokenId];

        if (index != lastIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastIndex];
            _ownedTokens[from][index] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = index;
        }
        delete _ownedTokensIndex[tokenId];
        delete _ownedTokens[from][lastIndex];
    }

    function _addTokenToAllTokensEnumeration(uint256 tokenId) private {
        uint256 idx = _allTokensLength;
        _allTokens[idx] = tokenId;
        _allTokensIndex[tokenId] = idx;
        unchecked { _allTokensLength = idx + 1; }
    }

    function _removeTokenFromAllTokensEnumeration(uint256 tokenId) private {
        uint256 lastIndex = _allTokensLength - 1;
        uint256 index = _allTokensIndex[tokenId];

        if (index != lastIndex) {
            uint256 lastTokenId = _allTokens[lastIndex];
            _allTokens[index] = lastTokenId;
            _allTokensIndex[lastTokenId] = index;
        }
        delete _allTokensIndex[tokenId];
        delete _allTokens[lastIndex];
        unchecked { _allTokensLength = lastIndex; }
    }

    /* ------------------- Lectures "identiques" à Cairo ------------------- */
    /**
     * @notice Retourne le tokenId à l’index `index` pour `owner`.
     * @dev Reproduit: assert(index < balance, 'Owner index out of bounds')
     */
    function token_of_owner_by_index(address owner, uint256 index) external view returns (uint256) {
        uint256 bal = balanceOf(owner);
        require(index < bal, "Owner index out of bounds");
        return _ownedTokens[owner][index];
    }

    /**
     * @notice Nombre total de tokens (supply).
     */
    function total_supply() external view returns (uint256) {
        return _allTokensLength;
    }

    /* ------------------- Helpers optionnels de démo ---------------------- */
    // Fonctions publiques pour tester rapidement sans autre fichier.
    function demo_mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function demo_burn(uint256 tokenId) external {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not authorized");
        _burn(tokenId);
    }
}
