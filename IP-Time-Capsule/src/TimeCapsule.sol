// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITimeCapsule {
    /**
     * Mint a new time capsule NFT.
     * @param recipient Token recipient
     * @param metadataHash Off-chain hash (felt252 → bytes32)
     * @param unvestingTimestamp Unix time (seconds) after which metadata is revealed/mutable
     * @return tokenId Newly minted token id
     */
    function mint(
        address recipient,
        bytes32 metadataHash,
        uint64 unvestingTimestamp
    ) external returns (uint256 tokenId);

    /// Get metadata hash (returns 0x0 until unvestingTimestamp is reached)
    function getMetadata(uint256 tokenId) external view returns (bytes32);

    /// Update metadata hash (only token owner or contract owner, and only after unvesting)
    function setMetadata(uint256 tokenId, bytes32 metadataHash) external;

    /// List all tokenIds owned by `owner` (using ERC721Enumerable)
    function listUserTokens(address owner) external view returns (uint256[] memory);
}
