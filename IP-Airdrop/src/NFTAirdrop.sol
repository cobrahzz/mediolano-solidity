// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title NFT Airdrop with Merkle claim + owner whitelist + batch airdrop
/// @notice Version Solidity équivalente (simplifiée) à ton Cairo, en keccak256
contract NFTAirdrop is ERC721, Ownable {
    // --- Merkle (claim off-chain) ---
    bytes32 public merkleRoot;                   // racine Merkle (keccak256)
    mapping(address => bool) public hasClaimed;  // anti double-claim
    bool public claimsLocked;                    // option : bloquer les claims (ex: après airdrop)

    // --- Whitelist on-chain (airdrop propriétaire) ---
    mapping(address => uint256) public whitelistAmount; // addr -> quantité à distribuer
    address[] private _whitelistAddrs;                  // itération pour airdrop
    mapping(address => bool) private _listed;           // éviter doublons

    // --- ERC721 ---
    uint256 private _nextTokenId = 1;           // IDs séquentiels (1..N)
    string  private _baseTokenURI;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        bytes32 merkleRoot_,
        address initialOwner
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        _baseTokenURI = baseURI_;
        merkleRoot = merkleRoot_;
    }

    // ===== Admin =====
    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
    }

    function setClaimsLocked(bool locked) external onlyOwner {
        claimsLocked = locked;
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }

    // ===== Whitelist (on-chain) =====
    function whitelist(address to, uint256 amount) external onlyOwner {
        if (!_listed[to]) {
            _listed[to] = true;
            _whitelistAddrs.push(to);
        }
        whitelistAmount[to] = amount; // écrase l’ancien montant si déjà listé
    }

    function whitelistBalanceOf(address to) external view returns (uint256) {
        return whitelistAmount[to];
    }

    function whitelistLength() external view returns (uint256) {
        return _whitelistAddrs.length;
    }

    /// @notice Airdrop par lots pour éviter le gas-limit (start, count)
    function airdrop(uint256 start, uint256 count) external onlyOwner {
        uint256 end = start + count;
        uint256 len = _whitelistAddrs.length;
        if (end > len) end = len;

        for (uint256 i = start; i < end; ++i) {
            address to = _whitelistAddrs[i];
            uint256 amount = whitelistAmount[to];
            if (amount > 0) {
                _batchMint(to, amount);
                whitelistAmount[to] = 0; // reset comme dans le Cairo
            }
        }
    }

    // ===== Claim (Merkle) =====
    /// @notice leaf = keccak256(abi.encodePacked(msg.sender, amount))
    function claim(bytes32[] calldata proof, uint256 amount) external {
         require(!claimsLocked, "CLAIMS_LOCKED");
         bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
         require(MerkleProof.verify(proof, merkleRoot, leaf), "Airdrop: preuve invalide");
         require(!hasClaimed[msg.sender], "Airdrop: deja reclame");

        hasClaimed[msg.sender] = true;
        _batchMint(msg.sender, amount);
    }

    // ===== Internals =====
    function _batchMint(address to, uint256 amount) internal {
        for (uint256 i = 0; i < amount; ++i) {
            _safeMint(to, _nextTokenId);
            _nextTokenId += 1;
        }
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
