// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Port 1:1 du contrat Cairo "UserAchievements" vers Solidity (un seul fichier)

contract UserAchievements {
    /*//////////////////////////////////////////////////////////////
                               Types/Structs
    //////////////////////////////////////////////////////////////*/

    enum AchievementType {
        Mint,
        Sale,
        License,
        Transfer,
        Collection,
        Collaboration,
        Innovation,
        Community,
        Custom
    }

    enum ActivityType {
        AssetMinted,
        AssetSold,
        AssetLicensed,
        AssetTransferred,
        CollectionCreated,
        CollaborationJoined,
        InnovationAwarded,
        CommunityContribution,
        CustomActivity
    }

    enum BadgeType {
        Creator,
        Seller,
        Licensor,
        Collector,
        Innovator,
        CommunityLeader,
        EarlyAdopter,
        TopPerformer,
        CustomBadge
    }

    enum CertificateType {
        CreatorCertificate,
        SellerCertificate,
        LicensorCertificate,
        InnovationCertificate,
        CommunityCertificate,
        AchievementCertificate,
        CustomCertificate
    }

    struct Achievement {
        AchievementType achievement_type;
        uint64 timestamp;         // u64
        uint256 metadata_id;      // felt252
        uint256 asset_id;         // Option<felt252> -> 0 means None
        uint256 category;         // Option<felt252> -> 0 means None
        uint32 points;            // u32
    }

    struct Badge {
        BadgeType badge_type;
        uint64 timestamp;
        uint256 metadata_id;
        bool is_active;
    }

    struct Certificate {
        CertificateType certificate_type;
        uint64 timestamp;
        uint256 metadata_id;
        uint64 expiry_date; // Option<u64> -> 0 means None
        bool is_valid;
    }

    struct LeaderboardEntry {
        address user;
        uint32 total_points;
        uint32 achievements_count;
        uint32 badges_count;
        uint32 certificates_count;
    }

    /*//////////////////////////////////////////////////////////////
                                  Events
    //////////////////////////////////////////////////////////////*/

    event AchievementRecorded(address indexed user, AchievementType achievement_type, uint32 points, uint64 timestamp);
    event ActivityEventRecorded(address indexed user, ActivityType activity_type, uint64 timestamp);
    event BadgeMinted(address indexed user, BadgeType badge_type, uint64 timestamp);
    event CertificateMinted(address indexed user, CertificateType certificate_type, uint64 timestamp);
    event PointsUpdated(address indexed user, uint32 new_total, uint32 change);
    event LeaderboardUpdated(address user, uint32 new_rank, uint32 total_points);
    event OwnerChanged(address indexed old_owner, address indexed new_owner);

    /*//////////////////////////////////////////////////////////////
                                  Storage
    //////////////////////////////////////////////////////////////*/

    // Core data structures
    mapping(address => mapping(uint32 => Achievement)) private user_achievements; // (user, index) -> Achievement
    mapping(address => uint32) private user_activity_count;
    mapping(address => uint32) private user_total_points;

    mapping(address => mapping(uint32 => Badge)) private user_badges;
    mapping(address => mapping(uint32 => Certificate)) private user_certificates;
    mapping(address => uint32) private user_badge_count;
    mapping(address => uint32) private user_certificate_count;

    // Leaderboard tracking
    mapping(uint32 => LeaderboardEntry) private leaderboard_entries; // index -> entry
    uint32 private leaderboard_count;
    mapping(address => uint32) private user_rank; // 0 means "no rank yet", else rank (1-based)

    // Configuration
    mapping(uint8 => uint32) private activity_points; // activity_type_id -> points
    address private owner;

    // Statistics
    uint32 private total_users;
    uint32 private total_achievements;
    uint32 private total_badges_minted;
    uint32 private total_certificates_minted;

    /*//////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address owner_) {
        owner = owner_;

        // Default activity points (IDs dérivés de l'ordre de ActivityType)
        activity_points[uint8(ActivityType.AssetMinted)] = 10;
        activity_points[uint8(ActivityType.AssetSold)] = 25;
        activity_points[uint8(ActivityType.AssetLicensed)] = 20;
        activity_points[uint8(ActivityType.AssetTransferred)] = 5;
        activity_points[uint8(ActivityType.CollectionCreated)] = 15;
        activity_points[uint8(ActivityType.CollaborationJoined)] = 12;
        activity_points[uint8(ActivityType.InnovationAwarded)] = 50;
        activity_points[uint8(ActivityType.CommunityContribution)] = 8;
        activity_points[uint8(ActivityType.CustomActivity)] = 5;
    }

    /*//////////////////////////////////////////////////////////////
                           Modifiers / Internals
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call");
        _;
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _activity_type_to_id(ActivityType t) internal pure returns (uint8) {
        return uint8(t);
    }

    function _activity_to_achievement_type(ActivityType t) internal pure returns (AchievementType) {
        if (t == ActivityType.AssetMinted) return AchievementType.Mint;
        if (t == ActivityType.AssetSold) return AchievementType.Sale;
        if (t == ActivityType.AssetLicensed) return AchievementType.License;
        if (t == ActivityType.AssetTransferred) return AchievementType.Transfer;
        if (t == ActivityType.CollectionCreated) return AchievementType.Collection;
        if (t == ActivityType.CollaborationJoined) return AchievementType.Collaboration;
        if (t == ActivityType.InnovationAwarded) return AchievementType.Innovation;
        if (t == ActivityType.CommunityContribution) return AchievementType.Community;
        return AchievementType.Custom;
    }

    function _update_leaderboard(address user, uint32 new_points) internal {
        uint32 current_rank = user_rank[user];
        uint32 achCount = user_activity_count[user];
        uint32 badgeCount = user_badge_count[user];
        uint32 certCount = user_certificate_count[user];

        LeaderboardEntry memory entry = LeaderboardEntry({
            user: user,
            total_points: new_points,
            achievements_count: achCount,
            badges_count: badgeCount,
            certificates_count: certCount
        });

        if (current_rank == 0) {
            // new user → append
            uint32 idx = leaderboard_count; // 0-based index
            leaderboard_entries[idx] = entry;
            leaderboard_count = idx + 1;
            user_rank[user] = idx + 1; // rank is 1-based
            total_users += 1;
        } else {
            // update existing (rank-1 is index)
            leaderboard_entries[current_rank - 1] = entry;
        }

        emit LeaderboardUpdated(user, user_rank[user], new_points);
    }

    /*//////////////////////////////////////////////////////////////
                          Interface (mêmes noms)
    //////////////////////////////////////////////////////////////*/

    /// Only owner (Mediolano platform) can record achievements
    function record_achievement(
        address user,
        AchievementType achievement_type,
        uint256 metadata_id,
        uint256 asset_id,   // 0 = None, else Some(value)
        uint256 category,   // 0 = None, else Some(value)
        uint32 points
    ) external onlyOwner {
        uint64 timestamp = _now();
        uint32 idx = user_activity_count[user];

        Achievement memory a = Achievement({
            achievement_type: achievement_type,
            timestamp: timestamp,
            metadata_id: metadata_id,
            asset_id: asset_id,
            category: category,
            points: points
        });

        user_achievements[user][idx] = a;
        user_activity_count[user] = idx + 1;

        // points
        uint32 current = user_total_points[user];
        uint32 newPoints = current + points;
        user_total_points[user] = newPoints;

        // global stats
        total_achievements += 1;

        // leaderboard
        _update_leaderboard(user, newPoints);

        emit AchievementRecorded(user, achievement_type, points, timestamp);
        emit PointsUpdated(user, newPoints, points);
    }

    /// Only owner (Mediolano platform) can record activity events
    function record_activity_event(
        address user,
        ActivityType activity_type,
        uint256 metadata_id,
        uint256 asset_id,   // 0 = None
        uint256 category    // 0 = None
    ) external onlyOwner {
        uint64 timestamp = _now();

        uint8 id = _activity_type_to_id(activity_type);
        uint32 points = activity_points[id];

        AchievementType achType = _activity_to_achievement_type(activity_type);

        // enregistre comme achievement
        record_achievement(user, achType, metadata_id, asset_id, category, points);

        emit ActivityEventRecorded(user, activity_type, timestamp);
    }

    /// Only owner (Mediolano platform) can mint badges
    function mint_badge(
        address user,
        BadgeType badge_type,
        uint256 metadata_id
    ) external onlyOwner {
        uint64 timestamp = _now();
        uint32 idx = user_badge_count[user];

        Badge memory b = Badge({
            badge_type: badge_type,
            timestamp: timestamp,
            metadata_id: metadata_id,
            is_active: true
        });

        user_badges[user][idx] = b;
        user_badge_count[user] = idx + 1;
        total_badges_minted += 1;

        emit BadgeMinted(user, badge_type, timestamp);
    }

    /// Only owner (Mediolano platform) can mint certificates
    function mint_certificate(
        address user,
        CertificateType certificate_type,
        uint256 metadata_id,
        uint64 expiry_date // 0 = None
    ) external onlyOwner {
        uint64 timestamp = _now();
        uint32 idx = user_certificate_count[user];

        Certificate memory c = Certificate({
            certificate_type: certificate_type,
            timestamp: timestamp,
            metadata_id: metadata_id,
            expiry_date: expiry_date,
            is_valid: true
        });

        user_certificates[user][idx] = c;
        user_certificate_count[user] = idx + 1;
        total_certificates_minted += 1;

        emit CertificateMinted(user, certificate_type, timestamp);
    }

    /*---------------------- Query functions ----------------------*/

    function get_user_achievements(
        address user,
        uint32 start_index,
        uint32 count
    ) external view returns (Achievement[] memory) {
        uint32 totalCount = user_activity_count[user];
        uint32 end = start_index + count;
        if (end > totalCount) end = totalCount;
        if (start_index >= end) return new Achievement;

        uint32 n = end - start_index;
        Achievement[] memory outArr = new Achievement[](n);
        for (uint32 i = 0; i < n; i++) {
            outArr[i] = user_achievements[user][start_index + i];
        }
        return outArr;
    }

    function get_user_activity_count(address user) external view returns (uint32) {
        return user_activity_count[user];
    }

    function get_user_total_points(address user) external view returns (uint32) {
        return user_total_points[user];
    }

    function get_user_badges(address user) external view returns (Badge[] memory) {
        uint32 count = user_badge_count[user];
        Badge[] memory outArr = new Badge[](count);
        for (uint32 i = 0; i < count; i++) {
            outArr[i] = user_badges[user][i];
        }
        return outArr;
    }

    function get_user_certificates(address user) external view returns (Certificate[] memory) {
        uint32 count = user_certificate_count[user];
        Certificate[] memory outArr = new Certificate[](count);
        for (uint32 i = 0; i < count; i++) {
            outArr[i] = user_certificates[user][i];
        }
        return outArr;
    }

    function get_leaderboard(
        uint32 start_index,
        uint32 count
    ) external view returns (LeaderboardEntry[] memory) {
        uint32 totalCount = leaderboard_count;
        uint32 end = start_index + count;
        if (end > totalCount) end = totalCount;
        if (start_index >= end) return new LeaderboardEntry;

        uint32 n = end - start_index;
        LeaderboardEntry[] memory outArr = new LeaderboardEntry[](n);
        for (uint32 i = 0; i < n; i++) {
            outArr[i] = leaderboard_entries[start_index + i];
        }
        return outArr;
    }

    function get_user_rank(address user) external view returns (uint32) {
        return user_rank[user];
    }

    /*---------------- Configuration (owner only) -----------------*/

    function set_activity_points(ActivityType activity_type, uint32 points) external onlyOwner {
        activity_points[_activity_type_to_id(activity_type)] = points;
    }

    function set_owner(address new_owner) external onlyOwner {
        address old = owner;
        owner = new_owner;
        emit OwnerChanged(old, new_owner);
    }

    /*---------------------- Getters (optionnel) ------------------*/

    function get_owner() external view returns (address) {
        return owner;
    }

    function get_stats()
        external
        view
        returns (
            uint32 _total_users,
            uint32 _total_achievements,
            uint32 _total_badges_minted,
            uint32 _total_certificates_minted,
            uint32 _leaderboard_count
        )
    {
        return (total_users, total_achievements, total_badges_minted, total_certificates_minted, leaderboard_count);
    }
}
