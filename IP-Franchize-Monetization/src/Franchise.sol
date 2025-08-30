// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    ─────────────────────────────────────────────────────────────────────────
    OpenZeppelin imports (assure-toi d'installer @openzeppelin/contracts)
    ─────────────────────────────────────────────────────────────────────────
*/
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/*
    ─────────────────────────────────────────────────────────────────────────
    Mock ERC20 (équivalent MockERC20 Cairo)
    - constructeur: name, symbol, fixedSupply (non utilisé pour coller au Cairo)
    - mint(address,uint256) : pas de contrôle d'accès (idem Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 /*fixedSupplyIgnored*/) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*
    ─────────────────────────────────────────────────────────────────────────
    Mock ERC721 (équivalent MockERC721 Cairo)
    - constructor fixe name/symbol comme Cairo ("Mediolano","MED") et baseURI
    - mint(address,uint256) : pas de contrôle d'accès (idem Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
contract MockERC721 is ERC721 {
    string private _base;

    constructor(string memory baseUri_) ERC721("Mediolano", "MED") {
        _base = baseUri_;
    }

    function _baseURI() internal view override returns (string memory) {
        return _base;
    }

    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

/*
    ─────────────────────────────────────────────────────────────────────────
    Erreurs (équivalents des constantes felt252 Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
error InvalidIpAsset();
error NotOwnerErr();                 // "Caller not asset owner"
error NotApprovedErr();              // "ip asset not approved by owner"
error IpAssetNotLinked();
error IpAssetAlreadyLinked();
error InvalidIpId();
error InvalidIpNftId();
error InvalidIpNftAddress();

error InvalidTerritoryId();
error RoyaltyFeesNotAllowed();
error TerritoryAlreadyLinked();
error ApplicationNotApproved();
error NotApplicationOwner();
error CannotCancelApplication();
error NotAuthorized();
error InvalidApplicationStatus();
error AgreementLicenseNotOver();
error TerritoryNotActive();
error FranchiseAgreementNotListed();

error Erc20TransferFailed();
error SaleRequestNotFound();
error InvalidSaleStatus();
error OnlyBuyerCanFinalizeSale();
error RevenueMismatch();
error InvalidRevenueAmount();
error InvalidRoyaltyAmount();
error FranchiseIpNotLinked();
error FranchiseAgreementNotActive();
error MaxMissedPaymentsNotReached();
error MissedPaymentsExceedsMax();
error ActiveSaleRequestInProgress();
error OnlyRoyaltyPayments();

error StartDateInThePast();
error StartDateAfterEndDate();
error EndDateInThePast();
error EndDateTooFar();
error FranchiseFeeRequired();
error OneTimeFeeRequired();
error RoyaltyPercentRequired();
error RoyaltyPercentTooHigh();
error CustomIntervalRequired();
error CustomIntervalBelowMinimum();
error InvalidTokenAddress();
error InvalidPaymentInterval();
error MaxMissedPaymentsRequired();
error LastPaymentIdMustBeZero();

/*
    ─────────────────────────────────────────────────────────────────────────
    Types / Enums (équivalents Cairo -> Solidity)
    ─────────────────────────────────────────────────────────────────────────
*/
enum PaymentSchedule { Monthly, Quarterly, SemiAnnually, Annually, Custom }
enum ExclusivityType { Exclusive, NonExclusive }
enum FranchiseSaleStatus { Pending, Approved, Rejected, Completed }
enum ApplicationStatus { Pending, Revised, RevisionAccepted, Approved, Rejected, Cancelled }
enum PaymentModelKind { OneTime, RoyaltyBased }

struct RoyaltyFees {
    uint8  royaltyPercent;         // 1..100
    PaymentSchedule paymentSchedule;
    uint64 customInterval;         // en secondes
    bool   hasCustomInterval;
    uint32 lastPaymentId;          // commence à 0
    uint32 maxMissedPayments;      // > 0
}

struct FranchiseTerms {
    PaymentModelKind kind;         // OneTime ou RoyaltyBased
    address paymentToken;          // IERC20
    uint256 franchiseFee;          // frais d’activation (toujours payé)
    uint64  licenseStart;          // timestamp futur
    uint64  licenseEnd;            // > start, <= start + 5 ans
    ExclusivityType exclusivity;   // territoire exclusif ?
    uint256 territoryId;

    // payload du modèle de paiement :
    uint256 oneTimeFee;            // utilisé si kind == OneTime
    RoyaltyFees royaltyFees;       // utilisé si kind == RoyaltyBased
}

struct Territory {
    uint256 id;
    string  name;
    bool    hasExclusiveAgreement;
    uint256 exclusiveAgreementId;  // valide si hasExclusiveAgreement==true
    bool    active;
}

struct FranchiseApplication {
    uint256 applicationId;
    address franchisee;
    FranchiseTerms currentTerms;
    ApplicationStatus status;
    address lastProposedBy;
    uint8   version;
}

struct FranchiseSaleRequest {
    address from;
    address to;
    uint256 salePrice;
    FranchiseSaleStatus status;
}

struct RoyaltyPayment {
    uint32 paymentId;
    uint256 royaltyPaid;
    uint256 reportedRevenue;
    uint64 timestamp;
}

/*
    ─────────────────────────────────────────────────────────────────────────
    Libs de validation/calcul (équivalents des traits Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
library FranchiseLib {
    function _paymentInterval(RoyaltyFees memory rf) internal pure returns (uint64) {
        if (rf.paymentSchedule == PaymentSchedule.Monthly) return 30 * 24 * 60 * 60;
        if (rf.paymentSchedule == PaymentSchedule.Quarterly) return 3 * 30 * 24 * 60 * 60;
        if (rf.paymentSchedule == PaymentSchedule.SemiAnnually) return 6 * 30 * 24 * 60 * 60;
        if (rf.paymentSchedule == PaymentSchedule.Annually) return 365 * 24 * 60 * 60;
        if (rf.paymentSchedule == PaymentSchedule.Custom) {
            return rf.hasCustomInterval ? rf.customInterval : 0;
        }
        return 0;
    }

    function validateTerms(FranchiseTerms memory t, uint64 nowTs) internal pure {
        if (t.licenseStart <= nowTs) revert StartDateInThePast();
        if (t.licenseStart >= t.licenseEnd) revert StartDateAfterEndDate();
        if (t.licenseEnd <= nowTs) revert EndDateInThePast();
        // max 5 ans
        uint64 maxEnd = nowTs + uint64(5 * 365 days);
        if (t.licenseEnd >= maxEnd) revert EndDateTooFar();
        if (t.paymentToken == address(0)) revert InvalidTokenAddress();
        if (t.franchiseFee == 0) revert FranchiseFeeRequired();

        if (t.kind == PaymentModelKind.OneTime) {
            if (t.oneTimeFee == 0) revert OneTimeFeeRequired();
        } else {
            // RoyaltyBased
            if (t.royaltyFees.royaltyPercent == 0) revert RoyaltyPercentRequired();
            if (t.royaltyFees.royaltyPercent > 100) revert RoyaltyPercentTooHigh();
            if (t.royaltyFees.maxMissedPayments == 0) revert MaxMissedPaymentsRequired();
            if (t.royaltyFees.lastPaymentId != 0) revert LastPaymentIdMustBeZero();

            if (t.royaltyFees.paymentSchedule == PaymentSchedule.Custom) {
                if (!t.royaltyFees.hasCustomInterval) revert CustomIntervalRequired();
                if (t.royaltyFees.customInterval < 1 days) revert CustomIntervalBelowMinimum();
            }

            uint64 interval = _paymentInterval(t.royaltyFees);
            if (interval == 0 || (t.licenseEnd - t.licenseStart) <= interval) {
                revert InvalidPaymentInterval();
            }
        }
    }

    function totalFranchiseFee(FranchiseTerms memory t) internal pure returns (uint256) {
        if (t.kind == PaymentModelKind.OneTime) {
            return t.franchiseFee + t.oneTimeFee;
        } else {
            return t.franchiseFee;
        }
    }

    function royaltyDue(RoyaltyFees memory rf, uint256 revenue) internal pure returns (uint256) {
        return (revenue * rf.royaltyPercent) / 100;
    }

    function calculateMissedPayments(
        RoyaltyFees memory rf,
        uint64 licenseStart,
        uint64 nowTs
    ) internal pure returns (uint32 missed) {
        uint64 interval = _paymentInterval(rf);
        if (interval == 0 || nowTs < licenseStart) return 0;

        uint64 totalDue = (nowTs - licenseStart) / interval;
        if (totalDue <= rf.lastPaymentId) return 0;

        uint64 diff = totalDue - rf.lastPaymentId;
        if (diff > type(uint32).max) diff = type(uint32).max;
        missed = uint32(diff);
    }

    function nextPaymentDue(RoyaltyFees memory rf, uint64 licenseStart) internal pure returns (uint64) {
        uint64 interval = _paymentInterval(rf);
        if (interval == 0) return licenseStart;
        return licenseStart + (uint64(rf.lastPaymentId + 1) * interval);
    }
}

/*
    ─────────────────────────────────────────────────────────────────────────
    Interfaces (équivalents Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
interface IIPFranchiseAgreement {
    function activate_franchise() external;

    function create_sale_request(address to, uint256 salePrice) external;
    function approve_franchise_sale() external;
    function reject_franchise_sale() external;
    function finalize_franchise_sale() external;

    function make_royalty_payments(uint256[] calldata reportedRevenues) external;

    function revoke_franchise_license() external;
    function reinstate_franchise_license() external;

    // Views
    function get_agreement_id() external view returns (uint256);
    function get_franchise_manager() external view returns (address);
    function get_franchisee() external view returns (address);
    function get_payment_token() external view returns (address);
    function get_franchise_terms() external view returns (FranchiseTerms memory);
    function get_sale_request() external view returns (bool exists, FranchiseSaleRequest memory req);
    function get_royalty_payment_info(uint32 paymentId) external view returns (RoyaltyPayment memory);
    function is_active() external view returns (bool);
    function is_revoked() external view returns (bool);
    function get_activation_fee() external view returns (uint256);
    function get_total_missed_payments() external view returns (uint32);
}

interface IIPFranchiseManager {
    function link_ip_asset() external;
    function unlink_ip_asset() external;

    function add_franchise_territory(string calldata name) external;
    function deactivate_franchise_territory(uint256 territoryId) external;

    function create_direct_franchise_agreement(address franchisee, FranchiseTerms calldata terms) external;
    function create_franchise_agreement_from_application(uint256 applicationId) external;

    function apply_for_franchise(FranchiseTerms calldata terms) external;
    function cancel_franchise_application(uint256 applicationId) external;
    function revise_franchise_application(uint256 applicationId, FranchiseTerms calldata newTerms) external;
    function accept_franchise_application_revision(uint256 applicationId) external;
    function approve_franchise_application(uint256 applicationId) external;
    function reject_franchise_application(uint256 applicationId) external;

    function revoke_franchise_license(uint256 agreementId) external;
    function reinstate_franchise_license(uint256 agreementId) external;

    function initiate_franchise_sale(uint256 agreementId) external;
    function approve_franchise_sale(uint256 agreementId) external;
    function reject_franchise_sale(uint256 agreementId) external;

    // upgrade placeholder (parité d'API)
    function upgrade(address newImpl) external;

    // Views
    function get_ip_nft_id() external view returns (uint256);
    function get_ip_nft_address() external view returns (address);
    function is_ip_asset_linked() external view returns (bool);

    function get_territory_info(uint256 territoryId) external view returns (Territory memory);
    function get_total_territories() external view returns (uint256);

    function get_franchise_agreement_address(uint256 agreementId) external view returns (address);
    function get_franchise_agreement_id(address agreement) external view returns (uint256);
    function get_total_franchise_agreements() external view returns (uint256);
    function get_franchisee_agreement(address franchisee, uint256 index) external view returns (uint256);
    function get_franchisee_agreement_count(address franchisee) external view returns (uint256);

    function get_franchise_application(uint256 applicationId, uint8 version) external view returns (FranchiseApplication memory);
    function get_franchise_application_version(uint256 applicationId) external view returns (uint8);
    function get_total_franchise_applications() external view returns (uint256);
    function get_franchisee_application(address franchisee, uint256 index) external view returns (uint256);
    function get_franchisee_application_count(address franchisee) external view returns (uint256);

    function get_preferred_payment_model() external view returns (FranchiseTerms memory);
    function get_default_franchise_fee() external view returns (uint256);

    function is_franchise_sale_requested(uint256 agreementId) external view returns (bool);
    function get_total_franchise_sale_requests() external view returns (uint256);
}

/*
    ─────────────────────────────────────────────────────────────────────────
    Événements (équivalents Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
contract EventsDefs {
    event IPAssetLinked(uint256 ip_token_id, address ip_token_address, address owner, uint64 timestamp);
    event IPAssetUnLinked(uint256 ip_token_id, address ip_token_address, address owner, uint64 timestamp);

    event FranchiseAgreementCreated(uint256 agreement_id, address agreement_address, address franchisee, uint64 timestamp);

    event NewFranchiseApplication(uint256 application_id, address franchisee, uint64 timestamp);
    event FranchiseApplicationRevised(uint256 application_id, address reviser, uint8 application_version, uint64 timestamp);
    event ApplicationRevisionAccepted(uint256 application_id, address franchisee, uint64 timestamp);
    event FranchiseApplicationCanceled(uint256 application_id, address franchisee, uint64 timestamp);
    event FranchiseApplicationApproved(uint256 application_id, uint64 timestamp);
    event FranchiseApplicationRejected(uint256 application_id, uint64 timestamp);

    event FranchiseSaleInitiated(uint256 agreement_id, uint256 sale_id, uint64 timestamp);
    event FranchiseSaleApproved(uint256 agreement_id, address agreement_address, uint64 timestamp);
    event FranchiseSaleRejected(uint256 agreement_id, address agreement_address, uint64 timestamp);
    event FranchiseAgreementRevoked(uint256 agreement_id, address agreement_address, uint64 timestamp);
    event FranchiseAgreementReinstated(uint256 agreement_id, address agreement_address, uint64 timestamp);

    event FranchiseAgreementActivated(uint256 agreement_id, uint64 timestamp);
    event SaleRequestInitiated(uint256 agreement_id, uint256 sale_price, address to, uint64 timestamp);
    event SaleRequestApproved(uint256 agreement_id, uint64 timestamp);
    event SaleRequestRejected(uint256 agreement_id, uint64 timestamp);
    event SaleRequestFinalized(uint256 agreement_id, address new_franchisee, uint64 timestamp);
    event RoyaltyPaymentMade(uint256 agreement_id, uint256 total_royalty, uint256 total_revenue, uint64 timestamp);

    event FranchiseLicenseRevoked(uint256 agreement_id, uint64 timestamp);
    event FranchiseLicenseReinstated(uint256 agreement_id, uint64 timestamp);

    event NewTerritoryAdded(uint256 territory_id, string name, uint64 timestamp);
    event TerritoryDeactivated(uint256 territory_id, uint64 timestamp);
}

/*
    ─────────────────────────────────────────────────────────────────────────
    IPFranchisingAgreement (équivalent Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
contract IPFranchisingAgreement is IIPFranchiseAgreement, AccessControl, Ownable, EventsDefs {
    using FranchiseLib for FranchiseTerms;
    using FranchiseLib for RoyaltyFees;

    // Rôles
    bytes32 public constant FRANCHISEE_ROLE = keccak256("FRANCHISER_ROLE"); // même chaîne que Cairo
    bytes32 public constant APPROVED_BUYER_ROLE = keccak256("APPROVED_BUYER");

    // Storage
    uint256 private _agreementId;
    address private _franchiseManager;
    address private _franchisee;
    FranchiseTerms private _terms;

    bool private _hasSaleRequest;
    FranchiseSaleRequest private _saleRequest;

    mapping(uint32 => RoyaltyPayment) private _royaltyPayments;

    bool private _isActiveFlag;
    bool private _isRevokedFlag;

    constructor(
        uint256 agreementId,
        address franchiseManager,
        address franchisee,
        FranchiseTerms memory terms
    ) Ownable(franchiseManager) { // <-- important pour OZ v5
        _agreementId = agreementId;
        _franchiseManager = franchiseManager;
        _franchisee = franchisee;
        _terms = terms;

        // _transferOwnership(franchiseManager); // <- à supprimer

        _grantRole(DEFAULT_ADMIN_ROLE, franchiseManager);
        _grantRole(FRANCHISEE_ROLE, franchisee);

        _isActiveFlag = false;
        _isRevokedFlag = false;
    }

    // ───────────────────── Logic ─────────────────────

    function activate_franchise() external override onlyRole(FRANCHISEE_ROLE) {
        // Vérifie que l'IP est toujours liée côté manager
        if (!IIPFranchiseManager(_franchiseManager).is_ip_asset_linked()) revert FranchiseIpNotLinked();

        uint256 totalFee = _terms.totalFranchiseFee();
        if (totalFee > 0) {
            bool ok = IERC20(_terms.paymentToken).transferFrom(msg.sender, _franchiseManager, totalFee);
            if (!ok) revert Erc20TransferFailed();
        }

        _isActiveFlag = true;
        emit FranchiseAgreementActivated(_agreementId, uint64(block.timestamp));
    }

    function create_sale_request(address to, uint256 salePrice) external override onlyRole(FRANCHISEE_ROLE) {
        if (!is_active()) revert FranchiseAgreementNotActive();
        if (!IIPFranchiseManager(_franchiseManager).is_ip_asset_linked()) revert FranchiseIpNotLinked();

        if (_hasSaleRequest) {
            // En Cairo, le test est légèrement bogué (Rejected || Rejected). Ici on empêche une demande active.
            if (_saleRequest.status == FranchiseSaleStatus.Pending || _saleRequest.status == FranchiseSaleStatus.Approved) {
                revert ActiveSaleRequestInProgress();
            }
        }

        _saleRequest = FranchiseSaleRequest({
            from: _franchisee,
            to: to,
            salePrice: salePrice,
            status: FranchiseSaleStatus.Pending
        });
        _hasSaleRequest = true;

        IIPFranchiseManager(_franchiseManager).initiate_franchise_sale(_agreementId);
        emit SaleRequestInitiated(_agreementId, salePrice, to, uint64(block.timestamp));
    }

    function approve_franchise_sale() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_hasSaleRequest) revert SaleRequestNotFound();
        if (_saleRequest.status != FranchiseSaleStatus.Pending) revert InvalidSaleStatus();

        _saleRequest.status = FranchiseSaleStatus.Approved;
        _grantRole(APPROVED_BUYER_ROLE, _saleRequest.to);

        emit SaleRequestApproved(_agreementId, uint64(block.timestamp));
    }

    function reject_franchise_sale() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_hasSaleRequest) revert SaleRequestNotFound();
        if (_saleRequest.status != FranchiseSaleStatus.Pending) revert InvalidSaleStatus();

        _saleRequest.status = FranchiseSaleStatus.Rejected;
        emit SaleRequestRejected(_agreementId, uint64(block.timestamp));
    }

    function finalize_franchise_sale() external override onlyRole(APPROVED_BUYER_ROLE) {
        if (!_hasSaleRequest) revert SaleRequestNotFound();
        if (_saleRequest.status != FranchiseSaleStatus.Approved) revert InvalidSaleStatus();
        if (msg.sender != _saleRequest.to) revert OnlyBuyerCanFinalizeSale();

        // split: 20% manager, 80% vendeur
        uint256 fee = (_saleRequest.salePrice * 20) / 100;
        uint256 sellerAmount = _saleRequest.salePrice - fee;

        IERC20 token = IERC20(_terms.paymentToken);
        bool ok1 = token.transferFrom(msg.sender, _franchiseManager, fee);
        bool ok2 = token.transferFrom(msg.sender, _franchisee, sellerAmount);
        if (!ok1 || !ok2) revert Erc20TransferFailed();

        // rôles
        _revokeRole(FRANCHISEE_ROLE, _franchisee);
        _revokeRole(APPROVED_BUYER_ROLE, _saleRequest.to);
        _franchisee = _saleRequest.to;
        _grantRole(FRANCHISEE_ROLE, _franchisee);

        _saleRequest.status = FranchiseSaleStatus.Completed;

        emit SaleRequestFinalized(_agreementId, _franchisee, uint64(block.timestamp));
    }

    function make_royalty_payments(uint256[] calldata reportedRevenues) external override {
        if (_terms.kind != PaymentModelKind.RoyaltyBased) revert OnlyRoyaltyPayments();

        RoyaltyFees memory rf = _terms.royaltyFees;
        uint32 missed = rf.calculateMissedPayments(_terms.licenseStart, uint64(block.timestamp));
        if (reportedRevenues.length != missed) revert RevenueMismatch();

        uint256 totalRoyalty = 0;
        uint256 totalRevenue = 0;
        uint32 lastPaymentId = rf.lastPaymentId;

        for (uint32 i = 0; i < missed; i++) {
            uint256 revenue = reportedRevenues[i];
            if (revenue == 0) revert InvalidRevenueAmount();
            uint256 royalty = FranchiseLib.royaltyDue(rf, revenue);
            if (royalty == 0) revert InvalidRoyaltyAmount();

            totalRoyalty += royalty;
            totalRevenue += revenue;

            uint32 nextId = lastPaymentId + (i + 1);
            _royaltyPayments[nextId] = RoyaltyPayment({
                paymentId: nextId,
                royaltyPaid: royalty,
                reportedRevenue: revenue,
                timestamp: uint64(block.timestamp)
            });
        }

        bool ok = IERC20(_terms.paymentToken).transferFrom(msg.sender, _franchiseManager, totalRoyalty);
        if (!ok) revert Erc20TransferFailed();

        // update lastPaymentId
        _terms.royaltyFees.lastPaymentId = lastPaymentId + missed;

        emit RoyaltyPaymentMade(_agreementId, totalRoyalty, totalRevenue, uint64(block.timestamp));
    }

    function revoke_franchise_license() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_terms.kind == PaymentModelKind.RoyaltyBased) {
            RoyaltyFees memory rf = _terms.royaltyFees;
            uint32 missed = rf.calculateMissedPayments(_terms.licenseStart, uint64(block.timestamp));
            if (missed < rf.maxMissedPayments) revert MaxMissedPaymentsNotReached();
        }
        _isRevokedFlag = true;
        emit FranchiseLicenseRevoked(_agreementId, uint64(block.timestamp));
    }

    function reinstate_franchise_license() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_terms.kind == PaymentModelKind.RoyaltyBased) {
            RoyaltyFees memory rf = _terms.royaltyFees;
            uint32 missed = rf.calculateMissedPayments(_terms.licenseStart, uint64(block.timestamp));
            if (missed >= rf.maxMissedPayments) revert MissedPaymentsExceedsMax();
        }
        _isRevokedFlag = false;
        emit FranchiseLicenseReinstated(_agreementId, uint64(block.timestamp));
    }

    // ───────────────────── Views ─────────────────────

    function get_agreement_id() external view override returns (uint256) { return _agreementId; }
    function get_franchise_manager() external view override returns (address) { return _franchiseManager; }
    function get_franchisee() external view override returns (address) { return _franchisee; }
    function get_payment_token() external view override returns (address) { return _terms.paymentToken; }
    function get_franchise_terms() external view override returns (FranchiseTerms memory) { return _terms; }

    function get_sale_request() external view override returns (bool exists, FranchiseSaleRequest memory req) {
        return (_hasSaleRequest, _saleRequest);
    }

    function get_royalty_payment_info(uint32 paymentId) external view override returns (RoyaltyPayment memory) {
        return _royaltyPayments[paymentId];
    }

    function is_active() public view override returns (bool) {
        if (uint64(block.timestamp) >= _terms.licenseEnd) return false;
        return _isActiveFlag;
    }

    function is_revoked() external view override returns (bool) { return _isRevokedFlag; }

    function get_activation_fee() external view override returns (uint256) {
        return _terms.totalFranchiseFee();
    }

    function get_total_missed_payments() external view override returns (uint32) {
        if (_terms.kind == PaymentModelKind.OneTime) return 0;
        return _terms.royaltyFees.calculateMissedPayments(_terms.licenseStart, uint64(block.timestamp));
    }
}

/*
    ─────────────────────────────────────────────────────────────────────────
    IPFranchiseManager (équivalent Cairo)
    ─────────────────────────────────────────────────────────────────────────
*/
contract IPFranchiseManager is IIPFranchiseManager, Ownable, EventsDefs {
    using FranchiseLib for FranchiseTerms;

    // Stockage principal
    uint256 private _ipNftId;
    address private _ipNft;
    bool    private _ipLinked;

    // Territoires
    mapping(uint256 => Territory) private _territories;
    uint256 private _territoriesCount;

    // Accords
    mapping(uint256 => address) private _agreements;      // id -> address
    mapping(address => uint256) private _agreementIds;    // address -> id
    uint256 private _agreementsCount;

    // Par franchisee
    mapping(address => mapping(uint256 => uint256)) private _franchiseeAgreements;
    mapping(address => uint256) private _franchiseeAgreementCount;

    // Applications (id, version) -> application
    mapping(uint256 => mapping(uint8 => FranchiseApplication)) private _applications;
    mapping(uint256 => uint8) private _applicationVersion;
    uint256 private _applicationsCount;

    mapping(address => mapping(uint256 => uint256)) private _franchiseeApplications;
    mapping(address => uint256) private _franchiseeApplicationCount;

    // Ventes
    mapping(uint256 => bool) private _saleRequested;
    uint256 private _saleRequestsCount;

    // Config par défaut
    FranchiseTerms private _preferredModel; // stocke un gabarit "par défaut"
    uint256 private _defaultFranchiseFee;

    // Upgrade placeholder (parité API)
    address public upgradedTo;

    constructor(
        address owner_,
        uint256 ipId,
        address ipNftAddress,
        uint256 defaultFranchiseFee,
        FranchiseTerms memory preferredPaymentModel
    ) Ownable(owner_) { // <-- important pour OZ v5
        // _transferOwnership(owner_); // <- à supprimer

        _ipNftId = ipId;
        _ipNft = ipNftAddress;
        _defaultFranchiseFee = defaultFranchiseFee;
        _preferredModel = preferredPaymentModel;
        _ipLinked = false;
    }

    // ─────────── Link/Unlink IP NFT ───────────

    function link_ip_asset() external override onlyOwner {
        if (_ipLinked) revert IpAssetAlreadyLinked();

        IERC721 nft = IERC721(_ipNft);
        if (nft.ownerOf(_ipNftId) != msg.sender) revert NotOwnerErr();
        if (!nft.isApprovedForAll(msg.sender, address(this))) revert NotApprovedErr();

        nft.transferFrom(msg.sender, address(this), _ipNftId);
        _ipLinked = true;

        emit IPAssetLinked(_ipNftId, _ipNft, msg.sender, uint64(block.timestamp));
    }

    function unlink_ip_asset() external override onlyOwner {
        if (!_ipLinked) revert IpAssetNotLinked();

        // Tous les accords doivent être inactifs/expirés
        for (uint256 id = 0; id < _agreementsCount; id++) {
            address ag = _agreements[id];
            if (ag != address(0)) {
                if (IIPFranchiseAgreement(ag).is_active()) revert AgreementLicenseNotOver();
            }
        }

        IERC721 nft = IERC721(_ipNft);
        if (nft.ownerOf(_ipNftId) != address(this)) revert NotOwnerErr();

        nft.transferFrom(address(this), msg.sender, _ipNftId);
        _ipLinked = false;

        emit IPAssetUnLinked(_ipNftId, _ipNft, msg.sender, uint64(block.timestamp));
    }

    // ─────────── Territoires ───────────

    function add_franchise_territory(string calldata name) external override onlyOwner {
        uint256 id = _territoriesCount;
        _territories[id] = Territory({
            id: id,
            name: name,
            hasExclusiveAgreement: false,
            exclusiveAgreementId: 0,
            active: true
        });
        _territoriesCount = id + 1;

        emit NewTerritoryAdded(id, name, uint64(block.timestamp));
    }

    function deactivate_franchise_territory(uint256 territoryId) external override onlyOwner {
        Territory memory t = _territories[territoryId];
        if (t.id != territoryId) revert InvalidTerritoryId();
        t.active = false;
        _territories[territoryId] = t;

        emit TerritoryDeactivated(territoryId, uint64(block.timestamp));
    }

    // ─────────── Création d’accords ───────────

    function create_direct_franchise_agreement(address franchisee, FranchiseTerms calldata terms) external override onlyOwner {
        if (!_ipLinked) revert IpAssetNotLinked();
        FranchiseTerms memory t = terms;
        t.validateTerms(uint64(block.timestamp));

        _create_franchise_agreement(franchisee, t);
    }

    function create_franchise_agreement_from_application(uint256 applicationId) external override onlyOwner {
        if (!_ipLinked) revert IpAssetNotLinked();

        uint8 v = _applicationVersion[applicationId];
        FranchiseApplication memory app = _applications[applicationId][v];
        if (app.status != ApplicationStatus.Approved) revert ApplicationNotApproved();

        FranchiseTerms memory t = app.currentTerms;
        t.validateTerms(uint64(block.timestamp));

        _create_franchise_agreement(app.franchisee, t);
    }

    // ─────────── Applications ───────────

    function apply_for_franchise(FranchiseTerms calldata terms) external override {
        if (!_ipLinked) revert IpAssetNotLinked();

        FranchiseTerms memory t = terms;
        t.validateTerms(uint64(block.timestamp));

        // territoire doit être libre et actif
        Territory memory terr = _territories[t.territoryId];
        if (!terr.active) revert TerritoryNotActive();
        if (terr.hasExclusiveAgreement) revert TerritoryAlreadyLinked();

        uint256 id = _applicationsCount;
        uint8 v = _applicationVersion[id]; // 0 à la création

        FranchiseApplication memory app = FranchiseApplication({
            applicationId: id,
            franchisee: msg.sender,
            currentTerms: t,
            status: ApplicationStatus.Pending,
            lastProposedBy: msg.sender,
            version: v
        });

        _applications[id][v] = app;
        _applicationsCount++;

        uint256 idx = _franchiseeApplicationCount[msg.sender];
        _franchiseeApplications[msg.sender][idx] = id;
        _franchiseeApplicationCount[msg.sender] = idx + 1;

        emit NewFranchiseApplication(id, msg.sender, uint64(block.timestamp));
    }

    function revise_franchise_application(uint256 applicationId, FranchiseTerms calldata newTerms) external override {
        uint8 v = _applicationVersion[applicationId];
        FranchiseApplication memory app = _applications[applicationId][v];

        if (msg.sender != app.franchisee && msg.sender != owner()) revert NotAuthorized();
        if (app.status != ApplicationStatus.Pending && app.status != ApplicationStatus.Revised) revert InvalidApplicationStatus();

        FranchiseTerms memory t = newTerms;
        t.validateTerms(uint64(block.timestamp));

        Territory memory terr = _territories[t.territoryId];
        if (!terr.active) revert TerritoryNotActive();
        if (terr.hasExclusiveAgreement) revert TerritoryAlreadyLinked();

        app.currentTerms = t;
        app.lastProposedBy = msg.sender;
        app.status = ApplicationStatus.Revised;

        uint8 newV = v + 1;
        _applicationVersion[applicationId] = newV;
        _applications[applicationId][newV] = app;

        emit FranchiseApplicationRevised(applicationId, msg.sender, newV, uint64(block.timestamp));
    }

    function accept_franchise_application_revision(uint256 applicationId) external override {
        uint8 v = _applicationVersion[applicationId];
        FranchiseApplication memory app = _applications[applicationId][v];

        if (msg.sender != app.franchisee) revert NotAuthorized();
        if (app.status != ApplicationStatus.Revised) revert InvalidApplicationStatus();

        app.status = ApplicationStatus.RevisionAccepted;
        _applications[applicationId][v] = app;

        emit ApplicationRevisionAccepted(applicationId, msg.sender, uint64(block.timestamp));
    }

    function cancel_franchise_application(uint256 applicationId) external override {
        uint8 v = _applicationVersion[applicationId];
        FranchiseApplication memory app = _applications[applicationId][v];

        if (msg.sender != app.franchisee) revert NotApplicationOwner();
        if (app.status != ApplicationStatus.Pending) revert CannotCancelApplication();

        app.status = ApplicationStatus.Cancelled;
        _applications[applicationId][v] = app;

        emit FranchiseApplicationCanceled(applicationId, msg.sender, uint64(block.timestamp));
    }

    function approve_franchise_application(uint256 applicationId) external override onlyOwner {
        uint8 v = _applicationVersion[applicationId];
        FranchiseApplication memory app = _applications[applicationId][v];

        if (app.status != ApplicationStatus.Pending && app.status != ApplicationStatus.RevisionAccepted) {
            revert InvalidApplicationStatus();
        }

        app.status = ApplicationStatus.Approved;
        _applications[applicationId][v] = app;

        emit FranchiseApplicationApproved(applicationId, uint64(block.timestamp));
    }

    function reject_franchise_application(uint256 applicationId) external override onlyOwner {
        uint8 v = _applicationVersion[applicationId];
        FranchiseApplication memory app = _applications[applicationId][v];

        if (app.status != ApplicationStatus.Pending && app.status != ApplicationStatus.RevisionAccepted) {
            revert InvalidApplicationStatus();
        }

        app.status = ApplicationStatus.Rejected;
        _applications[applicationId][v] = app;

        emit FranchiseApplicationRejected(applicationId, uint64(block.timestamp));
    }

    // ─────────── Ventes (pilotées par l’accord) ───────────

    function initiate_franchise_sale(uint256 agreementId) external override {
        address ag = _agreements[agreementId];
        if (ag == address(0)) revert InvalidIpId();
        if (msg.sender != ag) revert NotAuthorized();

        _saleRequested[agreementId] = true;

        uint256 saleId = _saleRequestsCount;
        _saleRequestsCount = saleId + 1;

        emit FranchiseSaleInitiated(agreementId, saleId, uint64(block.timestamp));
    }

    function approve_franchise_sale(uint256 agreementId) external override onlyOwner {
        if (!_saleRequested[agreementId]) revert FranchiseAgreementNotListed();

        address ag = _agreements[agreementId];
        IIPFranchiseAgreement(ag).approve_franchise_sale();

        emit FranchiseSaleApproved(agreementId, ag, uint64(block.timestamp));
    }

    function reject_franchise_sale(uint256 agreementId) external override onlyOwner {
        if (!_saleRequested[agreementId]) revert FranchiseAgreementNotListed();

        address ag = _agreements[agreementId];
        IIPFranchiseAgreement(ag).reject_franchise_sale();

        emit FranchiseSaleRejected(agreementId, ag, uint64(block.timestamp));
    }

    function revoke_franchise_license(uint256 agreementId) external override onlyOwner {
        address ag = _agreements[agreementId];
        IIPFranchiseAgreement(ag).revoke_franchise_license();
        emit FranchiseAgreementRevoked(agreementId, ag, uint64(block.timestamp));
    }

    function reinstate_franchise_license(uint256 agreementId) external override onlyOwner {
        address ag = _agreements[agreementId];
        IIPFranchiseAgreement(ag).reinstate_franchise_license();
        emit FranchiseAgreementReinstated(agreementId, ag, uint64(block.timestamp));
    }

    // ─────────── Views ───────────

    function get_ip_nft_id() external view override returns (uint256) { return _ipNftId; }
    function get_ip_nft_address() external view override returns (address) { return _ipNft; }
    function is_ip_asset_linked() external view override returns (bool) { return _ipLinked; }

    function get_territory_info(uint256 territoryId) external view override returns (Territory memory) {
        return _territories[territoryId];
    }

    function get_total_territories() external view override returns (uint256) { return _territoriesCount; }

    function get_franchise_agreement_address(uint256 agreementId) external view override returns (address) {
        return _agreements[agreementId];
    }

    function get_franchise_agreement_id(address agreement) external view override returns (uint256) {
        return _agreementIds[agreement];
    }

    function get_total_franchise_agreements() external view override returns (uint256) {
        return _agreementsCount;
    }

    function get_franchisee_agreement(address franchisee, uint256 index) external view override returns (uint256) {
        return _franchiseeAgreements[franchisee][index];
    }

    function get_franchisee_agreement_count(address franchisee) external view override returns (uint256) {
        return _franchiseeAgreementCount[franchisee];
    }

    function get_franchise_application(uint256 applicationId, uint8 version) external view override returns (FranchiseApplication memory) {
        return _applications[applicationId][version];
    }

    function get_franchise_application_version(uint256 applicationId) external view override returns (uint8) {
        return _applicationVersion[applicationId];
    }

    function get_total_franchise_applications() external view override returns (uint256) {
        return _applicationsCount;
    }

    function get_franchisee_application(address franchisee, uint256 index) external view override returns (uint256) {
        return _franchiseeApplications[franchisee][index];
    }

    function get_franchisee_application_count(address franchisee) external view override returns (uint256) {
        return _franchiseeApplicationCount[franchisee];
    }

    function get_preferred_payment_model() external view override returns (FranchiseTerms memory) {
        return _preferredModel;
    }

    function get_default_franchise_fee() external view override returns (uint256) {
        return _defaultFranchiseFee;
    }

    function is_franchise_sale_requested(uint256 agreementId) external view override returns (bool) {
        return _saleRequested[agreementId];
    }

    function get_total_franchise_sale_requests() external view override returns (uint256) {
        return _saleRequestsCount;
    }

    // ─────────── Upgrade placeholder (parité d’API) ───────────
    function upgrade(address newImpl) external override onlyOwner {
        upgradedTo = newImpl; // indicatif (aucun proxy ici)
    }

    // ─────────── Internals ───────────
    function _create_franchise_agreement(address franchisee, FranchiseTerms memory t) internal {
        // Vérif territoire
        Territory memory terr = _territories[t.territoryId];
        if (!terr.active) revert TerritoryNotActive();
        if (terr.hasExclusiveAgreement) revert TerritoryAlreadyLinked();

        uint256 id = _agreementsCount;

        // déploiement "direct" d'un accord (pas de class hash sur EVM)
        IPFranchisingAgreement agreement = new IPFranchisingAgreement(
            id,
            address(this),
            franchisee,
            t
        );

        address agreementAddr = address(agreement);

        _agreements[id] = agreementAddr;
        _agreementIds[agreementAddr] = id;
        _agreementsCount = id + 1;

        // associer à franchisee
        uint256 idx = _franchiseeAgreementCount[franchisee];
        _franchiseeAgreements[franchisee][idx] = id;
        _franchiseeAgreementCount[franchisee] = idx + 1;

        // exclusivité
        if (t.exclusivity == ExclusivityType.Exclusive) {
            terr.hasExclusiveAgreement = true;
            terr.exclusiveAgreementId = id;
            _territories[t.territoryId] = terr;
        }

        emit FranchiseAgreementCreated(id, agreementAddr, franchisee, uint64(block.timestamp));
    }
}
