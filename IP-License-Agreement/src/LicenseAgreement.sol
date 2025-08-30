// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*───────────────────────────────────────────────────────────────────────────*
 |                           Interfaces (Cairo parity)                        |
 *───────────────────────────────────────────────────────────────────────────*/

interface IIPLicensingAgreement {
    // Actions
    function sign_agreement() external;
    function make_immutable() external;
    function add_metadata(bytes32 key, bytes32 value) external;

    // Metadata de base
    function get_metadata()
        external
        view
        returns (
            string memory title,
            string memory description,
            string memory ip_metadata,
            uint64  creation_timestamp,
            bool    is_immutable,
            uint64  immutability_timestamp
        );

    // Metadata additionnelle / signers / signatures
    function get_additional_metadata(bytes32 key) external view returns (bytes32);
    function is_signer(address account) external view returns (bool);
    function has_signed(address account) external view returns (bool);
    function get_signature_timestamp(address account) external view returns (uint64);
    function get_signers() external view returns (address[] memory);
    function get_signer_count() external view returns (uint256);
    function get_signature_count() external view returns (uint256);
    function is_fully_signed() external view returns (bool);

    // Divers
    function get_factory() external view returns (address);
    function get_owner() external view returns (address);
}

interface IIPLicensingFactory {
    // Actions
    function create_agreement(
        string calldata title,
        string calldata description,
        string calldata ip_metadata,
        address[] calldata signers
    ) external returns (uint256 agreement_id, address agreement_address);

    // Getters
    function get_agreement_address(uint256 agreement_id) external view returns (address);
    function get_agreement_id(address agreement_address) external view returns (uint256);
    function get_agreement_count() external view returns (uint256);
    function get_user_agreements(address user) external view returns (uint256[] memory);
    function get_user_agreement_count(address user) external view returns (uint256);

    // “Class hash” (info pour parité avec Cairo)
    function update_agreement_class_hash(bytes32 new_class_hash) external;
    function get_agreement_class_hash() external view returns (bytes32);
}

/*───────────────────────────────────────────────────────────────────────────*
 |                           Ownable minimal (no deps)                        |
 *───────────────────────────────────────────────────────────────────────────*/

contract OwnableLite {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "owner=0");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: not owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/*───────────────────────────────────────────────────────────────────────────*
 |                        IPLicensingAgreement (monolith)                     |
 *───────────────────────────────────────────────────────────────────────────*/

contract IPLicensingAgreement is OwnableLite, IIPLicensingAgreement {
    // Base
    address private _factory;

    string  private _title;
    string  private _description;
    string  private _ipMetadata;
    uint64  private _creationTimestamp;

    bool    private _isImmutable;
    uint64  private _immutabilityTimestamp;

    // Signers & signatures
    mapping(address => bool) private _isSigner;
    address[] private _signers;

    mapping(address => bool)  private _hasSigned;
    mapping(address => uint64) private _signatureTimestamps;
    uint256 private _signatureCount;

    // Additional metadata
    mapping(bytes32 => bytes32) private _additionalMetadata;

    // Events (parité Cairo)
    event AgreementSigned(address indexed signer, uint64 timestamp);
    event AgreementMadeImmutable(uint64 timestamp);
    event MetadataAdded(bytes32 indexed key, bytes32 value);

    constructor(
        address creator,
        address factory,
        string memory title_,
        string memory description_,
        string memory ip_metadata_,
        address[] memory signers_
    ) OwnableLite(creator) {
        _factory = factory;

        _title = title_;
        _description = description_;
        _ipMetadata = ip_metadata_;
        _creationTimestamp = uint64(block.timestamp);

        _isImmutable = false;
        _immutabilityTimestamp = 0;
        _signatureCount = 0;

        // Uniques & non-zero
        for (uint256 i = 0; i < signers_.length; i++) {
            address s = signers_[i];
            if (s != address(0) && !_isSigner[s]) {
                _isSigner[s] = true;
                _signers.push(s);
            }
        }
    }

    // ── Actions ────────────────────────────────────────────────────────────

    function sign_agreement() external override {
        address caller = msg.sender;
        require(_isSigner[caller], "NOT_A_SIGNER");
        require(!_isImmutable, "AGREEMENT_IMMUTABLE");
        require(!_hasSigned[caller], "ALREADY_SIGNED");

        _hasSigned[caller] = true;
        uint64 ts = uint64(block.timestamp);
        _signatureTimestamps[caller] = ts;
        _signatureCount += 1;

        emit AgreementSigned(caller, ts);
    }

    function make_immutable() external override onlyOwner {
        require(!_isImmutable, "ALREADY_IMMUTABLE");
        // NB: La validation "fully signed" n'était pas appliquée dans la version Cairo.
        _isImmutable = true;
        _immutabilityTimestamp = uint64(block.timestamp);
        emit AgreementMadeImmutable(_immutabilityTimestamp);
    }

    function add_metadata(bytes32 key, bytes32 value) external override onlyOwner {
        require(!_isImmutable, "AGREEMENT_IMMUTABLE");
        require(key != bytes32(0), "EMPTY_KEY");
        require(value != bytes32(0), "EMPTY_VALUE");
        _additionalMetadata[key] = value;
        emit MetadataAdded(key, value);
    }

    // ── Views (base metadata) ──────────────────────────────────────────────

    function get_metadata()
        external
        view
        override
        returns (
            string memory title,
            string memory description,
            string memory ip_metadata,
            uint64  creation_timestamp,
            bool    is_immutable,
            uint64  immutability_timestamp
        )
    {
        return (
            _title,
            _description,
            _ipMetadata,
            _creationTimestamp,
            _isImmutable,
            _immutabilityTimestamp
        );
    }

    // ── Views (extra / signers / signatures) ───────────────────────────────

    function get_additional_metadata(bytes32 key) external view override returns (bytes32) {
        return _additionalMetadata[key];
    }

    function is_signer(address account) external view override returns (bool) {
        return _isSigner[account];
    }

    function has_signed(address account) external view override returns (bool) {
        return _hasSigned[account];
    }

    function get_signature_timestamp(address account) external view override returns (uint64) {
        require(_hasSigned[account], "NOT_SIGNED");
        return _signatureTimestamps[account];
    }

    function get_signers() external view override returns (address[] memory) {
        return _signers;
    }

    function get_signer_count() external view override returns (uint256) {
        return _signers.length;
    }

    function get_signature_count() external view override returns (uint256) {
        return _signatureCount;
    }

    function is_fully_signed() external view override returns (bool) {
        return _signatureCount == _signers.length;
    }

    function get_factory() external view override returns (address) {
        return _factory;
    }

    function get_owner() external view override returns (address) {
        return owner();
    }
}

