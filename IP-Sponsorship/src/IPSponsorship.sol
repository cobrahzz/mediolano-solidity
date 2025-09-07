// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────────── Errors (const strings) ───────────────────────────── */
library IPSponsorErrors {
    string internal constant ONLY_IP_OWNER_CAN_UPDATE      = "Only IP owner can update";
    string internal constant IP_NOT_ACTIVE                 = "IP is not active";
    string internal constant ONLY_OWNER_OR_ADMIN           = "Only owner or admin";
    string internal constant IP_ALREADY_INACTIVE           = "IP is already inactive";

    string internal constant ONLY_IP_OWNER_CAN_CREATE_OFFERS = "Only IP owner can create offers";
    string internal constant INVALID_PRICE_RANGE             = "Invalid price range";
    string internal constant DURATION_MUST_BE_POSITIVE       = "Duration must be positive";
    string internal constant ONLY_OFFER_AUTHOR_CAN_CANCEL    = "Only offer author can cancel";
    string internal constant OFFER_NOT_ACTIVE                = "Offer is not active";
    string internal constant ONLY_OFFER_AUTHOR_CAN_UPDATE    = "Only offer author can update";
    string internal constant ONLY_OFFER_AUTHOR_CAN_ACCEPT    = "Only offer author can accept";
    string internal constant ONLY_OFFER_AUTHOR_CAN_REJECT    = "Only offer author can reject";

    string internal constant BID_BELOW_MINIMUM   = "Bid below minimum price";
    string internal constant BID_ABOVE_MAXIMUM   = "Bid above maximum price";
    string internal constant NOT_AUTHORIZED_TO_SPONSOR = "Not authorized to sponsor";
    string internal constant NO_VALID_BID_FOUND  = "No valid bid found";

    string internal constant ONLY_LICENSE_OWNER_CAN_TRANSFER = "Only license owner can transfer";
    string internal constant LICENSE_NOT_ACTIVE              = "License is not active";
    string internal constant LICENSE_NOT_TRANSFERABLE        = "License is not transferable";
    string internal constant LICENSE_HAS_EXPIRED             = "License has expired";
    string internal constant NOT_AUTHORIZED_TO_REVOKE        = "Not authorized to revoke";
}

/* ───────────────────────────────── Interface (1:1 noms) ─────────────────────────── */
interface IIPSponsorship {
    // IP Management
    function register_ip(uint256 ip_metadata, uint256 license_terms) external returns (uint256);
    function update_ip_metadata(uint256 ip_id, uint256 new_metadata) external;
    function deactivate_ip(uint256 ip_id) external;

    // Sponsorship Offer
    function create_sponsorship_offer(
        uint256 ip_id,
        uint256 min_price,
        uint256 max_price,
        uint64 duration,
        address specific_sponsor // address(0) = None
    ) external returns (uint256);
    function cancel_sponsorship_offer(uint256 offer_id) external;
    function update_sponsorship_offer(uint256 offer_id, uint256 new_min_price, uint256 new_max_price) external;

    // Sponsorship
    function sponsor_ip(uint256 offer_id, uint256 bid_amount) external;
    function accept_sponsorship(uint256 offer_id, address sponsor) external;
    function reject_sponsorship(uint256 offer_id, address sponsor) external;

    // License
    function transfer_license(uint256 license_id, address new_owner) external;
    function revoke_license(uint256 license_id) external;

    // Views
    function get_ip_details(uint256 ip_id) external view returns (address owner, uint256 metadata, uint256 license_terms, bool active);
    function get_sponsorship_offer(uint256 offer_id) external view returns (uint256 ip_id, uint256 min_price, uint256 max_price, uint64 duration, address author, bool active, address specific_sponsor);
    function get_user_ips(address owner) external view returns (uint256[] memory);
    function get_user_licenses(address owner) external view returns (uint256[] memory);
    function get_active_offers() external view returns (uint256[] memory);
    function get_sponsorship_bids(uint256 offer_id) external view returns (address[] memory sponsors, uint256[] memory amounts);
    function is_license_valid(uint256 license_id) external view returns (bool);
    function get_license_details(uint256 license_id) external view returns (uint256 ip_id, address sponsor, address original_author, uint256 amount_paid, uint64 issue_date, uint64 expiry_date, bool active, bool transferable);
    function get_user_offers(address author) external view returns (uint256[] memory);
}

