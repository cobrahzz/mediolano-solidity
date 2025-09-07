// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =======================================================
   Minimal IERC20 + Mock ERC20 (pour tests/démo)
   ======================================================= */

interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address o, address s) external view returns (uint256);

    function approve(address s, uint256 amount) external returns (bool);
    function transfer(address r, uint256 amount) external returns (bool);
    function transferFrom(address sen, address r, uint256 amount) external returns (bool);

    function mint(address r, uint256 amount) external returns (bool);
}

contract ERC20Mock is IERC20 {
    string private _name;
    string private _symbol;
    uint8  private _decimals;
    uint256 private _totalSupply;
    address public owner;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        _name = "MockToken";
        _symbol = "MKT";
        _decimals = 18;
        owner = msg.sender;
    }

    function name() external view override returns (string memory) { return _name; }
    function symbol() external view override returns (string memory) { return _symbol; }
    function decimals() external view override returns (uint8) { return _decimals; }
    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address a) public view override returns (uint256) { return _balances[a]; }
    function allowance(address o, address s) external view override returns (uint256) { return _allowances[o][s]; }

    function approve(address s, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][s] = amount;
        emit Approval(msg.sender, s, amount);
        return true;
    }

    function transfer(address r, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, r, amount);
        return true;
    }

    function transferFrom(address sen, address r, uint256 amount) external override returns (bool) {
        uint256 allowed = _allowances[sen][msg.sender];
        require(allowed >= amount, "amount exceeds allowance");
        _allowances[sen][msg.sender] = allowed - amount;
        _transfer(sen, r, amount);
        return true;
    }

    function mint(address r, uint256 amount) external override returns (bool) {
        _totalSupply += amount;
        _balances[r] += amount;
        emit Transfer(address(0), r, amount);
        return true;
    }

    function _transfer(address f, address t, uint256 amount) internal {
        require(_balances[f] >= amount, "amount exceeds balance");
        _balances[f] -= amount;
        _balances[t] += amount;
        emit Transfer(f, t, amount);
    }
}

/* =======================================================
   IPNegotiationEscrow (traduction du contrat Cairo)
   - orderId: bytes32 (felt252 côté Cairo)
   - hash: keccak256(tokenId, orderCount, creator)
   ======================================================= */

contract IPNegotiationEscrow {
    struct Order {
        address creator;
        uint256 price;
        uint256 token_id;
        bool fulfilled;
        bytes32 id;
    }

    IERC20 public immutable erc20;
    address public immutable token_address;

    // order_id -> Order
    mapping(bytes32 => Order) private orders;
    // token_id -> order_id
    mapping(uint256 => bytes32) private token_to_order;
    // total orders
    uint256 public order_count;

    // suivi simple du dépôt pour chaque order
    mapping(bytes32 => bool) private depositDone;
    mapping(bytes32 => address) private orderBuyer;

    event OrderCreated(bytes32 order_id, address creator, uint256 price, uint256 token_id);
    event FundsDeposited(bytes32 order_id, address buyer, uint256 amount);
    event OrderFulfilled(bytes32 order_id, address seller, address buyer, uint256 token_id, uint256 price);
    event OrderCancelled(bytes32 order_id);

    constructor(address _tokenAddress) {
        erc20 = IERC20(_tokenAddress);
        token_address = _tokenAddress;
        order_count = 0;
    }

    /// Create a new order for IP negotiation
    function create_order(
        address creator,
        uint256 price,
        uint256 token_id
    ) external returns (bytes32 order_id) {
        require(msg.sender == creator, "Only creator can create order");

        // refuser un ordre actif pour le meme token
        bytes32 existing = token_to_order[token_id];
        if (existing != bytes32(0)) {
            require(orders[existing].fulfilled, "Token already has active order");
        }

        // Hash "equivalent" au Pedersen chain -> keccak256
        order_id = keccak256(abi.encodePacked(token_id, order_count, creator));

        Order memory o = Order({
            creator: creator,
            price: price,
            token_id: token_id,
            fulfilled: false,
            id: order_id
        });

        orders[order_id] = o;
        token_to_order[token_id] = order_id;
        order_count += 1;

        emit OrderCreated(order_id, creator, price, token_id);
    }

    /// Get order details by order ID
    function get_order(bytes32 order_id) external view returns (Order memory) {
        Order memory o = orders[order_id];
        require(o.id == order_id && order_id != bytes32(0), "Order does not exist");
        return o;
    }

    /// Get order details by token ID
    function get_order_by_token_id(uint256 token_id) external view returns (Order memory) {
        bytes32 id = token_to_order[token_id];
        require(id != bytes32(0), "No order for this token");
        return orders[id];
    }

    /// Deposit funds for an order
    /// Caller = buyer
    function deposit_funds(bytes32 order_id) external {
        Order memory o = orders[order_id];
        require(o.id == order_id && order_id != bytes32(0), "Order does not exist");
        require(!o.fulfilled, "Order already fulfilled");
        require(msg.sender != o.creator, "Creator cannot buy own IP");
        require(!depositDone[order_id], "Already deposited");

        // On s'aligne à l'intention Cairo : vérifier solde/allowance via transferFrom
        // (balance check facultatif: transferFrom renverra false si pas ok)
        bool ok = erc20.transferFrom(msg.sender, address(this), o.price);
        require(ok, "ERC20 transfer failed");

        depositDone[order_id] = true;
        orderBuyer[order_id] = msg.sender;

        emit FundsDeposited(order_id, msg.sender, o.price);
    }

    /// Fulfill an order after funds have been deposited
    /// Only creator (seller)
    function fulfill_order(bytes32 order_id) external {
        Order storage o = orders[order_id];
        require(o.id == order_id && order_id != bytes32(0), "Order does not exist");
        require(!o.fulfilled, "Order already fulfilled");
        require(msg.sender == o.creator, "Only creator can fulfill order");
        require(depositDone[order_id], "No deposit");

        address buyer = orderBuyer[order_id];

        // payer le vendeur
        bool ok = erc20.transfer(o.creator, o.price);
        require(ok, "ERC20 transfer failed");

        o.fulfilled = true;

        emit OrderFulfilled(order_id, o.creator, buyer, o.token_id, o.price);
    }

    /// Cancel an order
    /// Only creator; NOTE: pour rester proche du code Cairo, on ne rembourse pas
    /// automatiquement ici (sinon ajouter un transfert vers buyer).
    function cancel_order(bytes32 order_id) external {
        Order storage o = orders[order_id];
        require(o.id == order_id && order_id != bytes32(0), "Order does not exist");
        require(!o.fulfilled, "Order already fulfilled");
        require(msg.sender == o.creator, "Only creator can cancel order");

        o.fulfilled = true;
        emit OrderCancelled(order_id);
    }

    /* -------- Helpers (facultatifs) -------- */

    function get_order_buyer(bytes32 order_id) external view returns (address) {
        return orderBuyer[order_id];
    }

    function is_deposited(bytes32 order_id) external view returns (bool) {
        return depositDone[order_id];
    }
}
