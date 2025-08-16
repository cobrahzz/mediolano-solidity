// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Compat pour tokens ERC20 qui ne retournent pas bool (ou mal).
library SafeERC20Compat {
    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok, "ERC20 call failed");
        if (ret.length > 0) {
            require(abi.decode(ret, (bool)), "ERC20 op did not succeed");
        }
    }
    function safeTransfer(address token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, value));
    }
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)")), from, to, value));
    }
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Reentrancy guard minimaliste (OpenZeppelin-like).
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract IPCrowdfunding is ReentrancyGuard {
    using SafeERC20Compat for address;

    struct Campaign {
        address creator;
        string title;
        string description;
        uint256 goalAmount;
        uint256 raisedAmount;
        uint64 startTime;
        uint64 endTime;
        bool completed;
        bool refunded;
    }

    struct Contribution {
        address contributor;
        uint256 amount;
        uint64 timestamp;
    }

    address public owner;
    IERC20 public token; // exposé en lecture, mais on passe par SafeERC20Compat pour les calls

    uint256 public campaignsCount;
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(uint256 => Contribution)) public contributions; // (campaignId => (contributionId => Contribution))
    mapping(uint256 => uint256) public campaignContributionsCount;

    event CampaignCreated(uint256 indexed campaignId, address creator, string title);
    event ContributionMade(uint256 indexed campaignId, address contributor, uint256 amount);
    event FundsWithdrawn(uint256 indexed campaignId);
    event ContributionsRefunded(uint256 indexed campaignId, uint256 totalAmount);

    constructor(address _owner, address _token) {
        require(_owner != address(0), "Owner zero");
        require(_token != address(0), "Token zero");
        owner = _owner;
        token = IERC20(_token);
        campaignsCount = 0;
    }

    function create_campaign(
        string memory title,
        string memory description,
        uint256 goalAmount,
        uint64 duration
    ) external nonReentrant {
        require(bytes(title).length != 0, "Empty title");
        require(goalAmount > 0, "Invalid goal");
        require(duration > 0, "Invalid duration");

        uint256 campaignId = campaignsCount + 1;
        uint64 nowTs = uint64(block.timestamp);

        campaigns[campaignId] = Campaign({
            creator: msg.sender,
            title: title,
            description: description,
            goalAmount: goalAmount,
            raisedAmount: 0,
            startTime: nowTs,
            endTime: nowTs + duration,
            completed: false,
            refunded: false
        });

        campaignsCount = campaignId;
        emit CampaignCreated(campaignId, msg.sender, title);
    }

    function contribute(uint256 campaignId, uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");

        Campaign storage c = campaigns[campaignId];
        require(c.startTime != 0, "Campaign not found");
        require(block.timestamp >= c.startTime, "Campaign not started");
        require(block.timestamp <= c.endTime, "Campaign ended");
        require(!c.completed, "Campaign completed");
        require(!c.refunded, "Campaign refunded");

        // Effects (on écrit l'état AVANT l'interaction externe)
        uint256 contributionId = campaignContributionsCount[campaignId] + 1;
        contributions[campaignId][contributionId] = Contribution({
            contributor: msg.sender,
            amount: amount,
            timestamp: uint64(block.timestamp)
        });
        campaignContributionsCount[campaignId] = contributionId;

        unchecked { c.raisedAmount += amount; }

        // Interaction externe (après) + garde compat ERC20
        address(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        emit ContributionMade(campaignId, msg.sender, amount);
    }

    function withdraw_funds(uint256 campaignId) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.startTime != 0, "Campaign not found");
        require(msg.sender == c.creator, "Not the creator");
        require(!c.completed, "Campaign completed");
        require(!c.refunded, "Campaign refunded");
        require(c.raisedAmount >= c.goalAmount, "Goal not reached");

        uint256 amount = c.raisedAmount;

        // Effects
        c.completed = true;

        // Interaction
        address(address(token)).safeTransfer(c.creator, amount);

        emit FundsWithdrawn(campaignId);
    }

    function refund_contributions(uint256 campaignId) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.startTime != 0, "Campaign not found");
        require(!c.completed, "Campaign completed");
        require(!c.refunded, "Already refunded");
        require(c.raisedAmount < c.goalAmount, "Goal reached");
        require(block.timestamp > c.endTime, "Campaign not ended");

        uint256 count = campaignContributionsCount[campaignId];

        // Effects (marque comme remboursé d'abord — revert annulerait tout si un transfer échoue)
        c.refunded = true;

        // Interaction(s)
        uint256 total;
        for (uint256 i = 1; i <= count; ) {
            Contribution memory cont = contributions[campaignId][i];
            if (cont.amount > 0) {
                address(address(token)).safeTransfer(cont.contributor, cont.amount);
                unchecked { total += cont.amount; }
            }
            unchecked { ++i; }
        }

        emit ContributionsRefunded(campaignId, total);
    }

    // helpers "getters"
    function get_campaign(uint256 campaignId) external view returns (Campaign memory) {
        return campaigns[campaignId];
    }

    function get_contributions(uint256 campaignId) external view returns (Contribution[] memory arr) {
        uint256 count = campaignContributionsCount[campaignId];
        arr = new Contribution[](count);
        for (uint256 i = 0; i < count; ) {
            arr[i] = contributions[campaignId][i + 1];
            unchecked { ++i; }
        }
    }
}
