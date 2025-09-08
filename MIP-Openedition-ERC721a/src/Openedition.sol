// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IOpenEditionERC721A {
    function create_claim_phase(
        uint256 phase_id,
        uint256 price,
        uint64 start_time,
        uint64 end_time,
        bool is_public,
        address[] calldata whitelist
    ) external;

    function update_metadata(string calldata base_uri) external;

    function mint(uint256 phase_id, uint256 quantity) external returns (uint256);

    function get_current_token_id() external view returns (uint256);

    function get_metadata(uint256 token_id) external view returns (string memory);

    function get_claim_phase(uint256 phase_id)
        external
        view
        returns (uint256 price, uint64 start_time, uint64 end_time, bool is_public);

    function is_whitelisted(uint256 phase_id, address account) external view returns (bool);
}

contract OpenEditionERC721A is ERC721, Ownable, IOpenEditionERC721A {
    struct ClaimPhase {
        uint256 price;
        uint64 start_time;
        uint64 end_time;
        bool is_public;
    }

    // Storage
    string private _baseTokenURI;
    uint256 private _currentTokenId;
    mapping(uint256 => ClaimPhase) private _claimPhases;
    mapping(uint256 => mapping(address => bool)) private _whitelist;

    // Events (miroir Cairo)
    event ClaimPhaseCreated(
        uint256 indexed phase_id,
        uint256 price,
        uint64 start_time,
        uint64 end_time,
        bool is_public
    );

    event MetadataUpdated(string base_uri);

    event TokensMinted(
        uint256 indexed phase_id,
        uint256 first_token_id,
        uint256 quantity,
        address recipient
    );

    // Évènement analogue à UpgradeableComponent::Upgrade
    event UpgradeableUpgraded(bytes32 new_class_hash);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory base_uri_,
        address owner_
    ) ERC721(name_, symbol_) {
        _baseTokenURI = base_uri_;
        _currentTokenId = 0;
        _transferOwnership(owner_);
    }

    /* ===================== IOpenEditionERC721A ===================== */

    function create_claim_phase(
        uint256 phase_id,
        uint256 price,
        uint64 start_time,
        uint64 end_time,
        bool is_public,
        address[] calldata whitelist_
    ) external override onlyOwner {
        require(start_time <= end_time, "Invalid time range");
        require(end_time >= block.timestamp, "Phase ended");

        _claimPhases[phase_id] = ClaimPhase({
            price: price,
            start_time: start_time,
            end_time: end_time,
            is_public: is_public
        });

        // Populate whitelist
        if (!is_public && whitelist_.length > 0) {
            for (uint256 i = 0; i < whitelist_.length; i++) {
                _whitelist[phase_id][whitelist_[i]] = true;
            }
        }

        emit ClaimPhaseCreated(phase_id, price, start_time, end_time, is_public);
    }

    function update_metadata(string calldata base_uri) external override onlyOwner {
        _baseTokenURI = base_uri;
        emit MetadataUpdated(base_uri);
    }

    function mint(uint256 phase_id, uint256 quantity) external override returns (uint256) {
        address caller = _msgSender();
        require(caller != address(0), "Caller is zero address");
        require(quantity > 0, "Invalid quantity");

        ClaimPhase memory phase = _claimPhases[phase_id];
        require(phase.end_time != 0 || phase.start_time != 0 || phase.is_public || phase.price != 0, "Phase not found");

        uint256 nowTs = block.timestamp;
        require(nowTs >= uint256(phase.start_time), "Phase not started");
        require(nowTs <= uint256(phase.end_time), "Phase ended");

        if (!phase.is_public) {
            require(_whitelist[phase_id][caller], "Not whitelisted");
        }

        // (Paiement non géré ici, comme dans le code Cairo : à intégrer si besoin)

        uint256 firstTokenId = _currentTokenId + 1;
        unchecked {
            for (uint256 i = 0; i < quantity; i++) {
                _safeMint(caller, firstTokenId + i);
            }
            _currentTokenId = firstTokenId + quantity - 1;
        }

        emit TokensMinted(phase_id, firstTokenId, quantity, caller);
        return firstTokenId;
    }

    function get_current_token_id() external view override returns (uint256) {
        return _currentTokenId;
    }

    function get_metadata(uint256 /*token_id*/) external view override returns (string memory) {
        // Cairo renvoie base_uri "tel quel" (pas de concat en get_metadata)
        return _baseTokenURI;
    }

    function get_claim_phase(uint256 phase_id)
        external
        view
        override
        returns (uint256 price, uint64 start_time, uint64 end_time, bool is_public)
    {
        ClaimPhase memory p = _claimPhases[phase_id];
        return (p.price, p.start_time, p.end_time, p.is_public);
    }

    function is_whitelisted(uint256 phase_id, address account) external view override returns (bool) {
        return _whitelist[phase_id][account];
    }

    /* ===================== Helpers & Overrides ===================== */

    // ERC721.tokenURI() d’OZ concatène _baseURI() + tokenId si _baseURI() != ""
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /* ===================== "Upgradeable" analogue ===================== */

    // En Cairo, IUpgradeable::upgrade(new_class_hash) met à jour la class hash.
    // Ici, on expose une version "no-op" (évènement) pour parité d’API.
    // Pour un vrai upgrade, il faut un proxy (UUPS/Transparent). On évite d'induire en erreur.
    function upgrade(bytes32 new_class_hash) external onlyOwner {
        emit UpgradeableUpgraded(new_class_hash);
        // NOTE: pas de logique d'upgrade effective dans un contrat déployé en direct.
        // Utiliser un proxy si nécessaire.
    }
}