/* ───────────────────────────────────── Contract ─────────────────────────────────── */
contract IPSponsorship is IIPSponsorship {
    /* --------------------------------- Storage -------------------------------- */
    struct IntellectualProperty {
        address owner;
        uint256 metadata;       // IPFS hash / ref (felt252 -> uint256)
        uint256 license_terms;  // ref (felt252 -> uint256)
        bool    active;
        uint64  created_at;
    }

    struct SponsorshipOffer {
        uint256 ip_id;
        uint256 min_price;
        uint256 max_price;
        uint64  duration;           // seconds
        address author;
        bool    active;
        address specific_sponsor;   // address(0) => None
        uint64  created_at;
    }

    struct SponsorshipBid {
        address sponsor;
        uint256 amount;
        uint64  timestamp;
        bool    accepted;
    }

    struct License {
        uint256 ip_id;
        address sponsor;
        address original_author;
        uint256 amount_paid;
        uint64  issue_date;
        uint64  expiry_date;
        bool    active;
        bool    transferable;
    }

    // Core
    mapping(uint256 => IntellectualProperty) private intellectual_properties;
    mapping(uint256 => SponsorshipOffer)     private sponsorship_offers;
    mapping(uint256 => License)              private licenses;

    // Bids
    mapping(uint256 => SponsorshipBid[])     private offer_bids;

    // Users
    mapping(address => uint256[])            private user_ips;
    mapping(address => uint256[])            private user_licenses;
    mapping(address => uint256[])            private user_offers;

    // Active offer ids
    uint256[] private active_offers;

    // Admin & counters
    address public admin;
    uint256 private next_ip_id;
    uint256 private next_offer_id;
    uint256 private next_license_id;

    /* --------------------------------- Events --------------------------------- */
    event IPRegistered(uint256 ip_id, address owner, uint256 metadata, uint256 license_terms);
    event IPMetadataUpdated(uint256 ip_id, uint256 new_metadata);
    event SponsorshipOfferCreated(uint256 offer_id, uint256 ip_id, address author, uint256 min_price, uint256 max_price, uint64 duration, address specific_sponsor);
    event SponsorshipOfferCancelled(uint256 offer_id, address author);
    event SponsorshipOfferUpdated(uint256 offer_id, uint256 new_min_price, uint256 new_max_price);
    event SponsorshipBidPlaced(uint256 offer_id, address sponsor, uint256 amount);
    event SponsorshipAccepted(uint256 offer_id, address sponsor, uint256 license_id, uint256 amount);
    event SponsorshipRejected(uint256 offer_id, address sponsor);
    event LicenseTransferred(uint256 license_id, address from, address to);
    event LicenseRevoked(uint256 license_id, address revoker);

    /* --------------------------------- Init ----------------------------------- */
    constructor(address _admin) {
        admin = _admin;
        next_ip_id = 1;
        next_offer_id = 1;
        next_license_id = 1;
    }

    /* ------------------------------ IP Management ----------------------------- */
    function register_ip(uint256 ip_metadata, uint256 license_terms_) external returns (uint256) {
        uint256 ip_id = next_ip_id++;

        intellectual_properties[ip_id] = IntellectualProperty({
            owner: msg.sender,
            metadata: ip_metadata,
            license_terms: license_terms_,
            active: true,
            created_at: uint64(block.timestamp)
        });

        user_ips[msg.sender].push(ip_id);

        emit IPRegistered(ip_id, msg.sender, ip_metadata, license_terms_);
        return ip_id;
    }

    function update_ip_metadata(uint256 ip_id, uint256 new_metadata) external {
        IntellectualProperty storage ip = intellectual_properties[ip_id];
        require(ip.owner == msg.sender, IPSponsorErrors.ONLY_IP_OWNER_CAN_UPDATE);
        require(ip.active, IPSponsorErrors.IP_NOT_ACTIVE);

        ip.metadata = new_metadata;
        emit IPMetadataUpdated(ip_id, new_metadata);
    }

    function deactivate_ip(uint256 ip_id) external {
        IntellectualProperty storage ip = intellectual_properties[ip_id];
        require(ip.owner == msg.sender || admin == msg.sender, IPSponsorErrors.ONLY_OWNER_OR_ADMIN);
        require(ip.active, IPSponsorErrors.IP_ALREADY_INACTIVE);

        ip.active = false;
        _cancel_ip_offers(ip_id);
    }

    /* --------------------------- Sponsorship Offers --------------------------- */
    function create_sponsorship_offer(
        uint256 ip_id,
        uint256 min_price,
        uint256 max_price,
        uint64 duration,
        address specific_sponsor
    ) external returns (uint256) {
        IntellectualProperty storage ip = intellectual_properties[ip_id];
        require(ip.owner == msg.sender, IPSponsorErrors.ONLY_IP_OWNER_CAN_CREATE_OFFERS);
        require(ip.active, IPSponsorErrors.IP_NOT_ACTIVE);
        require(min_price <= max_price, IPSponsorErrors.INVALID_PRICE_RANGE);
        require(duration > 0, IPSponsorErrors.DURATION_MUST_BE_POSITIVE);

        uint256 offer_id = next_offer_id++;

        sponsorship_offers[offer_id] = SponsorshipOffer({
            ip_id: ip_id,
            min_price: min_price,
            max_price: max_price,
            duration: duration,
            author: msg.sender,
            active: true,
            specific_sponsor: specific_sponsor, // 0 = None
            created_at: uint64(block.timestamp)
        });

        user_offers[msg.sender].push(offer_id);
        active_offers.push(offer_id);

        emit SponsorshipOfferCreated(offer_id, ip_id, msg.sender, min_price, max_price, duration, specific_sponsor);
        return offer_id;
    }

    function cancel_sponsorship_offer(uint256 offer_id) external {
        SponsorshipOffer storage offer = sponsorship_offers[offer_id];
        require(offer.author == msg.sender, IPSponsorErrors.ONLY_OFFER_AUTHOR_CAN_CANCEL);
        require(offer.active, IPSponsorErrors.OFFER_NOT_ACTIVE);

        offer.active = false;
        _remove_from_active_offers(offer_id);

        emit SponsorshipOfferCancelled(offer_id, msg.sender);
    }

    function update_sponsorship_offer(uint256 offer_id, uint256 new_min_price, uint256 new_max_price) external {
        SponsorshipOffer storage offer = sponsorship_offers[offer_id];
        require(offer.author == msg.sender, IPSponsorErrors.ONLY_OFFER_AUTHOR_CAN_UPDATE);
        require(offer.active, IPSponsorErrors.OFFER_NOT_ACTIVE);
        require(new_min_price <= new_max_price, IPSponsorErrors.INVALID_PRICE_RANGE);

        offer.min_price = new_min_price;
        offer.max_price = new_max_price;

        emit SponsorshipOfferUpdated(offer_id, new_min_price, new_max_price);
    }

    /* --------------------------------- Bidding -------------------------------- */
    function sponsor_ip(uint256 offer_id, uint256 bid_amount) external {
        SponsorshipOffer storage offer = sponsorship_offers[offer_id];
        require(offer.active, IPSponsorErrors.OFFER_NOT_ACTIVE);
        require(bid_amount >= offer.min_price, IPSponsorErrors.BID_BELOW_MINIMUM);
        require(bid_amount <= offer.max_price, IPSponsorErrors.BID_ABOVE_MAXIMUM);

        if (offer.specific_sponsor != address(0)) {
            require(msg.sender == offer.specific_sponsor, IPSponsorErrors.NOT_AUTHORIZED_TO_SPONSOR);
        }

        offer_bids[offer_id].push(SponsorshipBid({
            sponsor: msg.sender,
            amount: bid_amount,
            timestamp: uint64(block.timestamp),
            accepted: false
        }));

        emit SponsorshipBidPlaced(offer_id, msg.sender, bid_amount);
    }

    function accept_sponsorship(uint256 offer_id, address sponsor) external {
        SponsorshipOffer storage offer = sponsorship_offers[offer_id];
        require(offer.author == msg.sender, IPSponsorErrors.ONLY_OFFER_AUTHOR_CAN_ACCEPT);
        require(offer.active, IPSponsorErrors.OFFER_NOT_ACTIVE);

        SponsorshipBid[] storage bids = offer_bids[offer_id];
        uint256 acceptedIndex = type(uint256).max;
        uint256 acceptedAmount = 0;

        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].sponsor == sponsor && !bids[i].accepted) {
                acceptedIndex = i;
                acceptedAmount = bids[i].amount;
                break;
            }
        }
        require(acceptedIndex != type(uint256).max, IPSponsorErrors.NO_VALID_BID_FOUND);

        // mark accepted
        bids[acceptedIndex].accepted = true;

        // create license
        uint256 license_id = next_license_id++;
        uint64 nowTs = uint64(block.timestamp);

        licenses[license_id] = License({
            ip_id: offer.ip_id,
            sponsor: sponsor,
            original_author: offer.author,
            amount_paid: acceptedAmount,
            issue_date: nowTs,
            expiry_date: nowTs + offer.duration,
            active: true,
            transferable: true
        });

        user_licenses[sponsor].push(license_id);

        // deactivate offer
        offer.active = false;
        _remove_from_active_offers(offer_id);

        emit SponsorshipAccepted(offer_id, sponsor, license_id, acceptedAmount);
    }

    function reject_sponsorship(uint256 offer_id, address sponsor) external {
        SponsorshipOffer storage offer = sponsorship_offers[offer_id];
        require(offer.author == msg.sender, IPSponsorErrors.ONLY_OFFER_AUTHOR_CAN_REJECT);
        require(offer.active, IPSponsorErrors.OFFER_NOT_ACTIVE);

        emit SponsorshipRejected(offer_id, sponsor);
    }

    /* ------------------------------- License Ops ------------------------------ */
    function transfer_license(uint256 license_id, address new_owner) external {
        License storage l = licenses[license_id];
        require(l.sponsor == msg.sender, IPSponsorErrors.ONLY_LICENSE_OWNER_CAN_TRANSFER);
        require(l.active, IPSponsorErrors.LICENSE_NOT_ACTIVE);
        require(l.transferable, IPSponsorErrors.LICENSE_NOT_TRANSFERABLE);
        require(block.timestamp < l.expiry_date, IPSponsorErrors.LICENSE_HAS_EXPIRED);

        address old = l.sponsor;
        l.sponsor = new_owner;

        user_licenses[new_owner].push(license_id);
        _remove_license_from_user(old, license_id);

        emit LicenseTransferred(license_id, old, new_owner);
    }

    function revoke_license(uint256 license_id) external {
        License storage l = licenses[license_id];
        require(l.original_author == msg.sender || admin == msg.sender, IPSponsorErrors.NOT_AUTHORIZED_TO_REVOKE);
        require(l.active, IPSponsorErrors.LICENSE_NOT_ACTIVE);

        l.active = false;
        emit LicenseRevoked(license_id, msg.sender);
    }

    /* ---------------------------------- Views --------------------------------- */
    function get_ip_details(uint256 ip_id) external view returns (address, uint256, uint256, bool) {
        IntellectualProperty storage ip = intellectual_properties[ip_id];
        return (ip.owner, ip.metadata, ip.license_terms, ip.active);
    }

    function get_sponsorship_offer(uint256 offer_id)
        external
        view
        returns (uint256, uint256, uint256, uint64, address, bool, address)
    {
        SponsorshipOffer storage o = sponsorship_offers[offer_id];
        return (o.ip_id, o.min_price, o.max_price, o.duration, o.author, o.active, o.specific_sponsor);
    }

    function get_user_ips(address owner_) external view returns (uint256[] memory) {
        return user_ips[owner_];
    }

    function get_user_licenses(address owner_) external view returns (uint256[] memory) {
        return user_licenses[owner_];
    }

    function get_active_offers() external view returns (uint256[] memory) {
        // retourne seulement celles qui sont encore actives (comme le Cairo)
        uint256 n = active_offers.length;
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (sponsorship_offers[active_offers[i]].active) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = active_offers[i];
            if (sponsorship_offers[id].active) {
                out[k++] = id;
            }
        }
        return out;
    }

    function get_sponsorship_bids(uint256 offer_id)
        external
        view
        returns (address[] memory sponsors, uint256[] memory amounts)
    {
        SponsorshipBid[] storage bids = offer_bids[offer_id];
        sponsors = new address[](bids.length);
        amounts  = new uint256[](bids.length);
        for (uint256 i = 0; i < bids.length; i++) {
            sponsors[i] = bids[i].sponsor;
            amounts[i]  = bids[i].amount;
        }
    }

    function is_license_valid(uint256 license_id) external view returns (bool) {
        License storage l = licenses[license_id];
        return l.active && block.timestamp < l.expiry_date;
    }

    function get_license_details(uint256 license_id)
        external
        view
        returns (uint256, address, address, uint256, uint64, uint64, bool, bool)
    {
        License storage l = licenses[license_id];
        return (l.ip_id, l.sponsor, l.original_author, l.amount_paid, l.issue_date, l.expiry_date, l.active, l.transferable);
    }

    function get_user_offers(address author) external view returns (uint256[] memory) {
        return user_offers[author];
    }

    /* --------------------------------- Helpers -------------------------------- */
    function _remove_license_from_user(address user, uint256 license_id) internal {
        uint256[] storage arr = user_licenses[user];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == license_id) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
    }

    function _cancel_ip_offers(uint256 ip_id) internal {
        // passe les offres actives de cet IP à inactive (ne retire pas de la liste, fidèle au Cairo)
        for (uint256 i = 0; i < active_offers.length; i++) {
            uint256 id = active_offers[i];
            SponsorshipOffer storage o = sponsorship_offers[id];
            if (o.ip_id == ip_id && o.active) {
                o.active = false;
            }
        }
    }

    function _remove_from_active_offers(uint256 offer_id) internal {
        for (uint256 i = 0; i < active_offers.length; i++) {
            if (active_offers[i] == offer_id) {
                active_offers[i] = active_offers[active_offers.length - 1];
                active_offers.pop();
                break;
            }
        }
    }
}
