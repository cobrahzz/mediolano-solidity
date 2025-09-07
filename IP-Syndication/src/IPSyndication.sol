// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ──────────────────────────── OZ imports ──────────────────────────── */
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/* ───────────────────────── IAssetNFT interface ─────────────────────── */
interface IAssetNFT {
    function mint(address recipient, uint256 token_id, uint256 amount) external;
}

/* ───────────────────────────── AssetNFT ────────────────────────────── */
/**
 * ERC1155 simple : URI global, mint libre (conforme à la version Cairo fournie).
 */
contract AssetNFT is ERC1155, IAssetNFT {
    constructor(string memory token_uri) ERC1155(token_uri) {}

    function mint(address recipient, uint256 token_id, uint256 amount) external override {
        // Cairo: commentaire "restrict to syndicate contract" mais pas d'enforcement.
        _mint(recipient, token_id, amount, "");
    }
}

/* ───────────────────────────── Types ──────────────────────────────── */
enum Status { Pending, Active, Completed, Cancelled }
enum Mode   { Public,  Whitelist }

/**
 * IP metadata
 * - name/description/uri: chaînes (Cairo ByteArray/ felt252)
 * - licensing_terms: uint256 (Cairo felt252)
 */
struct IPMetadata {
    uint256 ip_id;
    address owner;
    uint256 price;
    string  name;
    string  description;
    string  uri;
    uint256 licensing_terms;
    uint256 token_id;
}

struct SyndicationDetails {
    uint256 ip_id;
    Status  status;
    Mode    mode;
    uint256 total_raised;
    uint256 participant_count;
    address currency_address;
}

struct ParticipantDetails {
    address participant;
    uint256 amount_deposited;
    bool    minted;
    uint256 token_id;
    uint256 amount_refunded;
    uint256 share;
}

/* ───────────────────────── IIPSyndication (facultative) ───────────── */
interface IIPSyndication {
    function register_ip(
        uint256 price,
        string calldata name,
        string calldata description,
        string calldata uri,
        uint256 licensing_terms,
        Mode mode,
        address currency_address
    ) external returns (uint256);

    function update_whitelist(uint256 ip_id, address addr, bool status_) external;
    function deposit(uint256 ip_id, uint256 amount) external;
    function mint_asset(uint256 ip_id) external;
    function is_whitelisted(uint256 ip_id, address addr) external view returns (bool);
    function cancel_syndication(uint256 ip_id) external;
    function activate_syndication(uint256 ip_id) external;

    function get_ip_metadata(uint256 ip_id) external view returns (IPMetadata memory);
    function get_all_participants(uint256 ip_id) external view returns (address[] memory);
    function get_syndication_details(uint256 ip_id) external view returns (SyndicationDetails memory);
    function get_participant_details(uint256 ip_id, address participant) external view returns (ParticipantDetails memory);
    function get_syndication_status(uint256 ip_id) external view returns (Status);
    function get_participant_count(uint256 ip_id) external view returns (uint256);
}

/* ───────────────────────────── IPSyndication ───────────────────────── */
/**
 * Port fidèle de la logique Cairo : enregistrements IP, whitelist, dépôts ERC20,
 * finalisation, mint ERC1155, annulation + refunds, vues utilitaires.
 */
