// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// ------------------------------------------------------------------------
/// MockERC20 (équivalent du contrat Cairo MockERC20)
/// ------------------------------------------------------------------------
contract MockERC20 is ERC20 {
    constructor(address recipient) ERC20("Mock Token", "MCT") {
        // Alimente le destinataire avec une grosse supply
        _mint(recipient, 100_000_000 ether);
    }
}

/// ------------------------------------------------------------------------
/// Interface IIPTicketService (équivalente à l’interface Cairo)
/// ------------------------------------------------------------------------
interface IIPTicketService {
    function create_ip_asset(
        uint256 price,
        uint256 max_supply,
        uint256 expiration,
        uint256 royalty_percentage, // en basis points (ex: 500 = 5%)
        string calldata metadata_uri
    ) external returns (uint256);

    function mint_ticket(uint256 ip_asset_id) external;

    function has_valid_ticket(address user, uint256 ip_asset_id) external view returns (bool);

    /// Conforme à ERC-2981
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

/// ------------------------------------------------------------------------
/// IPTicketService
/// - ERC721 avec baseURI
/// - Paiement en ERC20 via transferFrom vers le propriétaire de l’IP
/// - Royalties calculées à la volée (même signature qu’ERC-2981)
/// ------------------------------------------------------------------------
contract IPTicketService is ERC721, IERC2981, IIPTicketService {
    using Strings for uint256;

    struct IPAsset {
        address owner;
        uint256 price;
        uint256 max_supply;
        uint256 tickets_minted;
        uint256 expiration;          // timestamp (seconds)
        uint256 royalty_percentage;  // basis points (10000 = 100%)
        string metadata_uri;         // stocké comme dans le Cairo (felt/uri)
    }

    // Storage principal
    IERC20 public immutable paymentToken;
    string private _baseTokenURI;

    uint256 public next_ip_asset_id = 1;
    uint256 public next_token_id = 1;
    uint256 public total_supply;

    mapping(uint256 => IPAsset) public ip_assets;              // ipId => IPAsset
    mapping(uint256 => uint256) public token_to_ip_asset;      // tokenId => ipId
    mapping(address => mapping(uint256 => uint256)) public user_ip_asset_balance; // user => ipId => count

    /// --------------------------------------------------------------------
    /// Events (noms et champs alignés avec la version Cairo)
    /// --------------------------------------------------------------------
    event IPAssetCreated(
        uint256 ip_asset_id,
        address owner,
        uint256 price,
        uint256 max_supply,
        uint256 expiration,
        uint256 royalty_percentage,
        string metadata_uri
    );

    event TicketMinted(
        uint256 token_id,
        uint256 ip_asset_id,
        address owner
    );

    constructor(
        string memory name_,
        string memory symbol_,
        address payment_token_,
        string memory baseTokenURI_
    ) ERC721(name_, symbol_) {
        require(payment_token_ != address(0), "invalid payment token");
        paymentToken = IERC20(payment_token_);
        _baseTokenURI = baseTokenURI_;
    }

    //--------------------------------------------------------------------------
    // IIPTicketService
    //--------------------------------------------------------------------------
    function create_ip_asset(
        uint256 price,
        uint256 max_supply,
        uint256 expiration,
        uint256 royalty_percentage,
        string calldata metadata_uri
    ) external override returns (uint256) {
        uint256 ipId = next_ip_asset_id++;
        ip_assets[ipId] = IPAsset({
            owner: msg.sender,
            price: price,
            max_supply: max_supply,
            tickets_minted: 0,
            expiration: expiration,
            royalty_percentage: royalty_percentage,
            metadata_uri: metadata_uri
        });

        emit IPAssetCreated(
            ipId,
            msg.sender,
            price,
            max_supply,
            expiration,
            royalty_percentage,
            metadata_uri
        );

        return ipId;
    }

    function mint_ticket(uint256 ip_asset_id) external override {
        IPAsset storage ip = ip_assets[ip_asset_id];
        require(ip.max_supply > 0, "ip not found");
        require(ip.tickets_minted < ip.max_supply, "Max supply reached");

        // Paiement ERC20: l'appelant doit avoir donné allowance à ce contrat
        // Vers le propriétaire de l'IP
        require(
            paymentToken.transferFrom(msg.sender, ip.owner, ip.price),
            "ERC20 transfer failed"
        );

        uint256 tokenId = next_token_id++;
        _safeMint(msg.sender, tokenId);

        token_to_ip_asset[tokenId] = ip_asset_id;
        user_ip_asset_balance[msg.sender][ip_asset_id] += 1;
        total_supply += 1;
        ip.tickets_minted += 1;

        emit TicketMinted(tokenId, ip_asset_id, msg.sender);
    }

    function has_valid_ticket(address user, uint256 ip_asset_id)
        external
        view
        override
        returns (bool)
    ) {
        IPAsset storage ip = ip_assets[ip_asset_id];
        if (block.timestamp >= ip.expiration) return false;
        return user_ip_asset_balance[user][ip_asset_id] > 0;
    }

    //--------------------------------------------------------------------------
    // Royalties (signature ERC-2981)
    //--------------------------------------------------------------------------
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    ) {
        uint256 ipId = token_to_ip_asset[tokenId];
        IPAsset storage ip = ip_assets[ipId];
        receiver = ip.owner;
        royaltyAmount = (salePrice * ip.royalty_percentage) / 10_000;
    }

    //--------------------------------------------------------------------------
    // ERC-721 helpers
    //--------------------------------------------------------------------------
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    //--------------------------------------------------------------------------
    // ERC165 / IERC2981
    //--------------------------------------------------------------------------
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
