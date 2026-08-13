// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #14: InviteRegistry — Referral Relationship Registry
 * Responsibility: Records invite relationships, supports fee distribution calculation
 * Deploy order: 2nd deployment (depends on PlatformSettings)
 *
 * This contract implements two-level referral registration and queries,
 * and automatically distributes trading fees based on invite levels
 * (level-1 inviter, level-2 inviter, platform wallet).
 */

import "./interfaces/Interfaces.sol";

/// @title InviteRegistry - Two-Level Referral System
/// @author WEB3GUARANTEE
/// @notice Manages user referral relationships and distributes trading fees across a two-level invite chain
contract InviteRegistry {

    // ==================== Anti-Contract Call ====================

    /// @dev Reject unauthorized contract calls; only EOA or whitelisted contract wallets allowed
    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // ==================== State Variables ====================

    /// Owner address for contract management
    address public owner;

    /// Platform settings interface for reading fee share ratios, authorized contracts, platform wallet, etc.
    IPlatformSettings public settings;

    /// Level-1 invite mapping: user address => direct inviter address (level1)
    mapping(address => address) public inviter;
    /// Level-2 invite mapping: user address => inviter's inviter address (level2)
    mapping(address => address) public inviterOfInviter;

    /// Direct invitee list: inviter address => list of users they directly invited
    mapping(address => address[]) public invitees;

    /// Cumulative invite earnings: inviter => token => totalEarned
    mapping(address => mapping(address => uint256)) public totalEarned;

    // ==================== Events ====================

    /// Emitted when a user registers an invite relationship
    /// @param user Registered user address
    /// @param level1 Level-1 inviter address
    /// @param level2 Level-2 inviter address
    event Registered(address indexed user, address indexed level1, address level2);

    /// Emitted when fee distribution is completed
    /// @param user User address that generated the fee
    /// @param toLevel1 Amount distributed to level-1 inviter
    /// @param toLevel2 Amount distributed to level-2 inviter
    /// @param toPlatform Amount distributed to platform wallet
    event FeeDistributed(address indexed user, uint256 toLevel1, uint256 toLevel2, uint256 toPlatform);

    // ==================== Constructor ====================

    /// Constructor, initializes the platform settings contract address
    /// @param _settings PlatformSettings contract address for global config such as fee share ratios
    constructor(address _settings) {
        owner = msg.sender;
        settings = IPlatformSettings(_settings);
    }

    // ==================== Owner Management ====================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // ==================== External Functions ====================

    /// Register invite relationship
    /// Caller (msg.sender) sets _inviter as their level-1 inviter,
    /// and automatically records _inviter's inviter as the caller's level-2 inviter.
    /// Each address can only register once; cannot self-invite; inviter cannot be zero address.
    /// @dev Audit note [L-03]: Checking only 1-2 level loops is safe since the system only has 2-level distribution,
    ///           deeper loops don't affect fee calculation, and each address can only register once, making long loops prohibitively expensive.
    /// @param _inviter Level-1 inviter address
    function register(address _inviter) external noContract {
        if (inviter[msg.sender] != address(0)) revert AlreadyRegistered();
        if (_inviter == msg.sender) revert CannotInviteSelf();
        if (_inviter == address(0) || _inviter.code.length > 0) revert InvalidInviter();
        if (inviter[_inviter] == msg.sender) revert CircularInvite();
        if (inviterOfInviter[_inviter] == msg.sender) revert CircularInvite();
        inviter[msg.sender] = _inviter;
        inviterOfInviter[msg.sender] = inviter[_inviter];
        invitees[_inviter].push(msg.sender);
        emit Registered(msg.sender, _inviter, inviter[_inviter]);
    }

    /// Query the level-1 and level-2 inviter addresses for a given user
    /// @param user User address to query
    /// @return level1 Level-1 inviter address
    /// @return level2 Level-2 inviter address
    function getInviters(address user) external view returns (address level1, address level2) {
        level1 = inviter[user];
        level2 = inviterOfInviter[user];
    }

    /// Distribute trading fees to inviters and platform
    /// Distributes fees according to rates configured in PlatformSettings:
    ///   -   - Level-1 inviter (if exists): calculated as level1Rate / 10000
    ///   -   - Level-2 inviter (if exists): calculated as level2Rate / 10000
    ///   -   - Platform wallet: receives the remainder
    /// Only contracts authorized by PlatformSettings may call this function.
    /// @param user User address that generated the fee
    /// @param feeAmount Total fee amount
    /// @param token ERC20 token contract used for fee payment
    function distributeFee(address user, uint256 feeAmount, IERC20 token) external {
        IPlatformSettings _s = settings;
        if (!_s.isAuthorizedContract(msg.sender)) revert NotAuthorized();
        address level1 = inviter[user];
        address level2 = inviterOfInviter[user];

        uint256 toLevel1 = 0;
        uint256 toLevel2 = 0;

        if (level1 != address(0) && level1.code.length == 0) {
            toLevel1 = feeAmount * _s.getLevel1Rate() / 10000;
            try token.transfer(level1, toLevel1) returns (bool ok) {
                if (!ok) toLevel1 = 0;
                else totalEarned[level1][address(token)] += toLevel1;
            } catch {
                toLevel1 = 0;
            }
        }
        if (level2 != address(0) && level2.code.length == 0) {
            toLevel2 = feeAmount * _s.getLevel2Rate() / 10000;
            try token.transfer(level2, toLevel2) returns (bool ok) {
                if (!ok) toLevel2 = 0;
                else totalEarned[level2][address(token)] += toLevel2;
            } catch {
                toLevel2 = 0;
            }
        }

        uint256 toPlatform = feeAmount - toLevel1 - toLevel2;
        address splitter = _s.getFeeSplitter();
        bool routed;
        if (splitter != address(0)) {
            try this._splitterRoute(splitter, address(token), toPlatform) {
                routed = true;
            } catch {
            }
        }
        if (!routed) {
            address platformWallet = _s.getPlatformWallet();
            if (platformWallet == address(0)) revert ZeroAddress();
            if (!token.transfer(platformWallet, toPlatform)) revert TransferFailed();
            if (splitter != address(0)) emit SplitterFallback(address(token), toPlatform, platformWallet);
        }

        emit FeeDistributed(user, toLevel1, toLevel2, toPlatform);
    }

    /// @dev Splitter-path wrapper — must be external so try/catch can roll back atomically.
    /// Only this contract itself may call it, preventing external callers from triggering cross-party misappropriation.
    function _splitterRoute(address splitter, address token, uint256 amount) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        if (!IERC20(token).transfer(splitter, amount)) revert TransferFailed();
        IPlatformFeeSplitter(splitter).distribute(token, amount);
    }

    // ==================== Invitee Queries ====================

    /// @notice Get paginated list of a user's direct invitees
    /// @param user Inviter address
    /// @param offset Start offset
    /// @param limit Max return count (capped at 100)
    /// @return Invitee address array
    function getInvitees(address user, uint256 offset, uint256 limit) external view returns (address[] memory) {
        address[] storage arr = invitees[user];
        uint256 total = arr.length;
        if (limit > 100) limit = 100;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = arr[i];
        }
        return result;
    }

    /// @notice Get total count of a user's direct invitees
    /// @param user Inviter address
    /// @return Total invitee count
    function getInviteeCount(address user) external view returns (uint256) {
        return invitees[user].length;
    }

    /// @notice Query a user's cumulative invite earnings (USDT)
    function getTotalEarned(address user, address usdt) external view returns (uint256 earnedUsdt) {
        earnedUsdt = totalEarned[user][usdt];
    }
}
