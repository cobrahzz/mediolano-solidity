// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockToken {
    // Stockage
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    string  private _name;
    string  private _symbol;
    uint8   private _decimals;
    uint256 private _totalSupply;
    address private _owner; // non utilisé pour l'ACL de mint (fidèle au Cairo)

    // Événements
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address owner_) {
        _name = "Mock Token";
        _symbol = "MKT";
        _decimals = 18;
        _owner = owner_;
    }

    // ----- Lecture style Cairo + standard -----
    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function decimals() external view returns (uint8) { return _decimals; }

    // Pour compat avec l’interface “Cairo-style”
    function total_supply() external view returns (uint256) { return _totalSupply; }
    // Standard
    function totalSupply() external view returns (uint256) { return _totalSupply; }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ----- Écriture -----
    function transfer(address recipient, uint256 amount) external returns (bool) {
        address sender = msg.sender;
        uint256 sb = _balances[sender];
        require(sb >= amount, "INSUFFICIENT_BALANCE");

        unchecked {
            _balances[sender] = sb - amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
        return true;
    }

    // Standard
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        address spender = msg.sender;
        uint256 allowed = _allowances[sender][spender];
        require(allowed >= amount, "ALLOWANCE_EXCEEDED");
        require(_balances[sender] >= amount, "INSUFFICIENT_BALANCE");

        unchecked {
            _allowances[sender][spender] = allowed - amount;
            _balances[sender] -= amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
        return true;
    }

    // Cairo-style alias
    function transfer_from(address sender, address recipient, uint256 amount) external returns (bool) {
        return transferFrom(sender, recipient, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // Mint SANS restriction (fidèle à ton Cairo)
    function mint(address recipient, uint256 amount) external returns (bool) {
        _totalSupply += amount;
        _balances[recipient] += amount;

        emit Transfer(address(0), recipient, amount);
        return true;
    }
}