/*───────────────────────────────────────────────────────────────────────────*
 |                          IPLicensingFactory (mono)                        |
 *───────────────────────────────────────────────────────────────────────────*/

contract IPLicensingFactory is OwnableLite, IIPLicensingFactory {
    bytes32 private _agreementClassHash; // info

    // ID <-> address
    mapping(uint256 => address) private _agreements;
    mapping(address => uint256) private _agreementIds;
    uint256 private _agreementCount;

    // user -> list of agreement IDs
    mapping(address => uint256[]) private _userAgreements;

    event AgreementCreated(
        uint256 indexed agreement_id,
        address indexed agreement_address,
        address indexed creator,
        string  title
    );

    constructor(address admin, bytes32 agreement_class_hash) OwnableLite(admin) {
        _agreementClassHash = agreement_class_hash;
    }

    function create_agreement(
        string calldata title,
        string calldata description,
        string calldata ip_metadata,
        address[] calldata signers
    ) external override returns (uint256 agreement_id, address agreement_address) {
        require(bytes(title).length > 0, "EMPTY_TITLE");
        require(bytes(description).length > 0, "EMPTY_DESCRIPTION");
        require(bytes(ip_metadata).length > 0, "EMPTY_METADATA");
        require(signers.length > 0, "NO_SIGNERS");

        address creator = msg.sender;

        // Deploy
        IPLicensingAgreement agreement = new IPLicensingAgreement(
            creator,
            address(this),
            title,
            description,
            ip_metadata,
            signers
        );

        _agreementCount += 1;
        agreement_id = _agreementCount;
        agreement_address = address(agreement);

        _agreements[agreement_id] = agreement_address;
        _agreementIds[agreement_address] = agreement_id;

        // Indexation user (creator + signers uniques)
        _userAgreements[creator].push(agreement_id);
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] != creator) {
                _userAgreements[signers[i]].push(agreement_id);
            }
        }

        emit AgreementCreated(agreement_id, agreement_address, creator, title);
    }

    function get_agreement_address(uint256 agreement_id) external view override returns (address) {
        address a = _agreements[agreement_id];
        require(a != address(0), "AGREEMENT_NOT_FOUND");
        return a;
    }

    function get_agreement_id(address agreement_address) external view override returns (uint256) {
        uint256 id = _agreementIds[agreement_address];
        require(id != 0, "AGREEMENT_NOT_FOUND");
        return id;
    }

    function get_agreement_count() external view override returns (uint256) {
        return _agreementCount;
    }

    function get_user_agreements(address user) external view override returns (uint256[] memory) {
        return _userAgreements[user];
    }

    function get_user_agreement_count(address user) external view override returns (uint256) {
        return _userAgreements[user].length;
    }

    function update_agreement_class_hash(bytes32 new_class_hash) external override onlyOwner {
        _agreementClassHash = new_class_hash;
    }

    function get_agreement_class_hash() external view override returns (bytes32) {
        return _agreementClassHash;
    }
}
