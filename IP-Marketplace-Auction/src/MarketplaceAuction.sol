// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ------------------------------------------------------------ */
/*                           OpenZeppelin                       */
/* ------------------------------------------------------------ */
import {ERC20}  from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20}  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ------------------------------------------------------------ */
/*                           MyToken (ERC20)                    */
/*  - Mint initial: 100_000_000 * 1e18 à `recipient`            */
/* ------------------------------------------------------------ */
contract MyToken is ERC20 {
    constructor(address recipient) ERC20("My Token", "MYT") {
        uint256 initialSupply = 100_000_000 * 10 ** decimals();
        _mint(recipient, initialSupply);
    }
}

/* ------------------------------------------------------------ */
/*                           MyNFT (ERC721)                     */
/*  - onlyOwner mint() -> retourne tokenId                      */
/* ------------------------------------------------------------ */
interface IMyNFT {
    function mint(address recipient) external returns (uint256);
}

contract MyNFT is ERC721, Ownable {
    uint256 private _tokenCount;
    string  private _base;

    constructor(address owner_) ERC721("MY NFT", "MNFT") Ownable(owner_) {
        _base = "uri/";
    }

    function mint(address recipient) external onlyOwner returns (uint256) {
        _tokenCount += 1;
        uint256 tokenId = _tokenCount;
        require(!_exists(tokenId), "NFT with id already exists");
        _safeMint(recipient, tokenId);
        return tokenId;
    }

    function _baseURI() internal view override returns (string memory) {
        return _base;
    }
}

/* ------------------------------------------------------------ */
/*                       Utils / Const & Errors                 */
/* ------------------------------------------------------------ */
uint64 constant DAY_IN_SECONDS = 24 * 60 * 60;

library Errors {
    string constant START_PRIZE_IS_ZERO            = "Start price is zero";
    string constant CALLER_NOT_OWNER               = "Caller is not owner";
    string constant CURRENCY_ADDRESS_ZERO          = "Currency address is zero";
    string constant INVALID_AUCTION                = "Invalid auction";
    string constant BIDDER_IS_OWNER                = "Bidder is owner";
    string constant AUCTION_CLOSED                 = "Auction closed";
    string constant AMOUNT_LESS_THAN_START_PRICE   = "Amount less than start price";
    string constant SALT_IS_ZERO                   = "Salt is zero";
    string constant INSUFFICIENT_FUNDS             = "Insufficient funds";
    string constant AUCTION_STILL_OPEN             = "Auction is still open";
    string constant NO_BID_FOUND                   = "No bid found";
    string constant WRONG_AMOUNT_OR_SALT           = "Wrong amount or salt";
    string constant REVEAL_TIME_NOT_OVER           = "Reveal time not over";
    string constant AUCTION_IS_FINALIZED           = "Auction already finalized";
    string constant BID_REFUNDED                   = "Bid refunded";
    string constant AMOUNT_EXCEEDS_BALANCE         = "Amount exceeds balance";
    string constant CALLER_ALREADY_WON_AUCTION     = "Caller already won auction";
}

/* ------------------------------------------------------------ */
/*                       Commit-hash helper                     */
/*  (Poseidon -> keccak256 pour EVM)                            */
/* ------------------------------------------------------------ */
function computeBidHash(uint256 amount, bytes32 salt) pure returns (bytes32) {
    return keccak256(abi.encode(amount, salt));
}

/* ------------------------------------------------------------ */
/*                            Marketplace                       */
/*  - Enchères commit/reveal pour ERC721 payées en ERC20        */
/* ------------------------------------------------------------ */
interface IMarketPlace {
    struct Auction {
        address owner;           // vendeur
        address token_address;   // ERC721
        uint256 token_id;
        uint256 start_price;
        uint256 highest_bid;
        address highest_bidder;
        uint64  end_time;
        bool    is_open;
        bool    is_finalized;
        address currency_address; // ERC20
    }

    function create_auction(
        address token_address,
        uint256 token_id,
        uint256 start_price,
        address currency_address
    ) external returns (uint64);

    function get_auction(uint64 auction_id) external view returns (Auction memory);

    function commit_bid(uint64 auction_id, uint256 amount, bytes32 salt) external;

    function get_auction_bid_count(uint64 auction_id) external view returns (uint64);

    function reveal_bid(uint64 auction_id, uint256 amount, bytes32 salt) external;

    function finalize_auction(uint64 auction_id) external;

