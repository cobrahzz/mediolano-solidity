// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ============================================================
   =============== Types / Enums / Structs ====================
   ============================================================ */

enum ClubStatus {
    Inactive,
    Open,
    Closed
}

struct ClubRecord {
    uint256 id;
    string  name;
    string  symbol;
    string  metadataURI;
    ClubStatus status;
    uint32  numMembers;
    address creator;
    address clubNFT;
    uint32  maxMembers;     // 0 => pas de limite
    uint256 entryFee;       // 0 => pas de frais
    address paymentToken;   // address(0) si pas de frais
}

/* ============================================================
   ======================= Interfaces =========================
   ============================================================ */

interface IIPClub {
    function create_club(
        string calldata name,
        string calldata symbol,
        string calldata metadata_uri,
        uint32 max_members,         // 0 => none
        uint256 entry_fee,          // 0 => none
        address payment_token       // zero address si none
    ) external;

    function close_club(uint256 club_id) external;

    function join_club(uint256 club_id) external;

    function get_club_record(uint256 club_id) external view returns (ClubRecord memory);

    function is_member(uint256 club_id, address user) external view returns (bool);

    function get_last_club_id() external view returns (uint256);
}

interface IIPClubNFT {
    function mint(address recipient) external;
    function has_nft(address user) external view returns (bool);
    function get_nft_creator() external view returns (address);
    function get_ip_club_manager() external view returns (address);
    function get_associated_club_id() external view returns (uint256);
    function get_last_minted_id() external view returns (uint256);
}

interface IERC20Mint {
    function mint(address recipient, uint256 amount) external;
}

/* ============================================================
   ======================= Mock ERC20 =========================
   ============================================================ */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20, IERC20Mint {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    function mint(address recipient, uint256 amount) external override {
        _mint(recipient, amount);
    }
}

/* ============================================================
   ====================== Events (Cairo) ======================
   ============================================================ */

event NewClubCreated(uint256 club_id, address creator, string metadata_uri, uint64 timestamp);
event ClubClosed(uint256 club_id, address creator, uint64 timestamp);
event NewMember(uint256 club_id, address member, uint64 timestamp);
event NftMinted(uint256 club_id, uint256 token_id, address recipient, uint64 timestamp);

/* ============================================================
   ======================= IPClubNFT ==========================
   ============================================================ */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract IPClubNFT is ERC721, AccessControl, IIPClubNFT {
    bytes32 public constant DEFAULT_ADMIN_ROLE_ALIAS = DEFAULT_ADMIN_ROLE;

    address private _creator;
    uint256 private _clubId;
    address private _ipClubManager;
    uint256 private _lastTokenId;
    string  private _base;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 club_id_,
        address creator_,
        address ip_club_manager_,
        string memory metadata_uri_
    ) ERC721(name_, symbol_) {
        _creator = creator_;
        _ipClubManager = ip_club_manager_;
        _clubId = club_id_;
        _base = metadata_uri_;
        _grantRole(DEFAULT_ADMIN_ROLE, ip_club_manager_);
    }

    function mint(address recipient) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!has_nft(recipient), "Already has nft");
        uint256 nextId = ++_lastTokenId;
        _safeMint(recipient, nextId);
        emit NftMinted(_clubId, nextId, recipient, uint64(block.timestamp));
    }

    function has_nft(address user) public view override returns (bool) {
        return balanceOf(user) > 0;
    }

    function get_nft_creator() external view override returns (address) { return _creator; }
    function get_ip_club_manager() external view override returns (address) { return _ipClubManager; }
    function get_associated_club_id() external view override returns (uint256) { return _clubId; }
    function get_last_minted_id() external view override returns (uint256) { return _lastTokenId; }

    function _baseURI() internal view override returns (string memory) { return _base; }

    // ERC165 diamond override
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/* ============================================================
   ======================== IPClub ============================
   ============================================================ */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IPClub is IIPClub {
    uint256 private _lastClubId;
    mapping(uint256 => ClubRecord) private _clubs;

    function create_club(
        string calldata name_,
        string calldata symbol_,
        string calldata metadata_uri_,
        uint32 max_members_,       // 0 => no cap
        uint256 entry_fee_,        // 0 => no fee
        address payment_token_     // address(0) if no fee
    ) external override {
        // ---- Options / validation ----
        // 0 => illimité : pas de revert ici

        bool feeSet = entry_fee_ > 0;
        bool tokenSet = payment_token_ != address(0);

        // Ordonner les erreurs pour matcher exactement les messages attendus par les tests
        if (!feeSet && tokenSet) {
            revert("Entry fee cannot be zero");
        }
        if (feeSet && !tokenSet) {
            revert("Payment token cannot be null");
        }
        // (les deux autres cas sont valides : (false,false) ou (true,true))

        uint256 nextId = ++_lastClubId;

        IPClubNFT clubNft = new IPClubNFT(
            name_, symbol_, nextId, msg.sender, address(this), metadata_uri_
        );

        ClubRecord memory rec = ClubRecord({
            id: nextId,
            name: name_,
            symbol: symbol_,
            metadataURI: metadata_uri_,
            status: ClubStatus.Open,
            numMembers: 0,
            creator: msg.sender,
            clubNFT: address(clubNft),
            maxMembers: max_members_,
            entryFee: entry_fee_,
            paymentToken: payment_token_
        });

        _clubs[nextId] = rec;
        emit NewClubCreated(nextId, msg.sender, metadata_uri_, uint64(block.timestamp));
    }

    function close_club(uint256 club_id) external override {
        ClubRecord storage rec = _clubs[club_id];
        require(rec.id != 0, "Club not found");
        require(rec.status == ClubStatus.Open, "Club not open");
        require(rec.creator == msg.sender, "Not Authorized");
        rec.status = ClubStatus.Closed;
        emit ClubClosed(club_id, msg.sender, uint64(block.timestamp));
    }

    function join_club(uint256 club_id) external override {
        ClubRecord storage rec = _clubs[club_id];
        require(rec.id != 0, "Club not found");
        require(rec.status == ClubStatus.Open, "Club not open");

        if (rec.maxMembers > 0) {
            require(rec.numMembers < rec.maxMembers, "Club full");
        }

        if (rec.entryFee > 0) {
            bool ok = IERC20(rec.paymentToken).transferFrom(
                msg.sender, rec.creator, rec.entryFee
            );
            require(ok, "Token Transfer Failed");
        }

        IIPClubNFT(rec.clubNFT).mint(msg.sender);
        unchecked { rec.numMembers += 1; }
        emit NewMember(club_id, msg.sender, uint64(block.timestamp));
    }

    function get_club_record(uint256 club_id) external view override returns (ClubRecord memory) {
        ClubRecord memory rec = _clubs[club_id];
        require(rec.id != 0, "Club not found");
        return rec;
    }

    function is_member(uint256 club_id, address user) external view override returns (bool) {
        ClubRecord memory rec = _clubs[club_id];
        require(rec.id != 0, "Club not found");
        return IIPClubNFT(rec.clubNFT).has_nft(user);
    }

    function get_last_club_id() external view override returns (uint256) {
        return _lastClubId;
    }
}
