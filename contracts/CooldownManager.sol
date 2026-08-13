// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #15: CooldownManager — C2C Cooldown Lock Management
 *
 * Responsibility: Prevents C2C scammers from withdrawing funds immediately after completing a trade;
 *                 tracks active trade count and cooldown status per user.
 *                 Buyer deposits are tracked per token (USDT),
 *                 active trade count and cooldown time are user-level shared state.
 *
 * Fund management: Merchant deposits, C2C sell order USDT, C2C buyer deposits
 */

import "./interfaces/Interfaces.sol";

/// @title CooldownManager - C2C Anti-Fraud Cooldown System
contract CooldownManager {

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    uint256 private _locked = 1;
    modifier nonReentrant() {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ==================== State Variables ====================

    // ===== Payment Channel (USDT only) =====

    address public owner;

    /// Registered payment channel token list ([USDT])
    address[] public tokens;
    /// token => whether valid
    mapping(address => bool) public isToken;

    address public factory;
    IPlatformSettings public settings;

    /// Cooldown period duration: test 30 minutes (production: 24 hours)
    uint256 public constant COOLDOWN_PERIOD = 24 hours; // production

    /// User active C2C trade count (shared per user, not per token)
    mapping(address => uint256) public activeTradeCount;

    /// User cooldown start time (shared per user)
    mapping(address => uint256) public cooldownStart;

    // [M-05 fix]: Track users with active disputes to prevent withdrawal during arbitration
    mapping(address => bool) public hasDispute;

    // [C-10 fix]: Track user's active C2C order count (buy orders + sell orders)
    mapping(address => uint256) public activeC2COrderCount;

    /// Dual payment channel: buyer deposit tracked per token
    mapping(address => mapping(address => uint256)) public depositBalance;

    /// Dual payment channel: pending withdrawals from failed transfers (per token)
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;

    /// Authorized C2CTrade clones
    mapping(address => bool) public authorizedCallers;

    // ==================== Events ====================

    event FactorySet(address factory);
    event TradeAuthorized(address trade);
    event TradeStarted(address indexed user, uint256 activeCount);
    event TradeEnded(address indexed user, uint256 activeCount, uint256 cooldownStart);
    event DisputeNotified(address indexed user);
    // [M-05 fix]: Event for dispute resolution
    event DisputeResolved(address indexed user);
    event DepositReceived(address indexed buyer, address indexed token, uint256 amount);
    event DepositPenalized(address indexed buyer, address indexed seller, address indexed token, uint256 amount);
    event DepositWithdrawn(address indexed buyer, address indexed token, uint256 amount);
    event TransferPending(address indexed to, address indexed token, uint256 amount);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier onlyFactoryOrAuthorized() {
        if (msg.sender != factory && !authorizedCallers[msg.sender]) revert NotAuthorized();
        _;
    }

    // ==================== Constructor ====================

    /// @notice Deploy cooldown manager contract (USDT only)
    constructor(address _usdt) {
        if (_usdt == address(0)) revert ZeroAddress();
        owner = msg.sender;
        tokens.push(_usdt);
        isToken[_usdt] = true;
    }

    // ==================== Admin Functions ====================

    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
        emit FactorySet(_factory);
    }

    function setSettings(address _settings) external onlyOwner {
        if (_settings == address(0)) revert ZeroAddress();
        settings = IPlatformSettings(_settings);
    }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    // ==================== Factory-Called Functions ====================

    function authorizeTrade(address trade) external onlyFactory {
        authorizedCallers[trade] = true;
        emit TradeAuthorized(trade);
    }

    function tradeStarted(address user) external onlyFactory {
        uint256 newCount = activeTradeCount[user] + 1;
        activeTradeCount[user] = newCount;
        cooldownStart[user] = 0;
        emit TradeStarted(user, newCount);
    }

    // [C-10 fix]: C2C order creation callback (buy/sell orders)
    function c2cOrderCreated(address user) external onlyFactory {
        activeC2COrderCount[user]++;
    }

    // [C-10 fix]: C2C order closure callback (completed/cancelled/delisted)
    function c2cOrderClosed(address user) external onlyFactory {
        if (activeC2COrderCount[user] > 0) {
            activeC2COrderCount[user]--;
        }
    }

    // ==================== Trade Contract-Called Functions ====================

    function tradeEnded(address user) external onlyAuthorized {
        uint256 count = activeTradeCount[user];
        if (count == 0) revert NoActiveTrade();
        uint256 newCount = count - 1;
        activeTradeCount[user] = newCount;
        if (newCount == 0) {
            cooldownStart[user] = block.timestamp;
        }
        emit TradeEnded(user, newCount, cooldownStart[user]);
    }

    function disputeRaised(address user) external onlyAuthorized {
        // [M-05 fix]: Record dispute status to prevent withdrawal during arbitration
        hasDispute[user] = true;
        emit DisputeNotified(user);
    }

    /// @notice Clear dispute status after arbitration completes
    function disputeResolved(address user) external onlyAuthorized {
        hasDispute[user] = false;
        emit DisputeResolved(user);
    }

    /// @notice Receive buyer deposit (credited per token)
    function receiveDeposit(address _buyer, uint256 amount, address token) external onlyFactoryOrAuthorized nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (amount == 0) revert Insufficient();
        if (!IERC20(token).transferFrom(_buyer, address(this), amount)) revert TransferFailed();
        depositBalance[_buyer][token] += amount;
        emit DepositReceived(_buyer, token, amount);
    }

    /// @notice Penalize buyer deposit to seller (per-token transfer)
    function penalize(address _buyer, address _seller, uint256 amount, address token) external onlyAuthorized nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (depositBalance[_buyer][token] < amount) revert Insufficient();
        depositBalance[_buyer][token] -= amount;
        _safeTransferToUser(token, _seller, amount);
        emit DepositPenalized(_buyer, _seller, token, amount);
    }

    /// @notice Release buyer deposit (per-token refund)
    function releaseDeposit(address _buyer, uint256 amount, address token) external onlyAuthorized nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (depositBalance[_buyer][token] < amount) revert Insufficient();
        depositBalance[_buyer][token] -= amount;
        _safeTransferToUser(token, _buyer, amount);
        emit DepositWithdrawn(_buyer, token, amount);
    }

    /// @notice Penalize buyer deposit to arbitration case contract (per token)
    function penalizeToCase(address _buyer, address caseContract, uint256 amount, address token) external onlyAuthorized nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (depositBalance[_buyer][token] < amount) revert Insufficient();
        depositBalance[_buyer][token] -= amount;
        _safeTransferToUser(token, caseContract, amount);
        emit DepositPenalized(_buyer, caseContract, token, amount);
    }

    /// @notice Partial release of buyer deposit (per token)
    function releasePartialDeposit(address _buyer, uint256 amount, address token) external onlyAuthorized nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (depositBalance[_buyer][token] < amount) revert Insufficient();
        depositBalance[_buyer][token] -= amount;
        _safeTransferToUser(token, _buyer, amount);
        emit DepositWithdrawn(_buyer, token, amount);
    }

    // ==================== User Operations ====================

    /// @notice Buyer withdraws deposit for a specified token (after cooldown period expires)
    function withdrawDeposit(address token) external noContract nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        uint256 amt = depositBalance[msg.sender][token];
        if (amt == 0) revert NoBalance();
        if (!canWithdraw(msg.sender)) revert CooldownActive();
        depositBalance[msg.sender][token] = 0;
        _safeTransferToUser(token, msg.sender, amt);
        emit DepositWithdrawn(msg.sender, token, amt);
    }

    // ==================== Query Functions ====================

    function canWithdraw(address user) public view returns (bool) {
        // [M-05 fix]: Check if user has active dispute
        if (hasDispute[user]) return false;
        if (activeTradeCount[user] > 0) return false;
        // [C-10 fix]: Check if user has active C2C orders (buy/sell orders)
        if (activeC2COrderCount[user] > 0) return false;
        if (cooldownStart[user] == 0) return true;
        return block.timestamp >= cooldownStart[user] + COOLDOWN_PERIOD;
    }

    /// @notice Get full deposit info for a buyer on a specified token
    function getDepositInfo(address _buyer, address token) external view returns (
        uint256 depositBal, uint256 frozenAmount, uint256 active, bool canWithdraw_, uint256 unlockTime
    ) {
        bool ok = canWithdraw(_buyer);
        uint256 unlock = 0;
        if (!ok) {
            if (activeTradeCount[_buyer] > 0) {
                unlock = type(uint256).max;
            } else {
                unlock = cooldownStart[_buyer] + COOLDOWN_PERIOD;
            }
        }
        return (
            depositBalance[_buyer][token],
            0, // CooldownManager does not distinguish frozen amounts (C2C deposits are deducted upon penalize/release)
            activeTradeCount[_buyer],
            ok,
            unlock
        );
    }

    /// @notice Get buyer's USDT deposit balance (frontend convenience query)
    function getUsdtDepositBalance(address _buyer) external view returns (uint256 usdtBal) {
        usdtBal = depositBalance[_buyer][tokens[0]];
    }

    function tokenCount() external view returns (uint256) { return tokens.length; }

    // ==================== Safe Transfer ====================

    function _safeTransferToUser(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            pendingWithdrawals[to][token] += amount;
            emit TransferPending(to, token, amount);
        }
    }

    /// @notice Claim pending token from failed transfers
    function claimPending(address token) external noContract nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        uint256 amount = pendingWithdrawals[msg.sender][token];
        if (amount == 0) revert NoBalance();
        pendingWithdrawals[msg.sender][token] = 0;
        if (!IERC20(token).transfer(msg.sender, amount)) revert TransferFailed();
    }
}
