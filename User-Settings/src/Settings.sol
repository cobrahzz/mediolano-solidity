// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// EncryptedPreferencesRegistry — Port Cairo → Solidity en un seul fichier
/// Mappings, structs, events, contrôles d’accès et logique de timestamps/“optionnels”
/// Notes:
/// - Option<T> Cairo émulé par sentinelles:
///   * NONE_U256 pour uint256 (felt252)
///   * NONE_U8 pour uint8
///   * TriBool pour Option<bool> : 0=false, 1=true, 2=none
/// - Hash Poseidon → keccak256 (même rôle utilitaire)

interface IEncryptedPreferencesRegistry {
    // write
    function store_account_details(
        uint256 name,
        uint256 email,
        uint256 username,
        uint64 timestamp
    ) external;

    function update_account_details(
        uint256 nameOrNone,     // NONE_U256 => None
        uint256 emailOrNone,    // NONE_U256 => None
        uint256 usernameOrNone, // NONE_U256 => None
        uint64 timestamp
    ) external;

    function store_ip_management_settings(
        uint8 protection_level,         // 0 or 1
        bool automatic_ip_registration,
        uint64 timestamp
    ) external;

    function update_ip_management_settings(
        uint8 protection_levelOrNone,     // NONE_U8 => None
        uint8 automatic_ip_registration3, // TriBool: 0=false, 1=true, 2=none
        uint64 timestamp
    ) external;

    function store_notification_settings(
        bool enable_notifications,
        bool ip_updates,
        bool blockchain_events,
        bool account_activity,
        uint64 timestamp
    ) external;

    function update_notification_settings(
        uint8 enable_notifications3, // TriBool
        uint8 ip_updates3,           // TriBool
        uint8 blockchain_events3,    // TriBool
        uint8 account_activity3,     // TriBool
        uint64 timestamp
    ) external;

    function store_security_settings(
        uint256 password, // à hacher coté contrat
        uint64 timestamp
    ) external;

    function update_security_settings(
        uint256 password,
        uint64 timestamp
    ) external;

    function store_network_settings(
        uint8 network_type,         // 0 TESTNET, 1 MAINNET
        uint8 gas_price_preference, // 0 LOW, 1 MEDIUM, 2 HIGH
        uint64 timestamp
    ) external;

    function update_network_settings(
        uint8 network_typeOrNone,         // NONE_U8 => None
        uint8 gas_price_preferenceOrNone, // NONE_U8 => None
        uint64 timestamp
    ) external;

    function store_advanced_settings(
        uint256 api_key,
        uint64 timestamp
    ) external;

    function store_X_verification(
        bool x_verified,
        uint64 timestamp,
        uint256 handler
    ) external;

    function regenerate_api_key(
        uint64 timestamp
    ) external returns (uint256);

    function delete_account(uint64 timestamp) external;

    // read
    function get_account_settings(address user) external view returns (uint256 name, uint256 email, uint256 username);
    function get_network_settings(address user) external view returns (uint8 network_type, uint8 gas_price_preference);
    function get_ip_settings(address user) external view returns (uint8 ip_protection_level, bool automatic_ip_registration);
    function get_notification_settings(address user) external view returns (bool enabled, bool ip_updates, bool blockchain_events, bool account_activity);
    function get_security_settings(address user) external view returns (bool two_factor_authentication, uint256 password);
    function get_advanced_settings(address user) external view returns (uint256 api_key, uint64 data_retention);
    function get_social_verification(address user) external view returns (
        bool x_is_verified, uint256 x_handler, address x_user_address,
        bool fb_is_verified, uint256 fb_handler, address fb_user_address
    );

    // upgrade (mimique)
    function upgrade(address newImplementation) external;
}