contract IPSyndication is IIPSyndication {
    /* ──────────────── erreurs (messages identiques au Cairo) ─────────────── */
    string private constant ERR_PRICE_ZERO              = "Price can not be zero";
    string private constant ERR_SYN_NON_ACTIVE          = "Syndication not active";
    string private constant ERR_SYN_ACTIVE              = "Syndication is active";
    string private constant ERR_ADDR_NOT_WL             = "Address not whitelisted";
    string private constant ERR_AMOUNT_ZERO             = "Amount can not be zero";
    string private constant ERR_CURR_ADDR_INVALID       = "Invalid currency address";
    string private constant ERR_FUND_COMPLETED          = "Fundraising already completed";
    string private constant ERR_NOT_WL_MODE             = "Not in whitelist mode";
    string private constant ERR_NOT_IP_OWNER            = "Not IP owner";
    string private constant ERR_COMPLETED_OR_CANCELLED  = "Syn: completed or cancelled";
    string private constant ERR_SYN_NOT_COMPLETED       = "Syndication not completed";
    string private constant ERR_NON_PARTICIPANT         = "Not Syndication Participant";
    string private constant ERR_ALREADY_MINTED          = "Already minted";
    string private constant ERR_INSUFF_BAL              = "Insufficient balance";
    string private constant ERR_ALREADY_REFUNDED        = "Already refunded";

    /* ─────────────────────────── storage ─────────────────────────── */
    mapping(uint256 => IPMetadata)          private ip_metadata;           // ip_id => meta
    uint256                                 private ip_count;
    mapping(uint256 => SyndicationDetails)  private syndication_details;   // ip_id => details

    mapping(uint256 => mapping(address => bool)) private ip_whitelist;     // ip_id => addr => wl?
    mapping(uint256 => address[])                 private participant_addrs;// ip_id => participants
    mapping(uint256 => mapping(address => ParticipantDetails)) private participants; // ip_id => addr => details

    address public immutable asset_nft_address;

    /* ─────────────────────────── events ─────────────────────────── */
    event IPRegistered(
        address owner,
        uint256 price,
        string  name,
        Mode    mode,
        uint256 token_id,
        address currency_address
    );
    event ParticipantAdded(uint256 indexed ip_id, address indexed participant);
    event DepositReceived(address indexed from, uint256 amount, uint256 total);
    event SyndicationCompleted(uint256 total_raised, uint32 participant_count, uint64 timestamp);
    event WhitelistUpdated(address indexed addr, bool status);
    event SyndicationCancelled(uint64 timestamp);
    event AssetMinted(address indexed recipient, uint256 share);

    /* ───────────────────────── constructor ──────────────────────── */
    constructor(address _asset_nft_address) {
        asset_nft_address = _asset_nft_address;
    }

    /* ─────────────────────────── external API ───────────────────── */

    function register_ip(
        uint256 price,
        string calldata name,
        string calldata description,
        string calldata uri,
        uint256 licensing_terms,
        Mode    mode,
        address currency_address
    ) external override returns (uint256) {
        require(price != 0, ERR_PRICE_ZERO);
        require(currency_address != address(0), ERR_CURR_ADDR_INVALID);

        uint256 ip_id = ip_count + 1;

        ip_metadata[ip_id] = IPMetadata({
            ip_id: ip_id,
            owner: msg.sender,
            price: price,
            name: name,
            description: description,
            uri: uri,
            licensing_terms: licensing_terms,
            token_id: ip_id
        });

        syndication_details[ip_id] = SyndicationDetails({
            ip_id: ip_id,
            status: Status.Pending,
            mode: mode,
            total_raised: 0,
            participant_count: get_participant_count(ip_id),
            currency_address: currency_address
        });

        ip_count = ip_id;

        emit IPRegistered(msg.sender, price, name, mode, ip_id, currency_address);
        return ip_id;
    }

    function activate_syndication(uint256 ip_id) external override {
        IPMetadata memory meta = ip_metadata[ip_id];
        require(meta.owner == msg.sender, ERR_NOT_IP_OWNER);

        SyndicationDetails memory det = syndication_details[ip_id];
        require(det.status == Status.Pending, ERR_SYN_ACTIVE);

        det.status = Status.Active;
        syndication_details[ip_id] = det;
    }

    function deposit(uint256 ip_id, uint256 amount) external override {
        SyndicationDetails memory det = syndication_details[ip_id];
        require(det.status == Status.Active, ERR_SYN_NON_ACTIVE);
        require(amount != 0, ERR_AMOUNT_ZERO);

        // balance check
        require(IERC20(det.currency_address).balanceOf(msg.sender) >= amount, ERR_INSUFF_BAL);

        // whitelist check
        if (det.mode == Mode.Whitelist) {
            require(ip_whitelist[ip_id][msg.sender], ERR_ADDR_NOT_WL);
        }

        uint256 total = det.total_raised;
        uint256 price = ip_metadata[ip_id].price;
        require(total < price, ERR_FUND_COMPLETED);

        uint256 remaining = price - total;
        uint256 depositAmount = amount > remaining ? remaining : amount;

        ParticipantDetails memory p = participants[ip_id][msg.sender];
        if (p.amount_deposited == 0 && p.participant == address(0)) {
            // first time participant
            p.participant = msg.sender;
            p.token_id    = ip_id;
            participant_addrs[ip_id].push(msg.sender);
            emit ParticipantAdded(ip_id, msg.sender);
        }

        p.amount_deposited += depositAmount;

        det.total_raised = total + depositAmount;
        det.participant_count = participant_addrs[ip_id].length;

        emit DepositReceived(msg.sender, depositAmount, det.total_raised);

        if (det.total_raised >= price) {
            det.status = Status.Completed;
            emit SyndicationCompleted(det.total_raised, uint32(det.participant_count), uint64(block.timestamp));
        }

        // persist
        syndication_details[ip_id] = det;
        participants[ip_id][msg.sender] = p;

        // pull funds
        IERC20(det.currency_address).transferFrom(msg.sender, address(this), depositAmount);
    }

    function get_participant_count(uint256 ip_id) public view override returns (uint256) {
        return participant_addrs[ip_id].length;
    }

    function get_all_participants(uint256 ip_id) external view override returns (address[] memory) {
        return participant_addrs[ip_id];
    }

    function update_whitelist(uint256 ip_id, address addr, bool status_) external override {
        IPMetadata memory meta = ip_metadata[ip_id];
        SyndicationDetails memory det = syndication_details[ip_id];

        require(meta.owner == msg.sender, ERR_NOT_IP_OWNER);
        require(det.status == Status.Active, ERR_SYN_NON_ACTIVE);
        require(det.mode == Mode.Whitelist, ERR_NOT_WL_MODE);

        ip_whitelist[ip_id][addr] = status_;
        emit WhitelistUpdated(addr, status_);
    }

    function is_whitelisted(uint256 ip_id, address addr) external view override returns (bool) {
        return ip_whitelist[ip_id][addr];
    }

    function cancel_syndication(uint256 ip_id) external override {
        require(ip_metadata[ip_id].owner == msg.sender, ERR_NOT_IP_OWNER);

        SyndicationDetails memory det = syndication_details[ip_id];
        require(
            det.status == Status.Active || det.status == Status.Pending,
            ERR_COMPLETED_OR_CANCELLED
        );

        det.status = Status.Cancelled;
        syndication_details[ip_id] = det;

        emit SyndicationCancelled(uint64(block.timestamp));
        _refund(ip_id);
    }

    function get_ip_metadata(uint256 ip_id) external view override returns (IPMetadata memory) {
        return ip_metadata[ip_id];
    }

    function get_syndication_details(uint256 ip_id) external view override returns (SyndicationDetails memory) {
        return syndication_details[ip_id];
    }

    function get_syndication_status(uint256 ip_id) external view override returns (Status) {
        return syndication_details[ip_id].status;
    }

    function get_participant_details(uint256 ip_id, address participant)
        external
        view
        override
        returns (ParticipantDetails memory)
    {
        return participants[ip_id][participant];
    }

    function mint_asset(uint256 ip_id) external override {
        SyndicationDetails memory det = syndication_details[ip_id];
        require(det.status == Status.Completed, ERR_SYN_NOT_COMPLETED);

        require(_is_participant(ip_id, msg.sender), ERR_NON_PARTICIPANT);

        ParticipantDetails memory p = participants[ip_id][msg.sender];
        require(!p.minted, ERR_ALREADY_MINTED);

        uint256 share = p.amount_deposited - p.amount_refunded;

        p.minted = true;
        p.share  = share;
        participants[ip_id][msg.sender] = p;

        emit AssetMinted(msg.sender, share);

        IAssetNFT(asset_nft_address).mint(msg.sender, ip_id, share);
    }

    /* ─────────────────────────── internal utils ───────────────────── */

    function _is_participant(uint256 ip_id, address who) internal view returns (bool) {
        address[] storage arr = participant_addrs[ip_id];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == who) return true;
        }
        return false;
    }

    function _refund(uint256 ip_id) internal {
        SyndicationDetails memory det = syndication_details[ip_id];
        address token = det.currency_address;

        address[] storage arr = participant_addrs[ip_id];
        for (uint256 i = 0; i < arr.length; i++) {
            address user = arr[i];
            ParticipantDetails memory p = participants[ip_id][user];

            uint256 amount = p.amount_deposited - p.amount_refunded;
            require(amount > 0, ERR_ALREADY_REFUNDED);

            p.amount_refunded += amount;
            participants[ip_id][user] = p;

            IERC20(token).transfer(user, amount);
        }
    }
}

/* ─────────────────────────── MyToken (ERC20) ───────────────────────── */
contract MyToken is ERC20 {
    constructor(address recipient) ERC20("My Token", "MYT") {
        // Cairo: mint de 100_000_000_000 (pas de *10^18 dans le code source)
        _mint(recipient, 100_000_000_000);
    }
}

/* ────────────────────── MockERC1155Receiver ───────────────────────── */
contract MockERC1155Receiver is ERC1155Receiver {
    function onERC1155Received(
        address, address, uint256, uint256, bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, address, uint256[] calldata, uint256[] calldata, bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Receiver)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
