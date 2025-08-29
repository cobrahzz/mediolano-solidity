// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Programmable IP Assignment (Solidity port)
/// @notice Gestion d'actifs "IP" (identifiés par bytes32) : création, transfert de
///         propriété, cession conditionnelle (assignments), royalties et exclusivité.
contract IPAssignment {
    // --------- Types ---------
    struct AssignmentData {
        uint64  start_time;        // UNIX timestamp
        uint64  end_time;          // UNIX timestamp
        uint128 royalty_rate;      // en basis points (1% = 100) max 10000
        uint8   rights_percentage; // 0..100
        bool    is_exclusive;      // exclusivité
    }

    // --------- Storage ---------
    address private _contractOwner;

    // IP Management
    mapping(bytes32 ipId => address owner) public ip_owner;
    mapping(bytes32 ipId => uint64 createdAt) public ip_created_at;

    // Assignments
    mapping(bytes32 ipId => mapping(address assignee => AssignmentData)) public assignments;
    mapping(bytes32 ipId => address[])                            private _assignees_list;
    mapping(bytes32 ipId => address assignee)                     public exclusive_assignee;
    mapping(bytes32 ipId => mapping(address assignee => bool))    public assignees; // present in list?
    mapping(bytes32 ipId => uint8 total)                          public total_assigned_rights;

    // Financials
    mapping(bytes32 ipId => mapping(address beneficiary => uint256)) public royalty_balances;
    mapping(bytes32 ipId => uint256) public total_royalty_reserve;

    // --------- Events ---------
    event IPCreated(bytes32 indexed ip_id, address indexed owner, uint64 timestamp);
    event IPAssigned(
        bytes32 indexed ip_id,
        address indexed assignee,
        uint64 start_time,
        uint64 end_time,
        uint128 royalty_rate,
        uint8 rights_percentage,
        bool is_exclusive
    );
    event IPOwnershipTransferred(bytes32 indexed ip_id, address indexed previous_owner, address indexed new_owner);
    event RoyaltyReceived(bytes32 indexed ip_id, uint256 amount, address indexed recipient);
    event RoyaltyWithdrawn(bytes32 indexed ip_id, address indexed beneficiary, uint256 amount);

    // --------- Constructor ---------
    constructor(address initial_owner) {
        _contractOwner = initial_owner;
    }

    // --------- Internal helpers ---------
    function _only_ip_owner(bytes32 ip_id) internal view {
        require(ip_owner[ip_id] == msg.sender, "IP: Caller not owner");
    }

    function _only_contract_owner() internal view {
        require(_contractOwner == msg.sender, "IP: Caller not admin");
    }

    function _validate_conditions(AssignmentData memory conditions) internal pure {
        require(conditions.end_time > conditions.start_time, "IP: Invalid time range");
        require(conditions.rights_percentage <= 100, "IP: Rights exceed 100%");
        require(conditions.royalty_rate <= 10000, "IP: Royalty rate too high");
    }

    function _pushAssignee(bytes32 ip_id, address user) internal {
        if (!assignees[ip_id][user]) {
            assignees[ip_id][user] = true;
            _assignees_list[ip_id].push(user);
        }
    }

    function _getActiveAssignees(bytes32 ip_id) internal view returns (address[] memory active) {
        address[] storage list = _assignees_list[ip_id];
        uint256 n = list.length;
        address[] memory tmp = new address[](n);
        uint256 m;

        uint64 nowTs = uint64(block.timestamp);
        address excl = exclusive_assignee[ip_id];

        for (uint256 i = 0; i < n; i++) {
            address a = list[i];
            AssignmentData memory d = assignments[ip_id][a];

            bool time_valid = (nowTs >= d.start_time && nowTs <= d.end_time);
            bool exclusive_valid = d.is_exclusive ? (excl == a) : true;

            if (time_valid && exclusive_valid) {
                tmp[m++] = a;
            }
        }

        active = new address[](m);
        for (uint256 j = 0; j < m; j++) active[j] = tmp[j];
    }

    function _calculate_total_royalty(bytes32 ip_id) internal view returns (uint256 total) {
        address[] memory actives = _getActiveAssignees(ip_id);
        uint256 n = actives.length;
        for (uint256 i = 0; i < n; i++) {
            total += assignments[ip_id][actives[i]].royalty_rate;
        }
    }

    /// @dev Distribue "amount", crédite owner + assignees actifs selon royalty_rate (bps).
    /// @return remaining le reliquat (si total_rate < 10000)
    function _distribute_royalties(bytes32 ip_id, uint256 amount) internal returns (uint256 remaining) {
        remaining = amount;

        uint256 total_rate = _calculate_total_royalty(ip_id);
        require(total_rate <= 10000, "IP: Total royalty too high"); // garde-fou

        if (total_rate > 0) {
            address ownerAddr = ip_owner[ip_id];

            // part owner
            uint256 owner_share = amount * (10000 - total_rate) / 10000;
            royalty_balances[ip_id][ownerAddr] += owner_share;
            remaining -= owner_share;

            // parts assignees
            address[] memory actives = _getActiveAssignees(ip_id);
            for (uint256 i = 0; i < actives.length; i++) {
                AssignmentData memory d = assignments[ip_id][actives[i]];
                uint256 share = amount * d.royalty_rate / 10000;
                royalty_balances[ip_id][actives[i]] += share;
                remaining -= share;
            }
        }
    }

    // --------- External functions (parité avec Cairo) ---------

    /// Creates new IP with caller as owner
    function create_ip(bytes32 ip_id) external {
        require(ip_owner[ip_id] == address(0), "IP: Already exists");
        address caller = msg.sender;
        uint64 ts = uint64(block.timestamp);

        ip_owner[ip_id] = caller;
        ip_created_at[ip_id] = ts;

        emit IPCreated(ip_id, caller, ts);
    }

    /// Transfers ownership of an IP asset
    function transfer_ip_ownership(bytes32 ip_id, address new_owner) external {
        _only_ip_owner(ip_id);
        require(new_owner != address(0), "IP: Invalid owner");

        address prev = ip_owner[ip_id];
        ip_owner[ip_id] = new_owner;

        emit IPOwnershipTransferred(ip_id, prev, new_owner);
    }

    /// Assigns IP rights under specified conditions
    function assign_ip(bytes32 ip_id, address assignee, AssignmentData calldata conditions) external {
        _only_ip_owner(ip_id);
        require(assignee != address(0), "IP: Invalid assignee");
        _validate_conditions(conditions);

        // Exclusivité: 1 seul assignee exclusif par IP
        if (conditions.is_exclusive) {
            require(exclusive_assignee[ip_id] == address(0), "IP: Exclusive exists");
            exclusive_assignee[ip_id] = assignee;
        }

        // Droits cumulés <= 100
        uint8 total = total_assigned_rights[ip_id] + conditions.rights_percentage;
        require(total <= 100, "IP: Rights exceeded");
        total_assigned_rights[ip_id] = total;

        // Enregistrement
        assignments[ip_id][assignee] = conditions;
        _pushAssignee(ip_id, assignee);

        emit IPAssigned(
            ip_id,
            assignee,
            conditions.start_time,
            conditions.end_time,
            conditions.royalty_rate,
            conditions.rights_percentage,
            conditions.is_exclusive
        );
    }

    /// Process royalty payment distribution
    function receive_royalty(bytes32 ip_id, uint256 amount) external {
        require(amount > 0, "IP: Invalid amount");

        uint256 remaining = _distribute_royalties(ip_id, amount);
        total_royalty_reserve[ip_id] += remaining;

        emit RoyaltyReceived(ip_id, amount, msg.sender);
    }

    /// Withdraw accumulated royalties (no token transfer here, just accounting)
    function withdraw_royalties(bytes32 ip_id) external {
        address caller = msg.sender;
        uint256 bal = royalty_balances[ip_id][caller];
        require(bal > 0, "IP: No balance");

        royalty_balances[ip_id][caller] = 0; // effet de retrait (mock)
        emit RoyaltyWithdrawn(ip_id, caller, bal);
    }

    /// Retrieves assignment details for IP-assignee pair
    function get_assignment_data(bytes32 ip_id, address assignee)
        external
        view
        returns (AssignmentData memory)
    {
        return assignments[ip_id][assignee];
    }

    /// Verifies if current conditions are met
    function check_assignment_condition(bytes32 ip_id, address assignee) external view returns (bool) {
        AssignmentData memory d = assignments[ip_id][assignee];
        uint64 nowTs = uint64(block.timestamp);

        bool valid = true;
        valid = valid && (nowTs >= d.start_time);
        valid = valid && (nowTs <= d.end_time);

        if (d.is_exclusive) {
            valid = valid && (exclusive_assignee[ip_id] == assignee);
        }
        return valid;
    }

    // Getters parity
    function get_contract_owner() external view returns (address) {
        return _contractOwner;
    }

    function get_ip_owner(bytes32 ip_id) external view returns (address) {
        return ip_owner[ip_id];
    }

    function get_royalty_balance(bytes32 ip_id, address beneficiary) external view returns (uint256) {
        return royalty_balances[ip_id][beneficiary];
    }
}
