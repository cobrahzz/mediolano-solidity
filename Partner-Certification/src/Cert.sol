// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Mediolano Certified Partner Contract (Solidity port)
/// @notice DAO-governed partner certification with NFT identity & integration data

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// Partner integration configuration structure
struct IntegrationData {
    uint256 template_id; // felt252 -> uint256
    uint256 config_hash; // felt252 -> uint256
}

contract PartnerCertification {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Certification status
    uint256 private constant STATUS_NONE     = 0;
    uint256 private constant STATUS_PENDING  = 1;
    uint256 private constant STATUS_APPROVED = 2;
    uint256 private constant STATUS_REJECTED = 3;
    uint256 private constant STATUS_REVOKED  = 4;

    // Governance params (exposés pour info, non utilisés dans ce port)
    uint64  public constant VOTING_DELAY        = 86400;      // 1 day
    uint64  public constant VOTING_PERIOD       = 604800;     // 1 week
    uint256 public constant PROPOSAL_THRESHOLD  = 10;
    uint256 public constant QUORUM              = 100_000_000;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CertificationRequested(address indexed user, uint64 timestamp);
    event CertificationApproved(address indexed applicant, uint256 tier);
    event CertificationRejected(address indexed applicant);
    event CertificationRevoked(address indexed partner);
    event IntegrationConfigUpdated(address indexed user, uint256 template_id, uint256 config_hash);
    event TierUpdated(address indexed partner, uint256 new_tier);
    event NoteAssigned(address indexed partner, uint256 note_hash);
    event NftIdentityAssigned(address indexed partner, uint256 nft_id);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    // Governance executor (timelock/executor) : seul autorisé à exécuter les actions gouvernées
    address public immutable governanceExecutor;

    // Token de vote (info) et registre NFT utilisé pour l’identité
    address public immutable votesToken;
    address public nftRegistry;

    // Partner certification data
    mapping(address => uint256) private certified_partners;      // status
    mapping(address => IntegrationData) private integration_data;
    mapping(address => uint64)  private registration_timestamps;
    mapping(address => uint256) private tiered_status;           // tier
    mapping(address => uint256) private notes;                   // note_hash
    mapping(address => uint256) private nft_identity;            // tokenId

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param votes_token    Adresse du token de vote (info)
    /// @param timelock_exec  Adresse de l’exécuteur de gouvernance (timelock/controller)
    /// @param nft_contract   Registre ERC721 pour l’identité NFT
    constructor(address votes_token, address timelock_exec, address nft_contract) {
        require(timelock_exec != address(0), "gov exec zero");
        votesToken = votes_token;
        governanceExecutor = timelock_exec;
        nftRegistry = nft_contract;

        // Pour permettre update_integration_config (voir code Cairo), on marque le timelock comme "approved".
        // Sinon, l’assertion "caller must be approved" empêcherait tout usage.
        certified_partners[governanceExecutor] = STATUS_APPROVED;
        registration_timestamps[governanceExecutor] = uint64(block.timestamp);
        tiered_status[governanceExecutor] = 1;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGovernance() {
        require(msg.sender == governanceExecutor, "only governance");
        _;
    }

    function _assert_zero_status(address account) internal view {
        require(certified_partners[account] == STATUS_NONE, "Already registered");
    }

    function _validate_pending_status(address account) internal view {
        require(certified_partners[account] == STATUS_PENDING, "Invalid status");
    }

    function _validate_approved_status(address account) internal view {
        require(certified_partners[account] == STATUS_APPROVED, "Not approved");
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// Permissionless certification request
    function request_certification() external {
        address caller = msg.sender;
        _assert_zero_status(caller);

        certified_partners[caller] = STATUS_PENDING;
        registration_timestamps[caller] = uint64(block.timestamp);

        emit CertificationRequested(caller, uint64(block.timestamp));
    }

    /// Governance-approved certification (only timelock/executor)
    function approve_certification(address applicant) external onlyGovernance {
        _validate_pending_status(applicant);

        uint256 default_tier = 1;
        certified_partners[applicant] = STATUS_APPROVED;
        tiered_status[applicant] = default_tier;

        emit CertificationApproved(applicant, default_tier);
    }

    /// Governance-rejected certification (only timelock/executor)
    function reject_certification(address applicant) external onlyGovernance {
        _validate_pending_status(applicant);
        certified_partners[applicant] = STATUS_REJECTED;
        emit CertificationRejected(applicant);
    }

    /// Governance-revoked certification (only timelock/executor)
    function revoke_certification(address partner) external onlyGovernance {
        _validate_approved_status(partner);
        certified_partners[partner] = STATUS_REVOKED;
        emit CertificationRevoked(partner);
    }

    /// Partner integration update (governance-controlled, see Cairo note)
    /// NB: en Cairo, la donnée était enregistrée pour le "caller" (le timelock).
    /// Ici on reproduit ce comportement : c’est la donnée d’intégration du caller (gouvernance).
    function update_integration_config(uint256 template_id, uint256 config_hash) external onlyGovernance {
        address caller = msg.sender;
        _validate_approved_status(caller); // s’applique au timelock (marqué approuvé en constructor)
        integration_data[caller] = IntegrationData({ template_id: template_id, config_hash: config_hash });
        emit IntegrationConfigUpdated(caller, template_id, config_hash);
    }

    /// Tier update through governance
    function update_tier(address partner, uint256 new_tier) external onlyGovernance {
        _validate_approved_status(partner);
        tiered_status[partner] = new_tier;
        emit TierUpdated(partner, new_tier);
    }

    /// Note assignment through governance
    function assign_note(address partner, uint256 note_hash) external onlyGovernance {
        notes[partner] = note_hash;
        emit NoteAssigned(partner, note_hash);
    }

    /// NFT identity assignment with ownership verification (only governance)
    function assign_nft_identity(address partner, uint256 nft_id) external onlyGovernance {
        require(nftRegistry != address(0), "nft registry unset");
        address owner = IERC721Minimal(nftRegistry).ownerOf(nft_id);
        require(owner == partner, "Partner doesn't own NFT");
        nft_identity[partner] = nft_id;
        emit NftIdentityAssigned(partner, nft_id);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function get_partner_status(address account) external view returns (uint256) {
        return certified_partners[account];
    }

    function get_integration_data(address account) external view returns (IntegrationData memory) {
        return integration_data[account];
    }

    function get_registration_timestamp(address account) external view returns (uint64) {
        return registration_timestamps[account];
    }

    function get_tier(address account) external view returns (uint256) {
        return tiered_status[account];
    }

    function get_note(address account) external view returns (uint256) {
        return notes[account];
    }

    function get_nft_identity(address account) external view returns (uint256) {
        return nft_identity[account];
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN/UTILITY (OPTIONNEL)
    //////////////////////////////////////////////////////////////*/

    /// Permet de mettre à jour le registre NFT si nécessaire (gouvernance)
    function set_nft_registry(address newRegistry) external onlyGovernance {
        nftRegistry = newRegistry;
    }
}
