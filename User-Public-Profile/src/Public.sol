// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Port 1:1 de "UserPublicProfile" (Cairo) vers Solidity (un seul fichier)
/// - ByteArray -> string
/// - u64 -> uint64
/// - Même API (snake_case), mêmes événements & contrôles d'accès

contract UserPublicProfile {
    /*//////////////////////////////////////////////////////////////
                               Structs
    //////////////////////////////////////////////////////////////*/

    struct UserProfile {
        // Personal Information
        string username;
        string name_;
        string bio;
        string location;
        string email;
        string phone;
        string org;
        string website;

        // Social Media Links
        string x_handle;
        string linkedin;
        string instagram;
        string tiktok;
        string facebook;
        string discord;
        string youtube;
        string github;

        // Boolean Settings
        bool display_public_profile;
        bool email_notifications;
        bool marketplace_profile;

        // Metadata
        bool is_registered;
        uint64 last_updated;
    }

    struct SocialMediaLinks {
        string x_handle;
        string linkedin;
        string instagram;
        string tiktok;
        string facebook;
        string discord;
        string youtube;
        string github;
    }

    struct PersonalInfo {
        string username;
        string name_;
        string bio;
        string location;
        string email;
        string phone;
        string org;
        string website;
    }

    struct ProfileSettings {
        bool display_public_profile;
        bool email_notifications;
        bool marketplace_profile;
    }

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event ProfileRegistered(address indexed user, string username, uint64 timestamp);
    event ProfileUpdated(address indexed user, uint64 timestamp);
    event SettingsUpdated(address indexed user, uint64 timestamp);

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    mapping(address => UserProfile) private profiles;
    uint32 private profile_count;

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                External
    //////////////////////////////////////////////////////////////*/

    /// Register a new user profile with all information (pour l'appelant)
    function register_profile(
        PersonalInfo calldata personal_info,
        SocialMediaLinks calldata social_links,
        ProfileSettings calldata settings
    ) external {
        address caller = msg.sender;
        uint64 current_time = _now();

        UserProfile memory profile = UserProfile({
            // Personal Information
            username: personal_info.username,
            name_: personal_info.name_,
            bio: personal_info.bio,
            location: personal_info.location,
            email: personal_info.email,
            phone: personal_info.phone,
            org: personal_info.org,
            website: personal_info.website,
            // Social Media
            x_handle: social_links.x_handle,
            linkedin: social_links.linkedin,
            instagram: social_links.instagram,
            tiktok: social_links.tiktok,
            facebook: social_links.facebook,
            discord: social_links.discord,
            youtube: social_links.youtube,
            github: social_links.github,
            // Settings
            display_public_profile: settings.display_public_profile,
            email_notifications: settings.email_notifications,
            marketplace_profile: settings.marketplace_profile,
            // Meta
            is_registered: true,
            last_updated: current_time
        });

        profiles[caller] = profile;
        unchecked { profile_count += 1; }

        emit ProfileRegistered(caller, personal_info.username, current_time);
    }

    /// Update personal information only (de l'appelant)
    function update_personal_info(PersonalInfo calldata personal_info) external {
        address caller = msg.sender;
        UserProfile memory p = profiles[caller];
        require(p.is_registered, "Profile not registered");

        uint64 current_time = _now();
        p.username = personal_info.username;
        p.name_ = personal_info.name_;
        p.bio = personal_info.bio;
        p.location = personal_info.location;
        p.email = personal_info.email;
        p.phone = personal_info.phone;
        p.org = personal_info.org;
        p.website = personal_info.website;
        p.last_updated = current_time;

        profiles[caller] = p;
        emit ProfileUpdated(caller, current_time);
    }

    /// Update social media links only (de l'appelant)
    function update_social_links(SocialMediaLinks calldata social_links) external {
        address caller = msg.sender;
        UserProfile memory p = profiles[caller];
        require(p.is_registered, "Profile not registered");

        uint64 current_time = _now();
        p.x_handle = social_links.x_handle;
        p.linkedin = social_links.linkedin;
        p.instagram = social_links.instagram;
        p.tiktok = social_links.tiktok;
        p.facebook = social_links.facebook;
        p.discord = social_links.discord;
        p.youtube = social_links.youtube;
        p.github = social_links.github;
        p.last_updated = current_time;

        profiles[caller] = p;
        emit ProfileUpdated(caller, current_time);
    }

    /// Update profile settings only (de l'appelant)
    function update_settings(ProfileSettings calldata settings) external {
        address caller = msg.sender;
        UserProfile memory p = profiles[caller];
        require(p.is_registered, "Profile not registered");

        uint64 current_time = _now();
        p.display_public_profile = settings.display_public_profile;
        p.email_notifications = settings.email_notifications;
        p.marketplace_profile = settings.marketplace_profile;
        p.last_updated = current_time;

        profiles[caller] = p;
        emit SettingsUpdated(caller, current_time);
    }

    /*---------------------------- Views ----------------------------*/

    /// Get complete user profile (respecte privacy : public ou owner)
    function get_profile(address user) external view returns (UserProfile memory) {
        UserProfile memory p = profiles[user];
        require(p.is_registered, "Profile not found");
        if (user != msg.sender) {
            require(p.display_public_profile, "Profile is private");
        }
        return p;
    }

    /// Get personal info (respecte privacy)
    function get_personal_info(address user) external view returns (PersonalInfo memory) {
        UserProfile memory p = profiles[user];
        require(p.is_registered, "Profile not found");
        if (user != msg.sender) {
            require(p.display_public_profile, "Profile is private");
        }
        return PersonalInfo({
            username: p.username,
            name_: p.name_,
            bio: p.bio,
            location: p.location,
            email: p.email,
            phone: p.phone,
            org: p.org,
            website: p.website
        });
    }

    /// Get social links (respecte privacy)
    function get_social_links(address user) external view returns (SocialMediaLinks memory) {
        UserProfile memory p = profiles[user];
        require(p.is_registered, "Profile not found");
        if (user != msg.sender) {
            require(p.display_public_profile, "Profile is private");
        }
        return SocialMediaLinks({
            x_handle: p.x_handle,
            linkedin: p.linkedin,
            instagram: p.instagram,
            tiktok: p.tiktok,
            facebook: p.facebook,
            discord: p.discord,
            youtube: p.youtube,
            github: p.github
        });
    }

    /// Get profile settings (visible uniquement par l'owner de ce profil)
    function get_settings(address user) external view returns (ProfileSettings memory) {
        require(user == msg.sender, "Can only view own settings");
        UserProfile memory p = profiles[user];
        require(p.is_registered, "Profile not found");
        return ProfileSettings({
            display_public_profile: p.display_public_profile,
            email_notifications: p.email_notifications,
            marketplace_profile: p.marketplace_profile
        });
    }

    /// Check if user has a registered profile
    function is_profile_registered(address user) external view returns (bool) {
        return profiles[user].is_registered;
    }

    /// Total registered profiles (compteur brut, ré-incrémenté si re-register comme en Cairo)
    function get_profile_count() external view returns (uint32) {
        return profile_count;
    }

    /// Get username (respecte privacy)
    function get_username(address user) external view returns (string memory) {
        UserProfile memory p = profiles[user];
        require(p.is_registered, "Profile not found");
        if (user != msg.sender) {
            require(p.display_public_profile, "Profile is private");
        }
        return p.username;
    }

    /// Is profile public
    function is_profile_public(address user) external view returns (bool) {
        UserProfile memory p = profiles[user];
        if (!p.is_registered) return false;
        return p.display_public_profile;
    }
}
