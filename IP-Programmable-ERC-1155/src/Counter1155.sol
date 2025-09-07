// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Port fidèle du contrat Cairo fourni :
 * - Noms des fonctions inchangés (snake_case).
 * - Même logique "batch_mint" réutilisée pour les transferts.
 * - owned_tokens_count/list mis à jour EXACTEMENT comme dans le Cairo :
 *   * on décrémente le compteur du `from` d'UNE unité par item transféré (même pour un transfer partiel),
 *   * on incrémente le compteur du `to` et on *append* le tokenId à sa liste (doublons possibles).
 * - Pas d’ERC1155Receiver ni de URI par ID avancée : fidèle au code.
 */
contract ERC1155CairoPort {
    /* -------------------------------- Events ------------------------------- */
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 token_id, uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] token_ids, uint256[] values);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /* -------------------------------- Storage ------------------------------ */
    // balances[token_id][account] => amount
    mapping(uint256 => mapping(address => uint256)) public ERC1155_balances;

    // approvals[owner][operator]
    mapping(address => mapping(address => bool)) public ERC1155_operator_approvals;

    // simple URI & license par token
    mapping(uint256 => string) public ERC1155_uri;
    mapping(uint256 => string) public ERC1155_licenses;

    // "énumération" propriétaire (fidèle au Cairo)
    mapping(address => uint256) public ERC1155_owned_tokens;                    // count
    mapping(address => mapping(uint256 => uint256)) public ERC1155_owned_tokens_list; // (owner, idx) -> tokenId

    address public owner;

    /* ------------------------------ Constructor ---------------------------- */
    constructor(
        string memory token_uri,
        address recipient,
        uint256[] memory token_ids,
        uint256[] memory values
    ) {
        owner = msg.sender;

        require(token_ids.length == values.length, "Arrays length mismatch");
        require(recipient != address(0), "Invalid recipient");

        // Init URI pour chaque token passé
        for (uint256 i = 0; i < token_ids.length; i++) {
            ERC1155_uri[token_ids[i]] = token_uri;
        }

        // Mint initial au recipient (from = 0x0) via la même routine que les transferts
        _batch_mint(address(0), recipient, token_ids, values, "");
    }

    /* ------------------------------- Interface ----------------------------- */
    function balance_of(address account, uint256 token_id) external view returns (uint256) {
        return ERC1155_balances[token_id][account];
    }

    function balance_of_batch(address[] calldata accounts, uint256[] calldata token_ids)
        external
        view
        returns (uint256[] memory)
    {
        require(accounts.length == token_ids.length, "Arrays length mismatch");
        uint256[] memory result = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            result[i] = ERC1155_balances[token_ids[i]][accounts[i]];
        }
        return result;
    }

    function is_approved_for_all(address _owner, address operator) external view returns (bool) {
        return ERC1155_operator_approvals[_owner][operator];
    }

    function uri(uint256 token_id) external view returns (string memory) {
        return ERC1155_uri[token_id];
    }

    function get_license(uint256 token_id) external view returns (string memory) {
        return ERC1155_licenses[token_id];
    }

    function set_approval_for_all(address operator, bool approved) external {
        require(operator != address(0), "Invalid operator");
        address _owner = msg.sender;
        require(_owner != operator, "Self approval");

        ERC1155_operator_approvals[_owner][operator] = approved;
        emit ApprovalForAll(_owner, operator, approved);
    }

    function safe_transfer_from(
        address from,
        address to,
        uint256 token_id,
        uint256 value,
        bytes calldata data
    ) external {
        require(to != address(0), "Invalid recipient");
        address caller = msg.sender;
        require(caller == from || ERC1155_operator_approvals[from][caller], "Not authorized");

        uint256;
        uint256;
        ids[0] = token_id;
        vals[0] = value;

        _batch_mint(from, to, ids, vals, data);
        emit TransferSingle(caller, from, to, token_id, value);
    }

    function safe_batch_transfer_from(
        address from,
        address to,
        uint256[] calldata token_ids,
        uint256[] calldata values,
        bytes calldata data
    ) external {
        require(token_ids.length == values.length, "Arrays length mismatch");
        require(to != address(0), "Invalid recipient");

        address caller = msg.sender;
        require(caller == from || ERC1155_operator_approvals[from][caller], "Not authorized");

        _batch_mint(from, to, token_ids, values, data);
        emit TransferBatch(caller, from, to, token_ids, values);
    }

    function list_tokens(address _owner) external view returns (uint256[] memory) {
        uint256 count = ERC1155_owned_tokens[_owner];
        uint256[] memory tokens = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokens[i] = ERC1155_owned_tokens_list[_owner][i];
        }
        return tokens;
    }

    /* --------------------------- Internal routine ------------------------- */
    // Réplique exacte de la logique Cairo:
    //  - si from != 0x0 : vérifie le solde, débite, puis DECREMENTE owned_tokens[from] d'1 (jamais < 0)
    //  - crédite to, INCREMENTE owned_tokens[to] d'1, et push tokenId dans sa liste (doublons possibles)
    function _batch_mint(
        address from,
        address to,
        uint256[] memory token_ids,
        uint256[] memory values,
        bytes memory /*data*/
    ) internal {
        for (uint256 i = 0; i < token_ids.length; i++) {
            uint256 id = token_ids[i];
            uint256 val = values[i];

            if (from != address(0)) {
                uint256 fb = ERC1155_balances[id][from];
                require(fb >= val, "Insufficient balance");
                ERC1155_balances[id][from] = fb - val;

                uint256 fromCount = ERC1155_owned_tokens[from];
                if (fromCount > 0) {
                    ERC1155_owned_tokens[from] = fromCount - 1;
                }
                // NOTE: on ne nettoie pas la liste de `from`, fidèle au code Cairo
            }

            uint256 tb = ERC1155_balances[id][to];
            ERC1155_balances[id][to] = tb + val;

            uint256 toCount = ERC1155_owned_tokens[to];
            ERC1155_owned_tokens[to] = toCount + 1;
            ERC1155_owned_tokens_list[to][toCount] = id; // append (doublon possible)
        }
    }
}
