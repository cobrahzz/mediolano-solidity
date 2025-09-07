// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────────── Interface (1:1) ───────────────────────────── */
interface ISubscription {
    function create_plan(uint256 price, uint64 duration, uint256 tier) external returns (uint256);
    function subscribe(uint256 plan_id) external;
    function unsubscribe(uint256 plan_id) external;
    function renew_subscription() external;
    function upgrade_subscription(uint256 new_plan_id) external;
    function get_subscription_status() external view returns (bool);
    function get_plan_details(uint256 plan_id) external view returns (uint256 price, uint64 duration, uint256 tier);
    function get_user_plan_ids() external view returns (uint256[] memory);
}

/* ────────────────────────────────── Contract ─────────────────────────────── */
contract Subscription is ISubscription {
    /* ------------------------------- Storage -------------------------------- */
    struct SubscriptionPlan {
        uint256 price;
        uint64  duration; // seconds
        uint256 tier;     // felt252 -> uint256
    }

    struct SubscriberInfo {
        uint64 subscription_start;
        uint64 subscription_end;
        bool   active;
    }

    // plan_id => plan
    mapping(uint256 => SubscriptionPlan) private subscription_plans;

    // user => info
    mapping(address => SubscriberInfo) private subscribers;

    // contract owner (can create plans)
    address public owner;

    // user => list of subscribed plan ids (history / current)
    mapping(address => uint256[]) private subscriber_plan_ids;

    /* -------------------------------- Events -------------------------------- */
    event PlanCreated(uint256 plan_id, uint256 price, uint64 duration, uint256 tier);
    event Subscribed(address indexed subscriber, uint256 plan_id);
    event Unsubscribed(address indexed subscriber, uint256 plan_id);
    event SubscriptionRenewed(address indexed subscriber);
    event SubscriptionUpgraded(address indexed subscriber, uint256 new_plan_id);

    /* ------------------------------- Init ----------------------------------- */
    constructor(address _owner) {
        owner = _owner;
    }

    /* ---------------------------- Public API (1:1) -------------------------- */

    // Only owner can create a plan. plan_id is pseudo-random from block data + inputs.
    function create_plan(uint256 price, uint64 duration, uint256 tier) external returns (uint256) {
        require(msg.sender == owner, "Only owner can create plans");

        uint256 plan_id = _generate_plan_id(price, duration, tier);

        // in Cairo: assert plan doesn't exist by checking stored price == 0
        require(subscription_plans[plan_id].price == 0, "Plan already exists");

        subscription_plans[plan_id] = SubscriptionPlan({
            price: price,
            duration: duration,
            tier: tier
        });

        emit PlanCreated(plan_id, price, duration, tier);
        return plan_id;
    }

    // Subscribe caller to a plan
    function subscribe(uint256 plan_id) external {
        SubscriptionPlan memory plan = subscription_plans[plan_id];
        require(plan.price != 0, "Plan does not exist");

        address caller = msg.sender;
        uint64 nowTs = uint64(block.timestamp);

        SubscriberInfo memory info = subscribers[caller];
        if (!info.active) {
            info = SubscriberInfo({
                subscription_start: nowTs,
                subscription_end: 0,
                active: true
            });
        }

        // write current state
        subscribers[caller] = info;

        // append plan id to user's list
        subscriber_plan_ids[caller].push(plan_id);

        // update end with current plan duration (then persist)
        info.subscription_end = nowTs + plan.duration;
        subscribers[caller] = info;

        emit Subscribed(caller, plan_id);
    }

    // Unsubscribe caller from a specific plan (removes one occurrence)
    function unsubscribe(uint256 plan_id) external {
        address caller = msg.sender;
        uint256[] storage ids = subscriber_plan_ids[caller];

        // find index
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == plan_id) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "Not subscribed to this plan");

        // remove by swap&pop
        ids[idx] = ids[ids.length - 1];
        ids.pop();

        if (ids.length == 0) {
            subscribers[caller].active = false;
        }

        emit Unsubscribed(caller, plan_id);
    }

    // Renew current subscription (assumes the first plan is the one to renew in Cairo)
    function renew_subscription() external {
        address caller = msg.sender;
        SubscriberInfo memory info = subscribers[caller];
        require(info.active, "Not currently subscribed");

        uint256[] storage ids = subscriber_plan_ids[caller];
        require(ids.length > 0, "Not currently subscribed");

        uint256 plan_id = ids[0];
        uint64 duration = subscription_plans[plan_id].duration;

        info.subscription_end = uint64(block.timestamp) + duration;
        subscribers[caller] = info;

        emit SubscriptionRenewed(caller);
    }

    // Upgrade to a new plan: replace the list with only new_plan_id, reset start/end
    function upgrade_subscription(uint256 new_plan_id) external {
        address caller = msg.sender;
        SubscriberInfo memory info = subscribers[caller];
        require(info.active, "Not currently subscribed");
        require(subscription_plans[new_plan_id].price != 0, "Plan does not exist");

        uint64 nowTs = uint64(block.timestamp);
        uint64 duration = subscription_plans[new_plan_id].duration;

        // clear list
        delete subscriber_plan_ids[caller];
        // add the new plan
        subscriber_plan_ids[caller].push(new_plan_id);

        info.subscription_start = nowTs;
        info.subscription_end   = nowTs + duration;
        subscribers[caller] = info;

        emit SubscriptionUpgraded(caller, new_plan_id);
    }

    // View: current caller status
    function get_subscription_status() external view returns (bool) {
        return subscribers[msg.sender].active;
    }

    // View: plan details
    function get_plan_details(uint256 plan_id) external view returns (uint256, uint64, uint256) {
        SubscriptionPlan memory p = subscription_plans[plan_id];
        return (p.price, p.duration, p.tier);
    }

    // View: caller's plan ids (copy of the dynamic array)
    function get_user_plan_ids() external view returns (uint256[] memory) {
        uint256[] storage s = subscriber_plan_ids[msg.sender];
        uint256[] memory out = new uint256[](s.length);
        for (uint256 i = 0; i < s.length; i++) out[i] = s[i];
        return out;
    }

    /* -------------------------------- Helpers -------------------------------- */

    // Mimic Cairo's "random felt" with keccak256 over the same entropy sources.
    function _generate_plan_id(uint256 price, uint64 duration, uint256 tier) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(block.number, block.timestamp, price, duration, tier)));
    }
}
