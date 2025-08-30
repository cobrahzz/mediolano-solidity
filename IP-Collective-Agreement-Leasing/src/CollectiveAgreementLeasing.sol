// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Port complet du module Cairo "CollectiveIPAgreement" en Solidity.
 * - ERC1155 de base (URI au constructeur), pas de mint implicite (parité avec l'original)
 * - Gouvernance par propositions/votes pondérés par parts
 * - Distribution de royalties (événements, comme dans l’original)
 * - Résolution de litiges par un "dispute_resolver"
 *
 * NB: les messages d’erreur reprennent le texte des constantes Cairo.
 */
contract CollectiveIPAgreement is ERC1155, Ownable {
    // =========================
    // ======== Types ==========
    // =========================

    struct IPData {
        string metadata_uri;     // IP metadata (IPFS/URL)
        uint32 owner_count;      // nombre de copropriétaires
        uint256 royalty_rate;    // base 1000 (1000 = 100%)
        uint64 expiry_date;      // timestamp (secondes)
        string license_terms;    // conditions de licence (JSON / IPFS)
    }

    struct Proposal {
        address proposer;
        string description;
        uint256 vote_count; // somme des parts "pour" (le Cairo additionne les parts sans tenir compte de support=false)
        bool executed;
        uint64 deadline;    // timestamp (secondes)
    }

    // =========================
    // ======== Storage ========
    // =========================

    // tokenId => IPData
    mapping(uint256 => IPData) private ip_data;

    // (tokenId, index) => owner
    mapping(uint256 => mapping(uint32 => address)) private ownersByIndex;

    // (tokenId, owner) => share (base 1000)
    mapping(uint256 => mapping(address => uint256)) private ownership_shares;

    // tokenId => logical total supply (toujours 1000)
    mapping(uint256 => uint256) private total_supply;

    // proposalId => Proposal
    mapping(uint256 => Proposal) private proposals;

    // (proposalId => (voter => bool))  — a déjà voté ?
    mapping(uint256 => mapping(address => bool)) private votes;

    // compteur global des propositions
    uint256 private proposal_count;

    // adresse autorisée à résoudre les litiges
    address public dispute_resolver;

    // =========================
    // ========= Events ========
    // =========================

    event IPRegistered(uint256 indexed token_id, uint32 owner_count, string metadata_uri);
    event RoyaltyDistributed(uint256 indexed token_id, uint256 amount, address recipient);
    event ProposalCreated(uint256 indexed proposal_id, address indexed proposer, string description);
    event Voted(uint256 indexed proposal_id, address indexed voter, bool vote);
    event ProposalExecuted(uint256 indexed proposal_id, bool success);
    event DisputeResolved(uint256 indexed token_id, address indexed resolver, string resolution);

    // =========================
    // ======== Errors =========
    // =========================
    // On reprend les messages du code Cairo pour rester fidèle.
    string private constant INVALID_METADATA_URI   = "Invalid metadata URI";
    string private constant MISMATCHED_OWNERS_SHARES = "Mismatched owners and shares";
    string private constant NO_OWNERS              = "At least one owner required";
    string private constant INVALID_ROYALTY_RATE   = "Royalty rate exceeds 100%";
    string private constant INVALID_SHARES_SUM     = "Shares must sum to 100%";
    string private constant NO_IP_DATA             = "No IP data found";
    string private constant NOT_OWNER              = "Not an owner";
    string private constant PROPOSAL_EXECUTED      = "Proposal already executed";
    string private constant VOTING_ENDED           = "Voting period ended";
    string private constant ALREADY_VOTED          = "Already voted";
    string private constant VOTING_NOT_ENDED       = "Voting period not ended";
    string private constant INSUFFICIENT_VOTES     = "Insufficient votes";
    string private constant NOT_DISPUTE_RESOLVER   = "Not dispute resolver";

    // =========================
    // ===== Constructor =======
    // =========================

    /**
     * @param owner_             Propriétaire (Ownable)
     * @param uri_               URI ERC1155 avec substituteur {id} si souhaité
     * @param dispute_resolver_  Adresse autorisée à résoudre les litiges
     */
    constructor(address owner_, string memory uri_, address dispute_resolver_)
        ERC1155(uri_)
        Ownable(owner_)
    {
        dispute_resolver = dispute_resolver_;
    }

    // =========================
    // ====== External API =====
    // =========================

    /**
     * Enregistre une IP collective.
     * Parité avec `register_ip` du contrat Cairo.
     */
    function register_ip(
        uint256 token_id,
        string memory metadata_uri,
        address[] memory owners_,
        uint256[] memory ownership_shares_,
        uint256 royalty_rate,
        uint64 expiry_date,
        string memory license_terms
    ) external onlyOwner {
        require(bytes(metadata_uri).length > 0, INVALID_METADATA_URI);
        require(owners_.length == ownership_shares_.length, MISMATCHED_OWNERS_SHARES);
        require(owners_.length > 0, NO_OWNERS);
        require(royalty_rate <= 1000, INVALID_ROYALTY_RATE); // 1000 = 100%

        uint256 sum_shares;
        for (uint256 i = 0; i < ownership_shares_.length; i++) {
            sum_shares += ownership_shares_[i];
        }
        require(sum_shares == 1000, INVALID_SHARES_SUM);

        // Stocke les métadonnées
        ip_data[token_id] = IPData({
            metadata_uri: metadata_uri,
            owner_count: uint32(owners_.length),
            royalty_rate: royalty_rate,
            expiry_date: expiry_date,
            license_terms: license_terms
        });

        // Stocke propriétaires et parts
        for (uint32 i = 0; i < owners_.length; i++) {
            address ownerAddr = owners_[i];
            uint256 share = ownership_shares_[i];
            ownersByIndex[token_id][i] = ownerAddr;
            ownership_shares[token_id][ownerAddr] = share;
        }

        // L’offre logique est fixée à 1000 (=100%) pour refléter les parts
        total_supply[token_id] = 1000;

        emit IPRegistered(token_id, uint32(owners_.length), metadata_uri);
    }

    /**
     * Distribue les royalties aux co-propriétaires (émission d’événements,
     * la logique Cairo ne transfère pas de fonds).
     */
    function distribute_royalties(uint256 token_id, uint256 total_amount) external onlyOwner {
        IPData memory d = ip_data[token_id];
        require(d.owner_count > 0, NO_IP_DATA);

        uint256 royalty_amount = (total_amount * d.royalty_rate) / 1000;

        for (uint32 i = 0; i < d.owner_count; i++) {
            address ownerAddr = ownersByIndex[token_id][i];
            uint256 share = ownership_shares[token_id][ownerAddr];
            uint256 owner_amount = (royalty_amount * share) / 1000;
            emit RoyaltyDistributed(token_id, owner_amount, ownerAddr);
        }
    }

    /**
     * Crée une proposition de gouvernance (seuls les copropriétaires peuvent proposer).
     */
    function create_proposal(uint256 token_id, string memory description) external {
        IPData memory d = ip_data[token_id];
        require(_is_owner(token_id, d.owner_count, msg.sender), NOT_OWNER);

        uint256 proposal_id = ++proposal_count;

        proposals[proposal_id] = Proposal({
            proposer: msg.sender,
            description: description,
            vote_count: 0,
            executed: false,
            deadline: uint64(block.timestamp + 7 days)
        });

        emit ProposalCreated(proposal_id, msg.sender, description);
    }

    /**
     * Vote (pondéré par les parts). Le Cairo additionne les parts
     * indépendamment du booléen `support`; on reproduit ce comportement.
     */
    function vote(uint256 token_id, uint256 proposal_id, bool support) external {
        IPData memory d = ip_data[token_id];
        require(_is_owner(token_id, d.owner_count, msg.sender), NOT_OWNER);

        Proposal memory p = proposals[proposal_id];
        require(!p.executed, PROPOSAL_EXECUTED);
        require(block.timestamp <= p.deadline, VOTING_ENDED);
        require(!votes[proposal_id][msg.sender], ALREADY_VOTED);

        uint256 share = ownership_shares[token_id][msg.sender];
        p.vote_count += share;

        proposals[proposal_id] = p;
        votes[proposal_id][msg.sender] = true;

        emit Voted(proposal_id, msg.sender, support);
    }

    /**
     * Exécute une proposition si >50% des parts ont voté.
     */
    function execute_proposal(uint256 /*token_id*/, uint256 proposal_id) external {
        Proposal memory p = proposals[proposal_id];
        require(!p.executed, PROPOSAL_EXECUTED);
        require(block.timestamp > p.deadline, VOTING_NOT_ENDED);

        uint256 total_votes = p.vote_count;
        require(total_votes > 500, INSUFFICIENT_VOTES); // >50% (base 1000)

        p.executed = true;
        proposals[proposal_id] = p;

        // Parité avec l’original : on n’a qu’un événement (pas de logique « réelle » ici).
        emit ProposalExecuted(proposal_id, true);
    }

    /**
     * Résolution de litige — uniquement par le "dispute_resolver".
     */
    function resolve_dispute(uint256 token_id, string memory resolution) external {
        require(msg.sender == dispute_resolver, NOT_DISPUTE_RESOLVER);
        emit DisputeResolved(token_id, msg.sender, resolution);
    }

    // ========= Getters (parité avec l’interface Cairo) =========

    function get_ip_metadata(uint256 token_id) external view returns (IPData memory) {
        return ip_data[token_id];
    }

    function get_owner(uint256 token_id, uint32 index) external view returns (address) {
        IPData memory d = ip_data[token_id];
        require(index < d.owner_count, "Index out of bounds");
        return ownersByIndex[token_id][index];
    }

    function get_ownership_share(uint256 token_id, address owner_) external view returns (uint256) {
        return ownership_shares[token_id][owner_];
    }

    function get_proposal(uint256 proposal_id) external view returns (Proposal memory) {
        return proposals[proposal_id];
    }

    function get_total_supply(uint256 token_id) external view returns (uint256) {
        return total_supply[token_id];
    }

    function set_dispute_resolver(address new_resolver) external onlyOwner {
        dispute_resolver = new_resolver;
    }

    // =========================
    // ====== Internal =========
    // =========================

    function _is_owner(uint256 token_id, uint32 owner_count, address who) internal view returns (bool) {
        for (uint32 i = 0; i < owner_count; i++) {
            if (ownersByIndex[token_id][i] == who) return true;
        }
        return false;
    }
}