contract EncryptedPreferencesRegistry is IEncryptedPreferencesRegistry {
    /*//////////////////////////////////////////////////////////////
                                Types
    //////////////////////////////////////////////////////////////*/

    // Option<bool> tri-state
    uint8 private constant TRIBOOL_FALSE = 0;
    uint8 private constant TRIBOOL_TRUE  = 1;
    uint8 private constant TRIBOOL_NONE  = 2;

    // Sentinelles pour Option<T>
    uint256 private constant NONE_U256 = type(uint256).max;
    uint8   private constant NONE_U8   = type(uint8).max;

    // Constantes
    uint256 private constant SUPPORTED_VERSION = 1;
    uint64  private constant TIME_WINDOW = 300; // 5 minutes

    // Enums
    enum IPProtectionLevel { STANDARD, ADVANCED }
    enum NetworkType { TESTNET, MAINNET }
    enum GasPricePreference { LOW, MEDIUM, HIGH }

    // Structs de settings (felt252 → uint256)
    struct AccountSetting {
        uint256 name;
        uint256 email;
        uint256 username;
    }

    struct IPSettings {
        IPProtectionLevel ip_protection_level;
        bool automatic_ip_registration;
    }

    struct NotificationSettings {
        bool enabled;
        bool ip_updates;
        bool blockchain_events;
        bool account_activity;
    }

    struct Security {
        bool two_factor_authentication;
        uint256 password; // hashed value
    }

    struct NetworkSettings {
        NetworkType network_type;
        GasPricePreference gas_price_preference;
    }

    struct AdvancedSettings {
        uint256 api_key;       // hashed/stored
        uint64 data_retention; // jours
    }

    struct XVerification {
        bool is_verified;
        uint256 handler;
        address user_address;
    }

    struct FacebookVerification {
        bool is_verified;
        uint256 handler;
        address user_address;
    }

    struct SocialVerification {
        XVerification x_verification_status;
        FacebookVerification facebook_verification_status;
    }

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event SettingUpdated(address indexed user, uint256 setting_type, uint64 timestamp);
    event SettingRemoved(address indexed user, uint256 setting_type, uint64 timestamp);
    event WalletKeyUpdated(address indexed user, uint256 pub_key, uint256 version, uint64 timestamp);
    event SocialVerificationUpdated(address indexed user, bool x_verified, uint64 timestamp);
    event AccountDeleted(address indexed user, uint256 setting, uint64 timestamp);

    // Mimique “Upgradeable”
    event Upgraded(address indexed newImplementation);

    /*//////////////////////////////////////////////////////////////
                                Ownership
    //////////////////////////////////////////////////////////////*/

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    mapping(address => bool) public authorized_apps;
    address public mediolano_app;

    mapping(address => AccountSetting) private users_account_settings;
    mapping(address => IPSettings) private users_ip_settings;
    mapping(address => NotificationSettings) private users_notification_settings;
    mapping(address => Security) private users_security_settings;
    mapping(address => NetworkSettings) private users_network_settings;
    mapping(address => AdvancedSettings) private users_advanced_settings;
    mapping(address => SocialVerification) private users_social_verification;

    mapping(address => uint64) private users_last_updated;

    // “Upgradeable” target (mimique)
    address public implementationTarget;

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _mediolano_app) {
        owner = _owner;
        mediolano_app = _mediolano_app;

        // Autorisations initiales
        authorized_apps[_owner] = true;
        authorized_apps[_mediolano_app] = true;
    }

    /*//////////////////////////////////////////////////////////////
                           Internal helpers
    //////////////////////////////////////////////////////////////*/

    function _assertAuthorized(address caller) internal view {
        require(authorized_apps[caller], "Unauthorized caller");
    }

    function _verify_settings_update(address caller, uint64 timestamp) internal {
        uint64 nowTs = uint64(block.timestamp);
        require(
            timestamp <= nowTs + TIME_WINDOW && timestamp + TIME_WINDOW >= nowTs,
            "Invalid timestamp"
        );
        users_last_updated[caller] = timestamp;
    }

    // ---- Hash helpers (Poseidon → keccak256) ----

    function hash_account_details(uint256 name, uint256 email, uint256 username, uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(name, email, username, timestamp)));
    }

    function hash_ip_settings(uint8 protection_level, bool automatic_ip_registration, uint64 timestamp) public pure returns (uint256) {
        require(protection_level == 0 || protection_level == 1, "Invalid Protection Level");
        return uint256(keccak256(abi.encodePacked(protection_level, automatic_ip_registration, timestamp)));
    }

    function hash_notification_settings(bool enable_notifications, bool ip_updates, bool blockchain_events, bool account_activity, uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(enable_notifications, ip_updates, blockchain_events, account_activity, timestamp)));
    }

    function hash_security_settings(uint256 password, uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(password, timestamp)));
    }

    function hash_network_settings(uint8 network_type, uint8 gas_price_preference, uint64 timestamp) public pure returns (uint256) {
        require(network_type == 0 || network_type == 1, "Invalid Network Type");
        require(gas_price_preference <= 2, "Invalid Gas Price Preference");
        return uint256(keccak256(abi.encodePacked(network_type, gas_price_preference, timestamp)));
    }

    function hash_advanced_settings(uint256 api_key, uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(api_key, timestamp)));
    }

    function hash_social_verification(bool x_verified, uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(x_verified, timestamp)));
    }

    function hash_wallet_update(uint256 new_pub_key, uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(new_pub_key, timestamp)));
    }

    function hash_api_key_regeneration(uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint256(keccak256("regenerate_api")), timestamp)));
    }

    function hash_account_deletion(uint64 timestamp) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint256(keccak256("delete_account")), timestamp)));
    }

    // ---- Enum <-> u8 helpers ----

    function _toU8(NetworkType n) internal pure returns (uint8) {
        return n == NetworkType.TESTNET ? 0 : 1;
    }

    function _fromU8_NetworkType(uint8 v) internal pure returns (NetworkType) {
        require(v == 0 || v == 1, "Invalid NetworkType");
        return v == 0 ? NetworkType.TESTNET : NetworkType.MAINNET;
    }

    function _toU8(GasPricePreference g) internal pure returns (uint8) {
        if (g == GasPricePreference.LOW) return 0;
        if (g == GasPricePreference.MEDIUM) return 1;
        return 2; // HIGH
    }

    function _fromU8_Gas(uint8 v) internal pure returns (GasPricePreference) {
        require(v <= 2, "Invalid Gas");
        if (v == 0) return GasPricePreference.LOW;
        if (v == 1) return GasPricePreference.MEDIUM;
        return GasPricePreference.HIGH;
    }

    function _toU8(IPProtectionLevel p) internal pure returns (uint8) {
        return p == IPProtectionLevel.STANDARD ? 0 : 1;
    }

    function _fromU8_IP(uint8 v) internal pure returns (IPProtectionLevel) {
        require(v == 0 || v == 1, "Invalid IPL");
        return v == 0 ? IPProtectionLevel.STANDARD : IPProtectionLevel.ADVANCED;
    }

    function _applyTriBool(bool current, uint8 tri) internal pure returns (bool) {
        if (tri == TRIBOOL_NONE) return current;
        require(tri == 0 || tri == 1, "Invalid tri-bool");
        return tri == TRIBOOL_TRUE;
    }

    /*//////////////////////////////////////////////////////////////
                        External (write) — owner/authz
    //////////////////////////////////////////////////////////////*/

    function store_account_details(
        uint256 name,
        uint256 email,
        uint256 username,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);
        _verify_settings_update(caller, timestamp);

        users_account_settings[caller] = AccountSetting(name, email, username);
        emit SettingUpdated(caller, uint256(keccak256("account_details")), uint64(block.timestamp));
    }

    function update_account_details(
        uint256 nameOrNone,
        uint256 emailOrNone,
        uint256 usernameOrNone,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        AccountSetting memory cur = users_account_settings[caller];

        uint256 newName = (nameOrNone == NONE_U256) ? cur.name : nameOrNone;
        uint256 newEmail = (emailOrNone == NONE_U256) ? cur.email : emailOrNone;
        uint256 newUser = (usernameOrNone == NONE_U256) ? cur.username : usernameOrNone;

        _verify_settings_update(caller, timestamp);

        users_account_settings[caller] = AccountSetting(newName, newEmail, newUser);
        emit SettingUpdated(caller, uint256(keccak256("account_details")), uint64(block.timestamp));
    }

    function store_ip_management_settings(
        uint8 protection_level,
        bool automatic_ip_registration,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);
        require(protection_level == 0 || protection_level == 1, "Invalid Protection Level");

        _verify_settings_update(caller, timestamp);

        users_ip_settings[caller] = IPSettings(_fromU8_IP(protection_level), automatic_ip_registration);
        emit SettingUpdated(caller, uint256(keccak256("ip_settings")), uint64(block.timestamp));
    }

    function update_ip_management_settings(
        uint8 protection_levelOrNone,
        uint8 automatic_ip_registration3,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        IPSettings memory cur = users_ip_settings[caller];

        IPProtectionLevel newLevel = cur.ip_protection_level;
        if (protection_levelOrNone != NONE_U8) {
            require(protection_levelOrNone == 0 || protection_levelOrNone == 1, "Invalid Protection Level");
            newLevel = _fromU8_IP(protection_levelOrNone);
        }

        bool newAuto = _applyTriBool(cur.automatic_ip_registration, automatic_ip_registration3);

        _verify_settings_update(caller, timestamp);

        users_ip_settings[caller] = IPSettings(newLevel, newAuto);
        emit SettingUpdated(caller, uint256(keccak256("ip_settings")), uint64(block.timestamp));
    }

    function store_notification_settings(
        bool enable_notifications,
        bool ip_updates,
        bool blockchain_events,
        bool account_activity,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);
        _verify_settings_update(caller, timestamp);

        users_notification_settings[caller] = NotificationSettings(
            enable_notifications, ip_updates, blockchain_events, account_activity
        );
        emit SettingUpdated(caller, uint256(keccak256("notification_settings")), uint64(block.timestamp));
    }

    function update_notification_settings(
        uint8 enable_notifications3,
        uint8 ip_updates3,
        uint8 blockchain_events3,
        uint8 account_activity3,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        NotificationSettings memory cur = users_notification_settings[caller];

        bool newEnabled = _applyTriBool(cur.enabled, enable_notifications3);
        bool newIpUpd   = _applyTriBool(cur.ip_updates, ip_updates3);
        bool newChain   = _applyTriBool(cur.blockchain_events, blockchain_events3);
        bool newAct     = _applyTriBool(cur.account_activity, account_activity3);

        _verify_settings_update(caller, timestamp);

        users_notification_settings[caller] = NotificationSettings(newEnabled, newIpUpd, newChain, newAct);
        emit SettingUpdated(caller, uint256(keccak256("notification_settings")), uint64(block.timestamp));
    }

    function store_security_settings(
        uint256 password,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        // Hash (Cairo Poseidon → keccak)
        uint256 hashed = uint256(keccak256(abi.encodePacked(password, timestamp, caller)));

        _verify_settings_update(caller, timestamp);

        users_security_settings[caller] = Security(false, hashed);
        emit SettingUpdated(caller, uint256(keccak256("security_settings")), uint64(block.timestamp));
    }

    function update_security_settings(
        uint256 password,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        _verify_settings_update(caller, timestamp);

        Security memory cur = users_security_settings[caller];
        uint256 hashed = uint256(keccak256(abi.encodePacked(password, caller)));
        users_security_settings[caller] = Security(cur.two_factor_authentication, hashed);

        emit SettingUpdated(caller, uint256(keccak256("security_settings")), uint64(block.timestamp));
    }

    function store_network_settings(
        uint8 network_type,
        uint8 gas_price_preference,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);
        require(network_type <= 1, "Invalid Network Type");
        require(gas_price_preference <= 2, "Invalid Gas Price Preference");

        _verify_settings_update(caller, timestamp);

        users_network_settings[caller] =
            NetworkSettings(_fromU8_NetworkType(network_type), _fromU8_Gas(gas_price_preference));

        emit SettingUpdated(caller, uint256(keccak256("network_settings")), uint64(block.timestamp));
    }

    function update_network_settings(
        uint8 network_typeOrNone,
        uint8 gas_price_preferenceOrNone,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        NetworkSettings memory cur = users_network_settings[caller];

        NetworkType ntype = cur.network_type;
        if (network_typeOrNone != NONE_U8) {
            require(network_typeOrNone <= 1, "Invalid Network Type");
            ntype = _fromU8_NetworkType(network_typeOrNone);
        }

        GasPricePreference gpp = cur.gas_price_preference;
        if (gas_price_preferenceOrNone != NONE_U8) {
            require(gas_price_preferenceOrNone <= 2, "Invalid Gas");
            gpp = _fromU8_Gas(gas_price_preferenceOrNone);
        }

        _verify_settings_update(caller, timestamp);

        users_network_settings[caller] = NetworkSettings(ntype, gpp);
        emit SettingUpdated(caller, uint256(keccak256("network_settings")), uint64(block.timestamp));
    }

    function store_advanced_settings(
        uint256 api_key,
        uint64 timestamp
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        _verify_settings_update(caller, timestamp);

        AdvancedSettings memory cur = users_advanced_settings[caller];
        users_advanced_settings[caller] = AdvancedSettings(api_key, cur.data_retention);

        emit SettingUpdated(caller, uint256(keccak256("advanced_settings")), uint64(block.timestamp));
    }

    function store_X_verification(
        bool x_verified,
        uint64 timestamp,
        uint256 handler
    ) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        _verify_settings_update(caller, timestamp);

        SocialVerification memory cur = users_social_verification[caller];

        // NB: Cairo set is_verified := true quoiqu'on passe; on reproduit le comportement.
        XVerification memory xv = XVerification(true, handler, caller);

        users_social_verification[caller] = SocialVerification(
            xv,
            cur.facebook_verification_status
        );

        emit SocialVerificationUpdated(caller, x_verified, uint64(block.timestamp));
    }

    function regenerate_api_key(
        uint64 timestamp
    ) external override returns (uint256) {
        address caller = msg.sender;
        _assertAuthorized(caller);

        _verify_settings_update(caller, timestamp);

        AdvancedSettings memory cur = users_advanced_settings[caller];
        // Nouveau API key = keccak(caller, timestamp, ancien api_key)
        uint256 newKey = uint256(keccak256(abi.encodePacked(caller, timestamp, cur.api_key)));
        cur.api_key = newKey;
        users_advanced_settings[caller] = cur;

        emit SettingUpdated(caller, uint256(keccak256("advanced_settings")), uint64(block.timestamp));
        return newKey;
    }

    function delete_account(uint64 timestamp) external override {
        address caller = msg.sender;
        _assertAuthorized(caller);

        _verify_settings_update(caller, timestamp);

        // reset “par défaut” (zéros)
        delete users_account_settings[caller];
        delete users_notification_settings[caller];
        delete users_ip_settings[caller];
        delete users_security_settings[caller];
        delete users_advanced_settings[caller];
        delete users_network_settings[caller];

        XVerification memory xv = XVerification(false, 0, address(0));
        FacebookVerification memory fbv = FacebookVerification(false, 0, address(0));
        users_social_verification[caller] = SocialVerification(xv, fbv);

        emit AccountDeleted(caller, uint256(keccak256("account_deleted")), uint64(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                               External (read)
    //////////////////////////////////////////////////////////////*/

    function get_account_settings(address user) external view override returns (uint256, uint256, uint256) {
        AccountSetting memory s = users_account_settings[user];
        return (s.name, s.email, s.username);
    }

    function get_network_settings(address user) external view override returns (uint8, uint8) {
        NetworkSettings memory s = users_network_settings[user];
        return (_toU8(s.network_type), _toU8(s.gas_price_preference));
    }

    function get_ip_settings(address user) external view override returns (uint8, bool) {
        IPSettings memory s = users_ip_settings[user];
        return (_toU8(s.ip_protection_level), s.automatic_ip_registration);
    }

    function get_notification_settings(address user) external view override returns (bool, bool, bool, bool) {
        NotificationSettings memory s = users_notification_settings[user];
        return (s.enabled, s.ip_updates, s.blockchain_events, s.account_activity);
    }

    function get_security_settings(address user) external view override returns (bool, uint256) {
        Security memory s = users_security_settings[user];
        return (s.two_factor_authentication, s.password);
    }

    function get_advanced_settings(address user) external view override returns (uint256, uint64) {
        AdvancedSettings memory s = users_advanced_settings[user];
        return (s.api_key, s.data_retention);
    }

    function get_social_verification(address user) external view override returns (
        bool, uint256, address,
        bool, uint256, address
    ) {
        SocialVerification memory sv = users_social_verification[user];
        return (
            sv.x_verification_status.is_verified,
            sv.x_verification_status.handler,
            sv.x_verification_status.user_address,
            sv.facebook_verification_status.is_verified,
            sv.facebook_verification_status.handler,
            sv.facebook_verification_status.user_address
        );
    }

    /*//////////////////////////////////////////////////////////////
                               Upgrade (mimique)
    //////////////////////////////////////////////////////////////*/

    function upgrade(address newImplementation) external override onlyOwner {
        implementationTarget = newImplementation;
        emit Upgraded(newImplementation);
    }
}
