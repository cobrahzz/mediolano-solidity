// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * PublicProfileMarketplace — port Solidity du contrat Cairo "PublicProfileMarketPlace".
 *
 * Points clés :
 * - Chaque vendeur possède un profil public + des infos privées (tél, email privé).
 * - Un vendeur ne peut créer qu'un seul profil (détecté via isRegistered).
 * - Seul le vendeur peut mettre à jour son profil et lire ses infos privées.
 * - Liens sociaux (platform, link) stockés par sellerId et consultables.
 * - sellerId démarre à (initialCount + 1) lors de la première création.
 *
 * NB: En Solidity, msg.sender n'est jamais l'adresse 0, mais on garde la vérif pour parité.
 */
contract PublicProfileMarketplace {
    // -----------------------------
    // Types
    // -----------------------------

    struct SellerPrivateInfo {
        address seller_address;
        string  phone_number;
        string  private_email;
    }

    struct SellerPublicProfile {
        address seller_address;
        string  seller_name;         // (felt252 -> string)
        string  store_name;          // (felt252 -> string)
        string  store_address;       // (ByteArray -> string)
        string  institutional_bio;   // (ByteArray -> string)
        string  business_email;      // (felt252 -> string)
    }

    struct SocialLink {
        string platform; // ex: "twitter", "linkedin"
        string link;     // ex: "https://twitter.com/xxx"
    }

    // -----------------------------
    // Storage
    // -----------------------------

    address public owner;

    // sellerId => données
    mapping(uint64 => SellerPublicProfile) private _publicProfiles;
    mapping(uint64 => SellerPrivateInfo)  private _privateInfos;

    // sellerId => liens sociaux
    mapping(uint64 => SocialLink[]) private _socialLinks;

    // gestion des vendeurs
    uint64 public sellerCount;               // nombre total de sellers
    address[] public registeredUsers;        // pour itération si besoin
    mapping(address => bool) public isRegistered;
    mapping(address => uint64) public sellerIdOf; // lookup rapide de l'id

    // -----------------------------
    // Events
    // -----------------------------

    event ProfileCreated(uint64 indexed seller_id, address indexed seller_address);
    event ProfileUpdated(uint64 indexed seller_id, address indexed seller_address);
    event SocialLinkAdded(
        uint64 indexed seller_id,
        address indexed seller_address,
        string platform,
        string link
    );

    // -----------------------------
    // Constructor
    // -----------------------------

    /**
     * @param initialSellerCount valeur initiale pour sellerCount (garde parité avec Cairo)
     * @param owner_ adresse d'initialisation stockée (non utilisée pour les autorisations ici)
     */
    constructor(uint64 initialSellerCount, address owner_) {
        owner = owner_;
        sellerCount = initialSellerCount;
    }

    // -----------------------------
    // Core (équivalents des fonctions Cairo)
    // -----------------------------

    /**
     * Crée un profil vendeur (public + privé). Un seul profil par adresse.
     * Retourne true si créé, false si l'adresse a déjà un profil.
     */
    function create_seller_profile(
        string calldata seller_name,
        string calldata store_name,
        string calldata store_address,
        string calldata institutional_bio,
        string calldata business_email,
        string calldata phone_number,
        string calldata private_email
    ) external returns (bool) {
        require(msg.sender != address(0), "Zero Address Caller");

        if (isRegistered[msg.sender]) {
            return false;
        }

        // nouveau sellerId
        uint64 seller_id = sellerCount + 1;

        // enregistrement
        _publicProfiles[seller_id] = SellerPublicProfile({
            seller_address: msg.sender,
            seller_name: seller_name,
            store_name: store_name,
            store_address: store_address,
            institutional_bio: institutional_bio,
            business_email: business_email
        });

        _privateInfos[seller_id] = SellerPrivateInfo({
            seller_address: msg.sender,
            phone_number: phone_number,
            private_email: private_email
        });

        // indexation
        sellerCount = seller_id;
        registeredUsers.push(msg.sender);
        isRegistered[msg.sender] = true;
        sellerIdOf[msg.sender] = seller_id;

        emit ProfileCreated(seller_id, msg.sender);
        return true;
    }

    /**
     * Mise à jour d'un profil (seulement par son propriétaire).
     * Retourne true en cas de succès, false si l'adresse n'est pas enregistrée.
     */
    function update_profile(
        uint64 seller_id,
        string calldata seller_name,
        string calldata store_name,
        string calldata store_address,
        string calldata institutional_bio,
        string calldata business_email,
        string calldata phone_number,
        string calldata private_email
    ) external returns (bool) {
        require(msg.sender != address(0), "Zero Address Caller");

        if (!isRegistered[msg.sender]) {
            return false;
        }

        SellerPublicProfile memory oldPub = _publicProfiles[seller_id];
        require(oldPub.seller_address != address(0), "Seller not found");
        require(oldPub.seller_address == msg.sender, "Unauthorized caller");

        // update public
        _publicProfiles[seller_id] = SellerPublicProfile({
            seller_address: oldPub.seller_address,
            seller_name: seller_name,
            store_name: store_name,
            store_address: store_address,
            institutional_bio: institutional_bio,
            business_email: business_email
        });

        // update private
        SellerPrivateInfo memory oldPriv = _privateInfos[seller_id];
        _privateInfos[seller_id] = SellerPrivateInfo({
            seller_address: oldPriv.seller_address,
            phone_number: phone_number,
            private_email: private_email
        });

        emit ProfileUpdated(seller_id, msg.sender);
        return true;
    }

    // ---- Views ----

    function get_seller_count() external view returns (uint64) {
        return sellerCount;
    }

    /**
     * Retourne tous les profils publics (1..sellerCount).
     * Attention: renvoyer des arrays de structs avec string est coûteux en gas (view OK).
     */
    function get_all_sellers() external view returns (SellerPublicProfile[] memory out) {
        out = new SellerPublicProfile[](sellerCount);
        for (uint64 i = 1; i <= sellerCount; i++) {
            out[i - 1] = _publicProfiles[i];
        }
    }

    function get_specific_seller(uint64 seller_id)
        external
        view
        returns (SellerPublicProfile memory)
    {
        SellerPublicProfile memory p = _publicProfiles[seller_id];
        require(p.seller_address != address(0), "Seller not found");
        return p;
    }

    /**
     * Retourne les infos privées (seul le vendeur concerné peut y accéder).
     */
    function get_private_info(uint64 seller_id)
        external
        view
        returns (SellerPrivateInfo memory)
    {
        SellerPublicProfile memory p = _publicProfiles[seller_id];
        require(p.seller_address != address(0), "Seller not found");
        require(msg.sender == p.seller_address, "Unauthorized Caller");
        return _privateInfos[seller_id];
    }

    // ---- Social links ----

    function add_social_link(
        uint64 seller_id,
        string calldata link,
        string calldata platform
    ) external {
        SellerPublicProfile memory p = _publicProfiles[seller_id];
        require(p.seller_address != address(0), "Seller not found");
        require(msg.sender != address(0), "Zero Address Caller");
        require(msg.sender == p.seller_address, "Unauthorized Caller");

        _socialLinks[seller_id].push(SocialLink({ platform: platform, link: link }));

        emit SocialLinkAdded(seller_id, msg.sender, platform, link);
    }

    function get_social_links(uint64 seller_id)
        external
        view
        returns (SocialLink[] memory)
    {
        require(msg.sender != address(0), "Zero Address Caller");
        return _socialLinks[seller_id];
    }

    // -----------------------------
    // Helpers (optionnels)
    // -----------------------------

    function isSeller(address account) external view returns (bool) {
        return isRegistered[account];
    }

    function registeredUsersLength() external view returns (uint256) {
        return registeredUsers.length;
    }
}