    function withdraw_unrevealed_bid(uint64 auction_id, uint256 amount, bytes32 salt) external;
}

contract MarketPlace is IMarketPlace {
    /* ------------------------------- storage ------------------------------ */
    mapping(uint64 => Auction) private _auctions;                                   // auction_id => Auction
    uint64 private _auctionCount;

    mapping(uint64 => mapping(address => bytes32)) private _committedHash;          // (auction, bidder) => hash
    mapping(uint64 => uint64) private _bidsCount;                                   // auction_id => nb commits

    struct RevealedBid { uint256 amount; address bidder; }
    mapping(uint64 => RevealedBid[]) private _revealed;                             // auction_id => revealed bids

    mapping(address => uint256) private _balances;                                  // escrow ERC20 de chaque bidder
    mapping(uint64 => mapping(address => bool)) private _refunded;                  // (auction, bidder) => refunded ?

    uint64 public immutable auction_duration_days;
    uint64 public immutable reveal_duration_days;

    /* -------------------------------- events ------------------------------ */
    event AuctionCreated(address indexed owner, address indexed token_address, uint256 indexed token_id, uint256 start_price, address currency_address);
    event BidCommitted(address indexed bidder, uint64 indexed auction_id);
    event BidRevealed(address indexed bidder, uint64 indexed auction_id, uint256 amount);
    event AuctionFinalized(uint64 indexed auction_id, address indexed highest_bidder);

    /* ------------------------------ constructor --------------------------- */
    constructor(uint64 auction_durationDays, uint64 reveal_durationDays) {
        auction_duration_days = auction_durationDays;
        reveal_duration_days  = reveal_durationDays;
    }

    /* --------------------------------- API -------------------------------- */
    function create_auction(
        address token_address,
        uint256 token_id,
        uint256 start_price,
        address currency_address
    ) external override returns (uint64) {
        require(start_price != 0, Errors.START_PRIZE_IS_ZERO);
        require(IERC721(token_address).ownerOf(token_id) == msg.sender, Errors.CALLER_NOT_OWNER);
        require(currency_address != address(0), Errors.CURRENCY_ADDRESS_ZERO);

        uint64 auction_id = ++_auctionCount;

        uint64 endTime = uint64(block.timestamp) + auction_duration_days * DAY_IN_SECONDS;

        _auctions[auction_id] = Auction({
            owner: msg.sender,
            token_address: token_address,
            token_id: token_id,
            start_price: start_price,
            highest_bid: 0,
            highest_bidder: address(0),
            end_time: endTime,
            is_open: true,
            is_finalized: false,
            currency_address: currency_address
        });

        // Le vendeur doit approuver le marketplace avant.
        IERC721(token_address).transferFrom(msg.sender, address(this), token_id);

        emit AuctionCreated(msg.sender, token_address, token_id, start_price, currency_address);
        return auction_id;
    }

    function get_auction(uint64 auction_id) external view override returns (Auction memory) {
        return _auctions[auction_id];
    }

    function commit_bid(uint64 auction_id, uint256 amount, bytes32 salt) external override {
        _check_auction_status(auction_id);
        Auction memory a = _auctions[auction_id];

        require(a.owner != address(0), Errors.INVALID_AUCTION);
        require(a.owner != msg.sender, Errors.BIDDER_IS_OWNER);
        require(a.is_open, Errors.AUCTION_CLOSED);
        require(amount >= a.start_price, Errors.AMOUNT_LESS_THAN_START_PRICE);
        require(salt != bytes32(0), Errors.SALT_IS_ZERO);
        require(IERC20(a.currency_address).balanceOf(msg.sender) >= amount, Errors.INSUFFICIENT_FUNDS);

        bytes32 h = computeBidHash(amount, salt);
        _committedHash[auction_id][msg.sender] = h;
        _bidsCount[auction_id] += 1;

        // escrow ERC20
        require(IERC20(a.currency_address).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        _balances[msg.sender] += amount;

        emit BidCommitted(msg.sender, auction_id);
    }

    function get_auction_bid_count(uint64 auction_id) external view override returns (uint64) {
        return _bidsCount[auction_id];
    }

    function reveal_bid(uint64 auction_id, uint256 amount, bytes32 salt) public override {
        _check_auction_status(auction_id);
        Auction memory a = _auctions[auction_id];

        // La phase reveal commence après la fin (is_open == false)
        require(!a.is_open, Errors.AUCTION_STILL_OPEN);

        bytes32 committed = _committedHash[auction_id][msg.sender];
        require(committed != bytes32(0), Errors.NO_BID_FOUND);

        bytes32 calc = computeBidHash(amount, salt);
        require(calc == committed, Errors.WRONG_AMOUNT_OR_SALT);

        // on accepte les reveals jusqu'à la fin de la période de révélation
        require(!_is_reveal_duration_over(auction_id), Errors.REVEAL_TIME_NOT_OVER);

        _revealed[auction_id].push(RevealedBid({amount: amount, bidder: msg.sender}));
        emit BidRevealed(msg.sender, auction_id, amount);
    }

    function finalize_auction(uint64 auction_id) external override {
        _check_auction_status(auction_id);
        Auction storage a = _auctions[auction_id];

        require(!a.is_open, Errors.AUCTION_STILL_OPEN);
        require(_is_reveal_duration_over(auction_id), Errors.REVEAL_TIME_NOT_OVER);
        require(!a.is_finalized, Errors.AUCTION_IS_FINALIZED);

        (uint256 highestBid, address highestBidder) = _get_highest_bidder(auction_id);

        // rembourser tous les perdants
        _refund_committed_funds(auction_id, highestBidder, a.currency_address);

        // transférer le NFT au gagnant
        IERC721(a.token_address).transferFrom(address(this), highestBidder, a.token_id);

        // payer le vendeur avec l'escrow du gagnant
        require(_balances[highestBidder] >= highestBid, "escrow < highest");
        _balances[highestBidder] -= highestBid;
        require(IERC20(a.currency_address).transfer(a.owner, highestBid), "pay seller failed");

        // maj état
        a.highest_bid    = highestBid;
        a.highest_bidder = highestBidder;
        a.is_finalized   = true;

        emit AuctionFinalized(auction_id, highestBidder);
    }

    function withdraw_unrevealed_bid(uint64 auction_id, uint256 amount, bytes32 salt) external override {
        Auction memory a = _auctions[auction_id];
        require(msg.sender != a.highest_bidder, Errors.CALLER_ALREADY_WON_AUCTION);
        require(!_refunded[auction_id][msg.sender], Errors.BID_REFUNDED);

        // révèle (échouera si mauvais couple amount/salt)
        reveal_bid(auction_id, amount, salt);

        // retirer depuis l'escrow
        uint256 bal = _balances[msg.sender];
        require(amount <= bal, Errors.AMOUNT_EXCEEDS_BALANCE);

        _balances[msg.sender] = bal - amount;
        _refunded[auction_id][msg.sender] = true;
        require(IERC20(a.currency_address).transfer(msg.sender, amount), "refund failed");
    }

    /* ------------------------------ internes ------------------------------ */
    function _is_owner(address token, uint256 tokenId, address who) private view returns (bool) {
        return IERC721(token).ownerOf(tokenId) == who;
    }

    function _get_highest_bidder(uint64 auction_id) private view returns (uint256, address) {
        RevealedBid[] storage bids = _revealed[auction_id];
        uint256 best = 0;
        address bestBidder = address(0);
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].amount > best) {
                best = bids[i].amount;
                bestBidder = bids[i].bidder;
            }
        }
        return (best, bestBidder);
    }

    function _refund_committed_funds(uint64 auction_id, address winner, address currency) private {
        RevealedBid[] storage bids = _revealed[auction_id];
        for (uint256 i = 0; i < bids.length; i++) {
            address bidder = bids[i].bidder;
            uint256 amount = bids[i].amount;
            if (bidder != winner && !_refunded[auction_id][bidder]) {
                // décrémente l'escrow puis rembourse
                require(_balances[bidder] >= amount, "escrow underflow");
                _balances[bidder] -= amount;
                _refunded[auction_id][bidder] = true;
                require(IERC20(currency).transfer(bidder, amount), "refund failed");
            }
        }
    }

    function _check_auction_status(uint64 auction_id) private {
        Auction storage a = _auctions[auction_id];
        if (a.is_open && block.timestamp >= a.end_time) {
            a.is_open = false;
        }
    }

    function _is_reveal_duration_over(uint64 auction_id) private view returns (bool) {
        Auction memory a = _auctions[auction_id];
        uint64 revealEnd = a.end_time + reveal_duration_days * DAY_IN_SECONDS;
        return uint64(block.timestamp) >= revealEnd;
    }
}
