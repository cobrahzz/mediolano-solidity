// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IIPCollection {
    function mint(address recipient) external returns (uint256);
    function burn(uint256 tokenId) external;
    function listUserTokens(address owner) external view returns (uint256[] memory);
    function transferToken(address from, address to, uint256 tokenId) external;
}

contract IPCollection is
    ERC721,
    ERC721Enumerable,
    ERC721Burnable,
    Ownable,
    IIPCollection
{
    using Strings for uint256;

    string private _baseTokenURI;
    uint256 private _tokenIdCounter; // starts at 0; first minted = 1

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address initialOwner
    ) ERC721(name_, symbol_) Ownable() {
        _baseTokenURI = baseURI_;
        _tokenIdCounter = 0;
        _transferOwnership(initialOwner);
    }

    /// Only owner can mint; returns tokenId
    function mint(address recipient) external onlyOwner returns (uint256) {
        require(msg.sender != address(0), "Caller is zero address");
        _tokenIdCounter += 1;
        uint256 tokenId = _tokenIdCounter;
        _safeMint(recipient, tokenId);
        return tokenId;
    }

    /// Implement interface + resolve multiple inheritance (ERC721Burnable also defines burn)
    function burn(uint256 tokenId)
        public
        override(ERC721Burnable, IIPCollection)
    {
        // conserve la logique d'OZ (owner ou approuvé)
        ERC721Burnable.burn(tokenId);
    }

    /// Enumerate owner's tokens via ERC721Enumerable
    function listUserTokens(address owner)
        external
        view
        returns (uint256[] memory)
    {
        uint256 count = balanceOf(owner);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }
        return ids;
    }

    /// Transfer only if THIS contract is approved for tokenId (mirrors Cairo check)
    function transferToken(address from, address to, uint256 tokenId) external {
        require(msg.sender != address(0), "Caller is zero address");
        require(getApproved(tokenId) == address(this), "Contract not approved");
        transferFrom(from, to, tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ------- Overrides (multiple inheritance) -------
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    /// Starknet-like upgrade stub (use a proxy on EVM if you need upgrades)
    function upgrade(bytes32 /* newClassHash */) external onlyOwner {
        revert("Upgrade not supported directly; use a proxy pattern");
    }
}
