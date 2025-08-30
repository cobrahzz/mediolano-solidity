// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIPLeasing {
    struct Lease {
        address lessee;
        uint256 amount;
        uint64  start_time;
        uint64  end_time;
        bool    is_active;
    }

    struct LeaseOffer {
        address owner;
        uint256 amount;
        uint256 lease_fee;
        uint64  duration;
        string  license_terms_uri;
        bool    is_active;
    }

    // --- Actions ---
    function create_lease_offer(
        uint256 token_id,
        uint256 amount,
        uint256 lease_fee,
        uint64  duration,
        string calldata license_terms_uri
    ) external;

    function cancel_lease_offer(uint256 token_id) external;

    function start_lease(uint256 token_id) external;

    function renew_lease(uint256 token_id, uint64 additional_duration) external;

    function expire_lease(uint256 token_id) external;

    function terminate_lease(uint256 token_id, string calldata reason) external;

    function mint_ip(address to, uint256 token_id, uint256 amount) external;

    // --- Views ---
    function get_lease(uint256 token_id) external view returns (Lease memory);
    function get_lease_offer(uint256 token_id) external view returns (LeaseOffer memory);
    function get_active_leases_by_owner(address owner_) external view returns (uint256[] memory);
    function get_active_leases_by_lessee(address lessee) external view returns (uint256[] memory);
}
