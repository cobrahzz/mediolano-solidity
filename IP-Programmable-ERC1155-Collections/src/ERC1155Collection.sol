// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ─────────────────────────────────────────────────────────────────────────────
   Minimal Ownable (stocké dans le proxy, utilisé par Impl & Factory)
───────────────────────────────────────────────────────────────────────────── */
abstract contract OwnableLite {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function __initOwner(address newOwner) internal {
        require(_owner == address(0), "Owner already set");
        _owner = newOwner;
        emit OwnershipTransferred(address(0), newOwner);
    }

    function owner() public view returns (address) { return _owner; }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Only owner");
        _;
    }

    function transfer_ownership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounce_ownership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
   ERC1155 minimal (balances + approvals + URI par token + safe transfers)
   Noms des fonctions en snake_case pour coller à l'ABI Cairo.
───────────────────────────────────────────────────────────────────────────── */
interface IERC1155Receiver {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external returns (bytes4);
    function onERC1155BatchReceived(address operator, address from, uint256[] calldata ids, uint256[] calldata values, bytes calldata data)
        external returns (bytes4);
}

abstract contract ERC1155Lite {
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 token_id, uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] token_ids, uint256[] values);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    mapping(uint256 => mapping(address => uint256)) internal _balances;         // id => (account => amount)
    mapping(address => mapping(address => bool)) internal _operatorApprovals;   // owner => (op => approved)
    mapping(uint256 => string) internal _uri;                                   // id => URI

    /* ----- lectures/approvals ----- */
    function balance_of(address account, uint256 token_id) public view returns (uint256) {
        return _balances[token_id][account];
    }

    function balance_of_batch(address[] calldata accounts, uint256[] calldata token_ids)
        public view returns (uint256[] memory)
    {
        require(accounts.length == token_ids.length, "Arrays length mismatch");
        uint256[] memory out = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            out[i] = _balances[token_ids[i]][accounts[i]];
        }
        return out;
    }

    function is_approved_for_all(address _owner, address operator) public view returns (bool) {
        return _operatorApprovals[_owner][operator];
    }

    function set_approval_for_all(address operator, bool approved) public {
        require(operator != msg.sender, "Self approval");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function uri(uint256 token_id) public view returns (string memory) {
        return _uri[token_id];
    }

    /* ----- transferts ----- */
    function safe_transfer_from(
        address from, address to, uint256 token_id, uint256 value, bytes calldata data
    ) public {
        require(to != address(0), "Invalid recipient");
        require(from == msg.sender || is_approved_for_all(from, msg.sender), "Not authorized");

        _beforeTokenTransfer(from, to, _asSingleton(token_id), _asSingleton(value), data);

        uint256 fb = _balances[token_id][from];
        require(fb >= value, "Insufficient balance");
        _balances[token_id][from] = fb - value;
        _balances[token_id][to]   += value;

        emit TransferSingle(msg.sender, from, to, token_id, value);
        _doSafeTransferAcceptanceCheck(msg.sender, from, to, token_id, value, data);
    }

    function safe_batch_transfer_from(
        address from, address to, uint256[] calldata token_ids, uint256[] calldata values, bytes calldata data
    ) public {
        require(to != address(0), "Invalid recipient");
        require(token_ids.length == values.length, "Arrays length mismatch");
        require(from == msg.sender || is_approved_for_all(from, msg.sender), "Not authorized");

        _beforeTokenTransfer(from, to, token_ids, values, data);

        for (uint256 i = 0; i < token_ids.length; i++) {
            uint256 id = token_ids[i];
            uint256 val = values[i];
            uint256 fb = _balances[id][from];
            require(fb >= val, "Insufficient balance");
            _balances[id][from] = fb - val;
            _balances[id][to]   += val;
        }

        emit TransferBatch(msg.sender, from, to, token_ids, values);
        _doSafeBatchTransferAcceptanceCheck(msg.sender, from, to, token_ids, values, data);
    }

    /* ----- mints internes avec acceptance check ----- */
    function _mint(address to, uint256 id, uint256 value, bytes memory data) internal {
        require(to != address(0), "Invalid recipient");
        _beforeTokenTransfer(address(0), to, _asSingleton(id), _asSingleton(value), data);
        _balances[id][to] += value;
        emit TransferSingle(msg.sender, address(0), to, id, value);
        _doSafeTransferAcceptanceCheck(msg.sender, address(0), to, id, value, data);
    }

    function _mintBatch(address to, uint256[] memory ids, uint256[] memory values, bytes memory data) internal {
        require(to != address(0), "Invalid recipient");
        require(ids.length == values.length, "Arrays length mismatch");

        _beforeTokenTransfer(address(0), to, ids, values, data);
        for (uint256 i = 0; i < ids.length; i++) {
            _balances[ids[i]][to] += values[i];
        }
        emit TransferBatch(msg.sender, address(0), to, ids, values);
        _doSafeBatchTransferAcceptanceCheck(msg.sender, address(0), to, ids, values, data);
    }

    /* ----- hooks / helpers ----- */
    function _beforeTokenTransfer(
        address /*from*/, address /*to*/, uint256[] memory /*ids*/, uint256[] memory /*values*/, bytes memory /*data*/
    ) internal virtual {}

    function _asSingleton(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256; arr[0] = x;
    }

    function _doSafeTransferAcceptanceCheck(
        address operator, address from, address to, uint256 id, uint256 value, bytes memory data
    ) private {
        if (to.code.length == 0) return;
        try IERC1155Receiver(to).onERC1155Received(operator, from, id, value, data) returns (bytes4 v) {
            require(v == IERC1155Receiver.onERC1155Received.selector, "Receiver rejected");
        } catch { revert("Receiver rejected"); }
    }

    function _doSafeBatchTransferAcceptanceCheck(
        address operator, address from, address to, uint256[] memory ids, uint256[] memory values, bytes memory data
    ) private {
        if (to.code.length == 0) return;
        try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, values, data) returns (bytes4 v) {
            require(v == IERC1155Receiver.onERC1155BatchReceived.selector, "Receiver rejected");
        } catch { revert("Receiver rejected"); }
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
   EIP-1967 Proxy (UUPS-style): upgrade gouverné par l'impl via delegatecall
───────────────────────────────────────────────────────────────────────────── */
contract ERC1967Proxy {
    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory initData) payable {
        _setImplementation(implementation);
        if (initData.length > 0) {
            (bool ok, bytes memory ret) = implementation.delegatecall(initData);
            require(ok, _getRevertMsg(ret));
        }
    }

    fallback() external payable {
        _delegate(_implementation());
    }

    receive() external payable {
        _delegate(_implementation());
    }

    function _implementation() internal view returns (address impl) {
        bytes32 slot = _IMPLEMENTATION_SLOT;
        assembly { impl := sload(slot) }
    }

    function _setImplementation(address newImpl) internal {
        bytes32 slot = _IMPLEMENTATION_SLOT;
        assembly { sstore(slot, newImpl) }
    }

    function _delegate(address impl) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(0, 0, size)
            switch result
            case 0 { revert(0, size) }
            default { return(0, size) }
        }
    }

    function _getRevertMsg(bytes memory ret) private pure returns (string memory) {
        if (ret.length < 68) return "init failed";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
   Impl v1 : ERC1155Collection (Ownable + ERC1155Lite + Upgrade)
───────────────────────────────────────────────────────────────────────────── */
contract ERC1155Collection is OwnableLite, ERC1155Lite {
    // copie du slot EIP-1967 pour lire/écrire la target via delegatecall
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // On garde aussi une copie lisible façon Cairo: class_hash = implementation
    address private _class_hash;
    bool private _initialized;

    /* ---------------------------- initialisation ---------------------------- */
    // Remplace le constructor Cairo: owner, token_uri commun, mint batch
    function initialize(
        address owner_,
        string memory token_uri,
        address recipient,
        uint256[] memory token_ids,
        uint256[] memory values
    ) external {
        require(!_initialized, "Already initialized");
        __initOwner(owner_);
        require(recipient != address(0), "Invalid recipient");
        require(token_ids.length == values.length, "Arrays length mismatch");

        // set URI sur chaque id fourni
        for (uint256 i = 0; i < token_ids.length; i++) {
            _uri[token_ids[i]] = token_uri;
        }

        // mint initial
        _mintBatch(recipient, token_ids, values, "");

        // mémoriser l'impl courante comme "class hash"
        _class_hash = _getImplementation();
        _initialized = true;
    }

    /* ---------------------------- interface Cairo --------------------------- */
    function class_hash() external view returns (address) {
        return _class_hash;
    }

    function mint(address to, uint256 token_id, uint256 value) external onlyOwner {
        _mint(to, token_id, value, "");
    }

    // upgrade(new_class_hash) — équiv. à UpgradeableComponent::upgrade(...)
    function upgrade(address new_impl) external onlyOwner {
        _upgradeTo(new_impl);
        _class_hash = new_impl;
    }

    /* ----------------------------- internes UUPS ---------------------------- */
    function _getImplementation() internal view returns (address impl) {
        bytes32 slot = _IMPLEMENTATION_SLOT;
        assembly { impl := sload(slot) }
    }
    function _setImplementation(address newImpl) internal {
        bytes32 slot = _IMPLEMENTATION_SLOT;
        assembly { sstore(slot, newImpl) }
    }
    function _upgradeTo(address newImpl) internal {
        require(newImpl.code.length > 0, "Impl has no code");
        _setImplementation(newImpl);
    }
}

/* Version 2 (pour test d’upgrade) — même storage layout */
contract ERC1155CollectionV2 is ERC1155Collection {
    function version() external pure returns (string memory) { return "v2"; }
}

/* ─────────────────────────────────────────────────────────────────────────────
   Factory : Ownable + class_hash (impl addr) + deploy via CREATE2 + init call
───────────────────────────────────────────────────────────────────────────── */
contract ERC1155CollectionsFactory is OwnableLite {
    address public erc1155_collections_class_hash; // adresse de l'impl
    uint256 public contract_address_salt;          // incrémenté à chaque déploiement

    constructor(address owner_, address impl) {
        __initOwner(owner_);
        erc1155_collections_class_hash = impl;
        contract_address_salt = 0;
    }

    function update_erc1155_collections_class_hash(address newImpl) external onlyOwner {
        require(newImpl != address(0), "Zero impl");
        erc1155_collections_class_hash = newImpl;
    }

    // deploy_erc1155_collection(token_uri, recipient, token_ids, values) -> proxy
    function deploy_erc1155_collection(
        string calldata token_uri,
        address recipient,
        uint256[] calldata token_ids,
        uint256[] calldata values
    ) external returns (address) {
        bytes memory initData = abi.encodeWithSelector(
            ERC1155Collection.initialize.selector,
            msg.sender,  // owner = caller (Cairo: get_caller_address())
            token_uri,
            recipient,
            token_ids,
            values
        );

        address proxy = address(new ERC1967Proxy{salt: bytes32(contract_address_salt)}(
            erc1155_collections_class_hash,
            initData
        ));
        unchecked { contract_address_salt += 1; }
        return proxy;
    }
}
