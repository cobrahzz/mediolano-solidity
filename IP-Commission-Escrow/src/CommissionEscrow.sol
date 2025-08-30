// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal ERC20 interface compatible avec le mock Cairo / OZ utilisé dans les tests.
interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title IPCommissionEscrow (port Solidity)
/// @notice Escrow de commande d’œuvre/IP payé en ERC20, avec états et validations simples.
contract IPCommissionEscrow {
    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Compteur auto-incrémenté d’orders (orderId > 0).
    uint256 public order_count;

    /// @dev order_id => montant (ERC20)
    mapping(uint256 => uint256) public orders_amount;

    /// @dev order_id => créateur (celui qui dépose les fonds)
    mapping(uint256 => address) public orders_creator;

    /// @dev order_id => fournisseur/supplier
    mapping(uint256 => address) public orders_supplier;

    /// @dev order_id => état (bytes32 ASCII: "NotPaid" | "Paid" | "Completed" | "Cancelled")
    mapping(uint256 => bytes32) public order_states;

    /// @dev order_id => artwork conditions (ex: IPFS hash)
    mapping(uint256 => string) public orders_artwork_conditions;

    /// @dev order_id => IP license details
    mapping(uint256 => string) public orders_ip_license;

    /// @dev Jeton ERC20 utilisé pour l’escrow.
    IERC20 public immutable token;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTES
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant STATE_NOT_PAID  = bytes32("NotPaid");
    bytes32 internal constant STATE_PAID      = bytes32("Paid");
    bytes32 internal constant STATE_COMPLETED = bytes32("Completed");
    bytes32 internal constant STATE_CANCELLED = bytes32("Cancelled");

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderCreated(
        uint256 indexed order_id,
        address indexed creator,
        address indexed supplier,
        uint256 amount,
        string artwork_conditions,
        string ip_license
    );

    event OrderPaid(
        uint256 indexed order_id,
        address indexed payer,
        uint256 amount
    );

    event OrderCompleted(
        uint256 indexed order_id,
        address indexed supplier,
        uint256 amount
    );

    event OrderCancelled(uint256 indexed order_id);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param token_address Adresse du contrat ERC20 utilisé pour l’escrow.
    constructor(address token_address) {
        require(token_address != address(0), "TOKEN_ADDR_ZERO");
        token = IERC20(token_address);
        order_count = 0;
    }

    /*//////////////////////////////////////////////////////////////
                          FONCTIONS PRINCIPALES
    //////////////////////////////////////////////////////////////*/

    /// @notice Crée une nouvelle commande.
    /// @param amount Montant en ERC20 à déposer.
    /// @param supplier Adresse du fournisseur/prestataire.
    /// @param artwork_conditions Conditions/brief de l'œuvre (ex: IPFS).
    /// @param ip_license Détails de licence IP.
    /// @return order_id Identifiant unique de la commande.
    function create_order(
        uint256 amount,
        address supplier,
        string memory artwork_conditions,
        string memory ip_license
    )
        external
        returns (uint256 order_id)
    {
        unchecked {
            order_id = ++order_count; // commence à 1
        }

        address caller = msg.sender;

        orders_creator[order_id] = caller;
        orders_supplier[order_id] = supplier;
        orders_amount[order_id] = amount;
        orders_artwork_conditions[order_id] = artwork_conditions;
        orders_ip_license[order_id] = ip_license;
        order_states[order_id] = STATE_NOT_PAID;

        emit OrderCreated(order_id, caller, supplier, amount, artwork_conditions, ip_license);
    }

    /// @notice Dépose les fonds pour une commande (transferFrom vers ce contrat).
    /// @dev L’appelant doit avoir `balanceOf >= amount` et avoir approuvé `amount`.
    /// @param order_id Identifiant de la commande.
    function pay_order(uint256 order_id) external {
        require(order_states[order_id] == STATE_NOT_PAID, "Order is not payable");

        uint256 amount = orders_amount[order_id];
        address caller = msg.sender;

        _validate(caller, amount);

        bool ok = token.transferFrom(caller, address(this), amount);
        require(ok, "ERC20_TRANSFER_FAILED");

        order_states[order_id] = STATE_PAID;

        emit OrderPaid(order_id, caller, amount);
    }

    /// @notice Termine la commande (transfert des fonds au fournisseur).
    /// @dev Seul le créateur peut valider la complétion quand l’état est Paid.
    /// @param order_id Identifiant de la commande.
    function complete_order(uint256 order_id) external {
        require(order_states[order_id] == STATE_PAID, "Order is not paid");

        address caller = msg.sender;
        address creator = orders_creator[order_id];
        require(caller == creator, "Only order creator can complete");

        uint256 amount = orders_amount[order_id];
        address supplier = orders_supplier[order_id];

        bool ok = token.transfer(supplier, amount);
        require(ok, "ERC20_TRANSFER_FAILED");

        order_states[order_id] = STATE_COMPLETED;

        emit OrderCompleted(order_id, supplier, amount);
    }

    /// @notice Annule une commande (possible uniquement si NotPaid).
    /// @dev Seul le créateur peut annuler.
    /// @param order_id Identifiant de la commande.
    function cancel_order(uint256 order_id) external {
        require(order_states[order_id] == STATE_NOT_PAID, "Cant cancel paid/completed one");

        address caller = msg.sender;
        address creator = orders_creator[order_id];
        require(caller == creator, "Only order creator can cancel");

        order_states[order_id] = STATE_CANCELLED;
        emit OrderCancelled(order_id);
    }

    /// @notice Détails d’une commande.
    /// @param order_id ID de la commande.
    /// @return creator Créateur de la commande.
    /// @return supplier Fournisseur destinataire.
    /// @return amount Montant déposé.
    /// @return state État courant (NotPaid/Paid/Completed/Cancelled) encodé en bytes32.
    /// @return artwork_conditions Conditions de l’œuvre.
    /// @return ip_license Détails de licence IP.
    function get_order_details(uint256 order_id)
        external
        view
        returns (
            address creator,
            address supplier,
            uint256 amount,
            bytes32 state,
            string memory artwork_conditions,
            string memory ip_license
        )
    {
        creator = orders_creator[order_id];
        supplier = orders_supplier[order_id];
        amount = orders_amount[order_id];
        state = order_states[order_id];
        artwork_conditions = orders_artwork_conditions[order_id];
        ip_license = orders_ip_license[order_id];
    }

    /*//////////////////////////////////////////////////////////////
                           FONCTIONS INTERNES
    //////////////////////////////////////////////////////////////*/

    /// @dev Vérifie que `buyer` a assez de balance (même logique que Cairo).
    /// @param buyer Adresse de l’acheteur.
    /// @param amount Montant requis.
    function _validate(address buyer, uint256 amount) internal view {
        require(token.balanceOf(buyer) >= amount, "ERC20_NOT_SUFFICIENT_AMOUNT");
        // NB: l’allowance est vérifiée par transferFrom.
    }
}
