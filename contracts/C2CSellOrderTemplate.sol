// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #5: C2CSellOrderTemplate — C2C Sell Order Template Contract
 * Responsibility: Manage a single USDT sell order (escrow, locking, release, cancellation)
 * Deployment: Used as a template, cloned by C2CFactory via EIP-1167 minimal proxy
 *
 * Workflow:
 *   1. Seller creates a sell order via C2CFactory, USDT is transferred into this contract for escrow
 *   2. When a buyer places an order, the corresponding amount is locked (lockAmount)
 *   3. After trade completion, the locked amount is released to the buyer (releaseAmount)
 *   4. When a trade is cancelled, the locked amount is unlocked back to available balance (unlockAmount)
 *   5. Seller can cancel the order at any time, unlocked USDT is returned to the seller
 */

import "./interfaces/Interfaces.sol";

/// @title C2CSellOrderTemplate - C2C Sell Order Escrow (EIP-1167 Clone)
/// @author WEB3GUARANTEE
/// @notice Manages a USDT sell order with escrow locking, partial fills, and expiration
contract C2CSellOrderTemplate {

    // ==================== Anti-Contract Call ====================

    /// @dev Reject unauthorized contract calls; only EOA or whitelisted contract wallets allowed
    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // Audit note [I-03]: Using uint256(1->2->1) instead of bool is best practice for EIP-1167 clones.
    // Clone contract storage defaults to 0; bool default false cannot distinguish "uninitialized" from "unlocked",
    // whereas uint256 is set from 0->1 in initialize(), ensuring nonReentrant works correctly in clones.
    uint256 private _locked;
    modifier nonReentrant() {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ==================== State Variables ====================

    /// Initialization flag, prevents re-initialization (replaces Constructor in clone proxy pattern)
    bool public initialized;

    /// Seller address (order creator)
    address public seller;

    /// C2C language market
    string public language;

    /// Order listing title
    string public title;

    /// Payment token used for this sell order (USDT)
    address public paymentToken;

    /// Total token amount for the sell order (USDT smallest precision, typically 6 decimals)
    uint256 public tokenAmount;

    /// Fiat unit price, fiat price per USDT, scaled by 1e6
    uint256 public price; // fiat per USDT, scaled 1e6

    /// Supported payment methods (e.g. "alipay", "wechat", "bank" string identifiers)
    string[] public paymentMethods;

    /// Fiat currency type (e.g. "CNY", "USD", "EUR")
    string public fiatType;

    /// Buyer payment window in seconds. Seller sets it when publishing the sell order;
    /// each buyer trade uses create time + this window as its payment deadline.
    uint256 public expireTime;

    /// Minimum trade amount per transaction (USDT), buyer order amount must not be below this
    uint256 public minTradeAmount;

    /// Whether buyer deposit is required (optional seller configuration)
    bool public requireBuyerDeposit;

    /// Buyer deposit rate (basis points, 10000=100%), only effective when requireBuyerDeposit is true
    /// Example: 1000 means buyer must deposit 10% of the trade amount as collateral
    uint256 public buyerDepositRate;

    /// Currently locked USDT amount (occupied by in-progress trades)
    uint256 public lockedAmount;

    /// Filled USDT amount (cumulative amount of completed trades)
    uint256 public filledAmount;

    /// Current sell order status (Active/PartiallyFilled/Filled/Cancelled)
    C2COrderStatus public status;

    /// Factory contract address (the C2CFactory that created this sell order)
    address public factory;

    /// Cooldown manager contract address (for cooldown period checks)
    address public cooldownManager;

    /// Timestamp when the sell order reached Cancelled or Filled status, used for long-unclaimed rescue.
    uint256 public endTime;

    /// Timestamp of last price update (for 5-minute cooldown restriction)
    uint256 public lastUpdateTime;

    /// Authorized trade contract address mapping (only factory-created trade contracts can lock/release)
    mapping(address => bool) public authorizedTrades;

    /// Pending withdrawal balance stored when transfer fails
    mapping(address => uint256) public pendingWithdrawals;

    // ==================== Events ====================

    /// Emitted when sell order is cancelled (lockedAmount > 0 means funds are still in active trades, must wait for trades to end then claim via claimRemaining)
    event Cancelled(uint256 lockedAmount);

    /// Emitted when sell order price is updated (for frontend monitoring)
    event OrderUpdated(uint256 newPrice);

    /// Emitted when a trade locks partial USDT, records locked amount and trade contract address
    event AmountLocked(uint256 amount, address tradeContract);

    /// Emitted when locked amount is unlocked (trade cancelled)
    event AmountUnlocked(uint256 amount);

    /// Emitted when locked amount is released to buyer (trade completed)
    event AmountReleased(uint256 amount, address to);

    /// Emitted when seller claims remaining USDT
    event Claimed(uint256 amount);
    event TransferPending(address indexed to, uint256 amount);

    // ==================== Modifiers ====================

    /// Only seller can call
    modifier onlySeller() { if (msg.sender != seller) revert NotSeller(); _; }

    /// Only factory contract can call
    modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }

    /// Only authorized trade contracts can call (authorized by factory when creating trades)
    modifier onlyAuthorizedTrade() {
        if (!authorizedTrades[msg.sender]) revert NotAuthorizedTrade();
        _;
    }

    // ==================== Initialization ====================

    /**
     * @notice Initialize sell order contract (replaces Constructor, used in clone proxy pattern)
     * @dev Can only be called once, called by C2CFactory immediately after cloning
     * @param p Sell order initialization parameter struct
     */
    function initialize(SellOrderInitParams calldata p) external {
        if (initialized) revert AlreadyInit();
        if (p.paymentToken == address(0)) revert PaymentTokenRequired();
        initialized = true;
        _locked = 1;
        seller = p.seller;
        language = p.language;
        title = p.title;
        paymentToken = p.paymentToken;
        tokenAmount = p.tokenAmount;
        price = p.price;
        for (uint256 i = 0; i < p.paymentMethods.length; ) {
            paymentMethods.push(p.paymentMethods[i]);
            unchecked { i++; }
        }
        fiatType = p.fiatType;
        expireTime = p.expireTime;
        minTradeAmount = p.minTradeAmount;
        requireBuyerDeposit = p.requireBuyerDeposit;
        buyerDepositRate = p.buyerDepositRate;
        factory = p.factory;
        cooldownManager = p.cooldownManager;
        status = C2COrderStatus.Active;
    }

    // ==================== Seller Operations ====================

    /**
     * @notice Seller updates sell order price
     * @dev Can only modify when no trades are locked (prevents price tampering during active trades)
     *      Sell order must be in Active or PartiallyFilled status
     * Caller: Only seller (onlySeller)
     * @param _price New fiat unit price (precision 1e6)
     */
    function updateOrder(uint256 _price) external onlySeller noContract {
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        if (block.timestamp < lastUpdateTime + 5 minutes) revert UpdateCooldown();
        if (lockedAmount != 0) revert HasLockedTrades();
        if (_price == 0) revert InvalidPrice();
        price = _price;
        lastUpdateTime = block.timestamp;
        emit OrderUpdated(_price);
    }

    /**
     * @notice Factory authorizes a trade contract (only factory can call)
     * @dev Factory calls this when creating a trade, adding the new trade contract to the authorized list
     * @param trade Trade contract address
     */
    function authorizeTrade(address trade) external onlyFactory {
        authorizedTrades[trade] = true;
    }

    /**
     * @notice Seller actively cancels the sell order
     * @dev Only seller can call; only Active or PartiallyFilled status can be cancelled
     *      Must have no active trades (lockedAmount == 0)
     *      After cancellation, remaining USDT is automatically returned to seller's wallet
     */
    function cancel() external onlySeller noContract nonReentrant {
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        if (lockedAmount != 0) revert HasLockedTrades();
        status = C2COrderStatus.Cancelled;
        endTime = block.timestamp;
        IC2CFactory(factory).sellOrderEnded(address(this));
        uint256 remaining = IERC20(paymentToken).balanceOf(address(this));
        if (remaining > 0) {
            _safeTransferToUser(seller, remaining);
            emit Claimed(remaining);
        }
        emit Cancelled(0);
    }

    /**
     * @notice Factory force-cancels the sell order (called automatically during Zombie Deposit Recycling)
     * @dev Only factory contract can call, bypasses onlySeller and noContract restrictions
     *      Must have no active trades (lockedAmount == 0)
     *      After cancellation, remaining USDT is automatically returned to seller's wallet
     */
    function cancelByFactory() external onlyFactory nonReentrant {
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        if (lockedAmount != 0) revert HasLockedTrades();
        status = C2COrderStatus.Cancelled;
        endTime = block.timestamp;
        IC2CFactory(factory).sellOrderEnded(address(this));
        uint256 remaining = IERC20(paymentToken).balanceOf(address(this));
        if (remaining > 0) {
            _safeTransferToUser(seller, remaining);
            emit Claimed(remaining);
        }
        emit Cancelled(1);
    }

    /**
     * @notice Admin force-delists the sell order (e.g. removing an off-shelf / zombie listing)
     * @dev Only admin can call. Requires no active (locked) trades so in-flight trades are never
     *      disturbed — they must be allowed to settle normally through the trade contract.
     *      The seller's remaining escrowed USDT is refunded to the SELLER (it is their own money),
     *      not swept to the platform wallet.
     *
     *      [FIX] Previously this refunded to the platform wallet/feeSplitter and bypassed the
     *      locked-amount check, which (a) confiscated the seller's own unsold USDT and (b) also
     *      swept funds locked for in-flight trades, bricking those trades (their later
     *      releaseAmount would find no balance) and double-calling the non-idempotent
     *      sellOrderEnded. Gating on lockedAmount == 0 avoids both problems.
     */
    function adminCancel() external nonReentrant {
        address settings = IC2CFactory(factory).settingsAddr();
        if (!IPlatformSettings(settings).isAdmin(msg.sender)) revert NotAdmin();
        if (status == C2COrderStatus.Cancelled || status == C2COrderStatus.Filled) revert WrongStatus();
        // Do not disturb in-flight trades: refuse while funds are locked for pending trades.
        if (lockedAmount != 0) revert HasLockedTrades();
        status = C2COrderStatus.Cancelled;
        endTime = block.timestamp;
        IC2CFactory(factory).sellOrderEnded(address(this));
        uint256 remaining = IERC20(paymentToken).balanceOf(address(this));
        if (remaining > 0) {
            // Refund the seller's own escrowed USDT (not the platform).
            _safeTransferToUser(seller, remaining);
            emit Claimed(remaining);
        }
        emit Cancelled(2);
    }

    // ==================== Trade Locking and Release ====================

    /**
     * @notice Lock a specified amount of USDT (called when buyer places an order)
     * @dev Anyone can call (typically called by C2CFactory's createTrade)
     *      Once locked, the amount cannot be used by other trades or withdrawn by the seller
     * @param amount USDT amount to lock, must be >= minTradeAmount and <= available balance
     */
    function lockAmount(uint256 amount) external onlyFactory {
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        // [H-17 fix]: Reject zero-amount lock to prevent gas waste and event pollution
        if (amount == 0) revert ZeroAmount();
        if (amount < minTradeAmount) revert BelowMin();
        uint256 available = tokenAmount - filledAmount - lockedAmount;
        if (amount > available) revert Insufficient();
        lockedAmount += amount;
        emit AmountLocked(amount, msg.sender);
    }

    /**
     * @notice Unlock a specified amount of USDT (called when trade is cancelled)
     * @dev Releases locked amount back to available balance, no token transfer
     *      Typically called by C2CTradeTemplate when a trade is cancelled
     * @param amount Amount to unlock, must not exceed current locked amount
     */
    function unlockAmount(uint256 amount) external onlyAuthorizedTrade {
        if (lockedAmount < amount) revert OverLocked();
        lockedAmount -= amount;
        emit AmountUnlocked(amount);
    }

    /**
     * @notice Release locked USDT to a specified address (called when trade completes)
     * @dev Deducts from locked amount, adds to filled amount, and transfers USDT to buyer
     *      If cumulative filled amount reaches total, sell order status changes to Filled
     *      Typically called by C2CTradeTemplate when a trade completes
     * @param amount Amount to release
     * @param to Address to receive USDT (typically the trade contract address, which then distributes)
     */
    function releaseAmount(uint256 amount, address to) external onlyAuthorizedTrade nonReentrant {
        if (lockedAmount < amount) revert OverLocked();
        lockedAmount -= amount;
        filledAmount += amount;
        if (filledAmount >= tokenAmount) {
            status = C2COrderStatus.Filled;
            endTime = block.timestamp;
            IC2CFactory(factory).sellOrderEnded(address(this));
        } else {
            status = C2COrderStatus.PartiallyFilled;
        }
        if (!IERC20(paymentToken).transfer(to, amount)) revert TransferFailed();
        emit AmountReleased(amount, to);
    }

    // ==================== Seller Claim Remaining USDT ====================

    /**
     * @notice Seller withdraws remaining USDT from the sell order
     * @dev Can only withdraw after sell order is Cancelled or Filled
     *      And there must be no active locked trades (lockedAmount == 0)
     *      Note: 24h cooldown applies to merchant deposits, not C2C sell orders
     */
    function claimRemaining() external onlySeller noContract nonReentrant {
        if (status != C2COrderStatus.Cancelled && status != C2COrderStatus.Filled) revert NotEnded();
        if (lockedAmount != 0) revert HasLockedTrades();
        uint256 remaining = IERC20(paymentToken).balanceOf(address(this));
        if (remaining == 0) revert NothingToClaim();
        _safeTransferToUser(seller, remaining);
        emit Claimed(remaining);
    }

    // ==================== Stranded Asset Rescue ====================

    /// Stranded Asset RescueEvents
    event TokensRescued(uint256 amount, address to);

    /**
     * @notice Admin rescues long-unclaimed USDT (callable 365 days after expiration)
     * @dev Requirements: sell order ended + no locked trades + more than 365 days after it ended.
     *      The seller-configured payment window is not a sell-order delist timestamp.
     *      Verifies admin identity and platform wallet via PlatformSettings through factory
     */
    function rescueTokens() external nonReentrant {
        address settings = IC2CFactory(factory).settingsAddr();
        if (!IPlatformSettings(settings).isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        if (status != C2COrderStatus.Cancelled && status != C2COrderStatus.Filled) revert NotEnded();
        if (lockedAmount != 0) revert HasLockedTrades();
        if (endTime == 0 || block.timestamp <= endTime + 365 days) revert TooEarly();
        uint256 remaining = IERC20(paymentToken).balanceOf(address(this));
        if (remaining == 0) revert NothingToRescue();
        // Rescued funds prefer the split routing splitter (30/30/40); fall back to platformWallet when unconfigured
        address splitter = IPlatformSettings(settings).getFeeSplitter();
        address dest = splitter != address(0) ? splitter : IPlatformSettings(settings).getPlatformWallet();
        if (!IERC20(paymentToken).transfer(dest, remaining)) revert TransferFailed();
        if (dest == splitter) {
            try IPlatformFeeSplitter(splitter).distribute(paymentToken, remaining) {} catch {}
        }
        emit TokensRescued(remaining, dest);
    }

    // ==================== Query Functions ====================

    /**
     * @notice Get current available (unlocked, unfilled) USDT amount
     * @return Available USDT amount
     */
    function getAvailable() external view returns (uint256) {
        return tokenAmount - filledAmount - lockedAmount;
    }

    /**
     * @notice Get sell order basic info (dual payment channel: return value includes paymentToken)
     * @return seller_ Seller address
     * @return title_ Order listing title
     * @return tokenAmount_ Total token amount for sale
     * @return price_ Fiat unit price
     * @return paymentMethods_ Supported payment methods
     * @return fiatType_ Fiat currency type
     * @return expireTime_ Payment window in seconds after buyer places order (field name kept for ABI compatibility)
     * @return paymentToken_ Payment token (USDT)
     */
    function getOrderInfo() external view returns (
        address seller_, string memory title_, uint256 tokenAmount_, uint256 price_,
        string[] memory paymentMethods_, string memory fiatType_, uint256 expireTime_,
        address paymentToken_
    ) {
        return (seller, title, tokenAmount, price, paymentMethods, fiatType, expireTime, paymentToken);
    }

    function getPaymentMethodCount() external view returns (uint256) {
        return paymentMethods.length;
    }

    /**
     * @notice Get sell order configuration info
     * @return Min trade amount, whether deposit required, deposit rate (basis points), order status
     */
    function getOrderConfig() external view returns (
        uint256, bool, uint256, C2COrderStatus
    ) {
        return (minTradeAmount, requireBuyerDeposit, buyerDepositRate, status);
    }

    /**
     * @notice Get sell order claim info
     * @return remaining USDT balance remaining in contract
     * @return claimable Whether withdrawal is possible
     * @return unlockTime Always 0 (no cooldown for C2C sell orders)
     */
    function getClaimInfo() external view returns (uint256, bool, uint256) {
        uint256 remaining = IERC20(paymentToken).balanceOf(address(this));
        bool ended = (status == C2COrderStatus.Cancelled || status == C2COrderStatus.Filled);
        bool noLock = (lockedAmount == 0);
        bool claimable = ended && noLock && remaining > 0;
        return (remaining, claimable, 0);
    }

    // ==================== Safe Transfer ====================

    function _safeTransferToUser(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = paymentToken.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            pendingWithdrawals[to] += amount;
            emit TransferPending(to, amount);
        }
    }

    /// @notice Claim pending balance from failed transfers
    function claimPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoBalance();
        pendingWithdrawals[msg.sender] = 0;
        if (!IERC20(paymentToken).transfer(msg.sender, amount)) revert TransferFailed();
    }
}
