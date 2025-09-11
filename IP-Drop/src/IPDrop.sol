// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract IPDrop {
    struct ClaimConditions {
        uint64 startTime;
        uint64 endTime;
        uint256 price;
        uint256 maxQuantityPerWallet;
        address paymentToken;
    }

    struct TokenOwnership {
        address addr;
        uint64 start_timestamp;
    }

    string public name;
    string public symbol;
    string public base_uri;

    uint256 public current_index;
    uint256 private _max_supply;

    mapping(uint256 => TokenOwnership) private _packed_ownerships;
    mapping(address => uint256) private _packed_address_data;

    mapping(uint256 => address) private _token_approvals;
    mapping(address => mapping(address => bool)) private _operator_approvals;

    ClaimConditions private _claim_conditions;
    mapping(address => uint256) private _claimed_by_wallet;

    mapping(address => bool) private _allowlist;
    bool private _allowlist_enabled;

    uint256 public total_payments_received;

    address public owner;

    uint256 private _locked = 1;

    event Transfer(address indexed from, address indexed to, uint256 indexed token_id);
    event Approval(address indexed owner, address indexed approved, uint256 indexed token_id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event TokensClaimed(address indexed claimer, uint256 quantity, uint256 start_token_id, uint256 total_paid);
    event ClaimConditionsUpdated(ClaimConditions conditions);
    event AllowlistUpdated(address indexed user, bool allowed);
    event PaymentReceived(address indexed from, uint256 amount, address token);
    event PaymentsWithdrawn(address indexed to, uint256 amount, address token);
    event BaseURIUpdated(string new_base_uri);

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _base_uri,
        uint256 max_supply_,
        address owner_,
        ClaimConditions memory initial_conditions,
        bool allowlist_enabled_
    ) {
        require(owner_ != address(0), "OWNER_ZERO");
        name = _name;
        symbol = _symbol;
        base_uri = _base_uri;
        _max_supply = max_supply_;
        current_index = 1;
        _claim_conditions = initial_conditions;
        _allowlist_enabled = allowlist_enabled_;
        total_payments_received = 0;
        owner = owner_;
    }

    modifier only_owner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    modifier non_reentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    function token_uri(uint256 token_id) external view returns (string memory) {
        _require_exists(token_id);
        return string(abi.encodePacked(base_uri, _toString(token_id)));
    }

    function balance_of(address account) external view returns (uint256) {
        require(account != address(0), "Invalid owner address");
        return _packed_address_data[account];
    }

    function owner_of(uint256 token_id) public view returns (address) {
        require(_exists(token_id), "ERC721: invalid token ID");
        uint256 curr = token_id;
        while (true) {
            TokenOwnership memory o = _packed_ownerships[curr];
            if (o.addr != address(0)) return o.addr;
            unchecked { curr--; }
        }
    }

    function get_approved(uint256 token_id) external view returns (address) {
        require(_exists(token_id), "ERC721: approved query for nonexistent token");
        return _token_approvals[token_id];
    }

    function is_approved_for_all(address _owner, address operator) public view returns (bool) {
        return _operator_approvals[_owner][operator];
    }

    function approve(address to, uint256 token_id) external {
        address _owner = owner_of(token_id);
        require(to != _owner, "Approval to current owner");
        require(
            msg.sender == _owner || is_approved_for_all(_owner, msg.sender),
            "ERC721: approve caller is not token owner or approved for all"
        );
        _approve(to, token_id, _owner);
    }

    function set_approval_for_all(address operator, bool approved) external {
        require(operator != msg.sender, "Approve to caller");
        _operator_approvals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transfer_from(address from, address to, uint256 token_id) public {
        _transfer(from, to, token_id);
    }

    function safe_transfer_from(address from, address to, uint256 token_id, bytes calldata) external {
        _transfer(from, to, token_id);
    }

    function claim(uint256 quantity) external non_reentrant {
        _validate_claim(msg.sender, quantity);
        require(_claim_conditions.price == 0, "Payment required");
        _execute_claim(msg.sender, quantity, 0);
    }

    function claim_with_payment(uint256 quantity) external non_reentrant {
        _validate_claim(msg.sender, quantity);
        uint256 total_cost = _claim_conditions.price * quantity;
        require(total_cost > 0, "No payment required - use claim");
        if (_claim_conditions.paymentToken != address(0)) {
            bool ok = IERC20(_claim_conditions.paymentToken).transferFrom(
                msg.sender, address(this), total_cost
            );
            require(ok, "Payment transfer failed");
            emit PaymentReceived(msg.sender, total_cost, _claim_conditions.paymentToken);
        }
        total_payments_received += total_cost;
        _execute_claim(msg.sender, quantity, total_cost);
    }

    function set_claim_conditions(ClaimConditions memory conditions) external only_owner {
        require(conditions.startTime < conditions.endTime, "Invalid time range");
        require(conditions.maxQuantityPerWallet > 0, "Invalid max quantity");
        _claim_conditions = conditions;
        emit ClaimConditionsUpdated(conditions);
    }

    function add_to_allowlist(address addr) external only_owner {
        require(addr != address(0), "Invalid address");
        _allowlist[addr] = true;
        emit AllowlistUpdated(addr, true);
    }

    function add_batch_to_allowlist(address[] calldata addrs) external only_owner {
        for (uint256 i = 0; i < addrs.length; i++) {
            require(addrs[i] != address(0), "Invalid address in batch");
            _allowlist[addrs[i]] = true;
            emit AllowlistUpdated(addrs[i], true);
        }
    }

    function remove_from_allowlist(address addr) external only_owner {
        _allowlist[addr] = false;
        emit AllowlistUpdated(addr, false);
    }

    function set_base_uri(string calldata new_base_uri) external only_owner {
        base_uri = new_base_uri;
        emit BaseURIUpdated(new_base_uri);
    }

    function set_allowlist_enabled(bool enabled) external only_owner {
        _allowlist_enabled = enabled;
    }

    function withdraw_payments() external only_owner {
        uint256 amt = total_payments_received;
        require(amt > 0, "No payments to withdraw");
        address token = _claim_conditions.paymentToken;
        if (token != address(0)) {
            bool ok = IERC20(token).transfer(owner, amt);
            require(ok, "Withdrawal failed");
            emit PaymentsWithdrawn(owner, amt, token);
        }
        total_payments_received = 0;
    }

    function total_supply() public view returns (uint256) {
        uint256 curr = current_index;
        return curr == 0 ? 0 : (curr - 1);
    }

    function max_supply() external view returns (uint256) {
        return _max_supply;
    }

    function get_claim_conditions() external view returns (ClaimConditions memory) {
        return _claim_conditions;
    }

    function is_allowlisted(address addr) public view returns (bool) {
        if (!_allowlist_enabled) return true;
        return _allowlist[addr];
    }

    function is_allowlist_enabled() external view returns (bool) {
        return _allowlist_enabled;
    }

    function claimed_by_wallet(address wallet) external view returns (uint256) {
        return _claimed_by_wallet[wallet];
    }

    function _validate_claim(address claimer, uint256 quantity) internal view {
        uint256 nowTs = block.timestamp;
        require(nowTs >= _claim_conditions.startTime, "Claim not started");
        require(nowTs <= _claim_conditions.endTime, "Claim ended");
        require(quantity > 0, "Invalid quantity");
        require(total_supply() + quantity <= _max_supply, "Exceeds max supply");
        uint256 already = _claimed_by_wallet[claimer];
        require(already + quantity <= _claim_conditions.maxQuantityPerWallet, "Exceeds wallet limit");
        if (_allowlist_enabled) {
            require(_allowlist[claimer], "Not on allowlist");
        }
    }

    function _execute_claim(address claimer, uint256 quantity, uint256 total_paid) internal {
        uint256 start_token_id = current_index;
        _claimed_by_wallet[claimer] += quantity;
        _mint_batch(claimer, quantity);
        emit TokensClaimed(claimer, quantity, start_token_id, total_paid);
    }

    function _mint_batch(address to, uint256 quantity) internal {
        uint256 startId = current_index;
        uint256 endId;
        unchecked { endId = startId + quantity; }
        _packed_address_data[to] += quantity;
        _packed_ownerships[startId] = TokenOwnership({
            addr: to,
            start_timestamp: uint64(block.timestamp)
        });
        for (uint256 id = startId; id < endId; id++) {
            emit Transfer(address(0), to, id);
        }
        current_index = endId;
    }

    function _exists(uint256 token_id) internal view returns (bool) {
        return token_id > 0 && token_id < current_index;
    }

    function _require_exists(uint256 token_id) internal view {
        require(_exists(token_id), "Token does not exist");
    }

    function _approve(address to, uint256 token_id, address token_owner) internal {
        _token_approvals[token_id] = to;
        emit Approval(token_owner, to, token_id);
    }

    function _transfer(address from, address to, uint256 token_id) internal {
        require(owner_of(token_id) == from, "Not token owner");
        require(to != address(0), "Transfer to zero address");
        address caller = msg.sender;
        require(
            caller == from ||
            _token_approvals[token_id] == caller ||
            is_approved_for_all(from, caller),
            "ERC721: caller is not token owner or approved"
        );
        _approve(address(0), token_id, from);
        if (_packed_ownerships[token_id].addr == address(0)) {
            _packed_ownerships[token_id] = TokenOwnership(from, uint64(block.timestamp));
        }
        _packed_ownerships[token_id] = TokenOwnership(to, uint64(block.timestamp));
        uint256 next = token_id + 1;
        if (next < current_index && _packed_ownerships[next].addr == address(0)) {
            _packed_ownerships[next] = TokenOwnership(from, uint64(block.timestamp));
        }
        unchecked {
            _packed_address_data[from] -= 1;
            _packed_address_data[to] += 1;
        }
        emit Transfer(from, to, token_id);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
