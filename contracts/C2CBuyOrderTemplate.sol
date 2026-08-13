// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #6: C2CBuyOrderTemplate - C2C Buy Order Template
 * Responsibility: Manages a single USDT buy order (listing, fill tracking, cancellation)
 * Deployment: Used as a template, cloned by C2CFactory via EIP-1167 minimal proxy
 *
 * Workflow:
 *   1. Buyer creates a buy order via C2CFactory (no USDT staking required, intent only)
 *   2. After seller matches, updateFilled updates the filled amount
 *   3. Buyer can cancel at any time (cancel)
 *   4. After expiration, anyone can trigger auto-cancel (triggerAutoCancel)
 */

import "./interfaces/Interfaces.sol";

/// @title C2CBuyOrderTemplate - C2C Buy Order (EIP-1167 Clone)
/// @author WEB3GUARANTEE
/// @notice Manages a fiat-to-USDT buy order with matching and trade creation
contract C2CBuyOrderTemplate {

    // ==================== Anti-Contract Call ====================

    /// @dev Reject unauthorized contract calls; only EOA or whitelisted contract wallets allowed
    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // [H-07 fix]: Add reentrancy guard for state-changing functions
    uint256 private _locked;
    modifier nonReentrant() {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ==================== State Variables ====================

    /// Initialization flag to prevent re-initialization (replaces constructor in clone proxy pattern)
    bool public initialized;

    /// Buyer address (order creator)
    address public buyer;

    /// C2C language market
    string public language;

    /// Order listing title
    string public title;

    /// Payment token for this buy order (USDT)
    address public paymentToken;

    /// Total token amount for the buy order (USDT smallest precision)
    uint256 public tokenAmount;

    /// [H-22 fix]: Original total capacity, never modified after init. tokenAmount may shrink during
    /// arbitration freeze but can be restored to this value when unfrozen.
    uint256 public originalTokenAmount;

    /// Fiat unit price per USDT, scaled by 1e6
    uint256 public price;

    /// Supported payment methods
    string[] public paymentMethods;

    /// Fiat currency type (e.g. "CNY", "USD", "EUR")
    string public fiatType;

    /// Payment window after a seller accepts this buy order, in seconds.
    /// Kept as expireTime for ABI compatibility with existing readers.
    uint256 public expireTime;

    /// Minimum trade amount per transaction (USDT)
    uint256 public minTradeAmount;

    /// Filled USDT amount (cumulative completed trades)
    uint256 public filledAmount;

    /// Locked USDT amount (cumulative in-flight/active trades not yet completed or cancelled).
    /// Mirrors the sell-order locking model to prevent concurrent over-acceptance:
    /// a buy order can only be accepted while amount <= tokenAmount - filledAmount - lockedAmount.
    uint256 public lockedAmount;

    /// Current buy order status (Active/PartiallyFilled/Filled/Cancelled)
    C2COrderStatus public status;

    /// Factory contract address (the C2CFactory that created this buy order)
    address public factory;

    /// Merchant deposit contract used to freeze buy-order collateral
    address public merchantDeposit;

    /// Total deposit frozen for this buy order
    uint256 public frozenDepositAmount;

    /// Amount of frozen deposit already released as the buy order is filled
    uint256 public releasedDepositAmount;

    /// Buy-order collateral rate: 10% of remaining order amount
    uint256 public constant BUY_ORDER_DEPOSIT_RATE = 1000;

    /// Whether this buy order's available capacity has been frozen down due to the buyer being
    /// taken to community arbitration on one of their buy-order trades. When true, available is 0
    /// (tokenAmount was shrunk to filledAmount + lockedAmount) and no new accepts are possible,
    /// but any in-flight (locked) trades continue to settle normally. Display-only flag; correctness
    /// of getAvailable() does not depend on it.
    bool public availableFrozen;

    /// Last price update timestamp (for 5-minute cooldown)
    uint256 public lastUpdateTime;

    // ==================== Events ====================

    /// Emitted when the buy order is cancelled
    event Cancelled();

    /// Emitted when the buy order price is updated (for frontend listeners)
    event OrderUpdated(uint256 newPrice);

    /// Emitted when filled amount is updated, recording the fill amount
    event FilledUpdated(uint256 amount);

    /// Emitted when an amount is locked for an in-flight trade (buy order accepted)
    event AmountLocked(uint256 amount);

    /// Emitted when a locked amount is released back to available (trade cancelled/timed out)
    event AmountUnlocked(uint256 amount);

    /// Emitted when buy-order merchant deposit is frozen
    event BuyerDepositFrozen(address indexed depositContract, address indexed token, uint256 amount);

    /// Emitted when buy-order merchant deposit is released
    event BuyerDepositReleased(address indexed token, uint256 amount);

    /// Emitted when buy-order buyer deposit is forfeited to an arbitration case (seller won)
    event BuyerDepositForfeited(address indexed caseContract, address indexed token, uint256 amount);

    /// Emitted when the buy order's available capacity is frozen down for arbitration (buyer is respondent).
    event AvailableFrozenForArbitration(uint256 releasedDeposit, uint256 newTokenAmount);

    /// [H-22 fix]: Emitted when the buy order's available capacity is unfrozen after arbitration resolves
    event AvailableUnfrozen(uint256 restoredTokenAmount);

    // ==================== Modifiers ====================

    /// Only buyer can call
    modifier onlyBuyer() { if (msg.sender != buyer) revert NotBuyer(); _; }

    // ==================== Initialization ====================

    /**
     * @notice Initialize buy order contract (clone proxy pattern, called by C2CFactory immediately after cloning)
     * @dev Can only be called once
     * @param p Buy order initialization parameter struct
     */
    function initialize(BuyOrderInitParams calldata p) external {
        if (initialized) revert AlreadyInit();
        if (p.paymentToken == address(0)) revert PaymentTokenRequired();
        initialized = true;
        _locked = 1;  // Initialize reentrancy guard
        buyer = p.buyer;
        language = p.language;
        title = p.title;
        paymentToken = p.paymentToken;
        tokenAmount = p.tokenAmount;
        originalTokenAmount = p.tokenAmount; // [H-22 fix]: Store original capacity
        price = p.price;
        for (uint256 i = 0; i < p.paymentMethods.length; ) {
            paymentMethods.push(p.paymentMethods[i]);
            unchecked { i++; }
        }
        fiatType = p.fiatType;
        expireTime = p.expireTime;
        minTradeAmount = p.minTradeAmount;
        factory = p.factory;
        status = C2COrderStatus.Active;
    }

    // ==================== Buyer Operations ====================

    /**
     * @notice Buyer updates buy order price
     * @dev Buy order must be in Active or PartiallyFilled status
     * Caller: buyer only (onlyBuyer)
     * @param _price New fiat unit price (scaled 1e6)
     */
    function updateOrder(uint256 _price) external onlyBuyer noContract {
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        if (block.timestamp < lastUpdateTime + 5 minutes) revert UpdateCooldown();
        if (_price == 0) revert InvalidPrice();
        price = _price;
        lastUpdateTime = block.timestamp;
        emit OrderUpdated(_price);
    }

    /**
     * @notice Buyer cancels the buy order
     * @dev Only buyer can call; only Active or PartiallyFilled orders can be cancelled
     *      Buy orders have no USDT staked, so no refund is needed
     */
    function cancel() external onlyBuyer noContract nonReentrant {
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        // [H-01 fix]: Prevent cancellation when there are active (locked) trades in flight
        if (lockedAmount > 0) revert HasActiveTransactions();
        status = C2COrderStatus.Cancelled;
        _releaseRemainingDeposit();
        IC2CFactory(factory).buyOrderEnded(address(this));
        emit Cancelled();
    }

    /**
     * @notice Factory force-cancels the buy order (called during zombie deposit recycling)
     * @dev Only factory can call, bypasses onlyBuyer and noContract restrictions
     */
    function cancelByFactory() external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        status = C2COrderStatus.Cancelled;
        _releaseRemainingDeposit();
        IC2CFactory(factory).buyOrderEnded(address(this));
        emit Cancelled();
    }

    /**
     * @notice Admin force-delists the buy order (for content moderation)
     * @dev Only admin can call. Requires no active (locked) trades so in-flight trades are never
     *      disturbed — they must be allowed to settle normally through the trade contract.
     *
     *      [FIX] Previously this bypassed the locked-amount check and released ALL frozen deposit
     *      (including the slice backing an in-flight trade). That prematurely freed the in-flight
     *      trade's deposit AND, once that trade settled, updateFilled() re-animated this order from
     *      Cancelled back to PartiallyFilled while it was already removed from the active index —
     *      producing a zombie order whose stale buyOrderIndex==0 corrupted activeBuyOrders[0] on the
     *      next buyOrderEnded. Gating on lockedAmount == 0 (mirroring the seller side and the buyer's
     *      own cancel()) avoids all of these. In-flight trades on a bad actor are handled via the
     *      community-dispute / arbitration path, not by force-delisting mid-trade.
     */
    function adminCancel() external nonReentrant {
        address settings = IC2CFactory(factory).settingsAddr();
        if (!IPlatformSettings(settings).isAdmin(msg.sender)) revert NotAdmin();
        if (status == C2COrderStatus.Cancelled || status == C2COrderStatus.Filled) revert WrongStatus();
        // Do not disturb in-flight trades: refuse while capacity is locked for pending trades.
        if (lockedAmount > 0) revert HasActiveTransactions();
        status = C2COrderStatus.Cancelled;
        // Release deposit to prevent permanent lock
        _releaseRemainingDeposit();
        IC2CFactory(factory).buyOrderEnded(address(this));
        emit Cancelled();
    }

    // ==================== Fill Updates ====================

    /**
     * @notice Lock a specified amount for an in-flight trade (called by factory on acceptBuyOrder)
     * @dev Only factory can call. Reserves the amount so concurrent accepts cannot over-commit
     *      beyond the order's remaining capacity. Mirrors C2CSellOrderTemplate.lockAmount.
     * @param amount USDT amount to lock, must be <= available (tokenAmount - filledAmount - lockedAmount)
     */
    function lockAmount(uint256 amount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) revert WrongStatus();
        // [H-22 fix]: No new locks while frozen for arbitration (order is off the shelf).
        if (availableFrozen) revert Insufficient();
        // [H-16 fix]: Reject zero-amount lock to prevent gas waste and event pollution
        if (amount == 0) revert ZeroAmount();
        uint256 available = tokenAmount - filledAmount - lockedAmount;
        if (amount > available) revert Insufficient();
        lockedAmount += amount;
        emit AmountLocked(amount);
    }

    /**
     * @notice Release a locked amount back to available (called by factory when a trade is cancelled/timed out)
     * @dev Only factory can call (factory forwards from a factory-created trade). No token movement;
     *      the seller's USDT for a buy-order trade is escrowed in the trade contract, not here.
     * @param amount Amount to unlock, must not exceed current locked amount
     */
    function unlockAmount(uint256 amount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (lockedAmount < amount) revert OverLocked();
        lockedAmount -= amount;
        // [FIX] When the order's available capacity is frozen for arbitration (availableFrozen),
        // the unlocked capacity can NEVER be re-accepted (getAvailable()==0, lockAmount() reverts),
        // so its backing deposit slice would otherwise be stranded frozen forever. Release it back
        // to the buyer's MD available balance now. In the normal (non-frozen) case we intentionally
        // keep the deposit frozen: the unlocked capacity returns to available and stays collateralized
        // for a future re-accept; that deposit is released later via _releaseRemainingDeposit on order end.
        if (availableFrozen) {
            _releaseDepositForFill(amount);
        }
        emit AmountUnlocked(amount);
    }

    /**
     * @notice Update filled amount (only factory can call)
     * @dev Reserved for future buy-order matching flow; current trade flow is initiated from sell orders.
     * @param amount USDT amount filled in this transaction
     */
    function updateFilled(uint256 amount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        uint256 remainingAmount = tokenAmount > filledAmount ? tokenAmount - filledAmount : 0;
        uint256 effectiveAmount = amount > remainingAmount ? remainingAmount : amount;
        if (effectiveAmount == 0) revert ZeroAmount();
        // This in-flight amount was locked at accept time; release the lock as it converts to filled.
        if (lockedAmount >= effectiveAmount) {
            lockedAmount -= effectiveAmount;
        } else {
            lockedAmount = 0;
        }
        filledAmount += effectiveAmount;
        _releaseDepositForFill(effectiveAmount);
        if (filledAmount >= tokenAmount) {
            status = C2COrderStatus.Filled;
            _releaseRemainingDeposit();
            IC2CFactory(factory).buyOrderEnded(address(this));
        } else {
            status = C2COrderStatus.PartiallyFilled;
        }
        emit FilledUpdated(effectiveAmount);
    }

    function lockBuyerDeposit(address depositContract) external {
        if (msg.sender != factory) revert NotFactory();
        if (depositContract == address(0)) revert NoDepositContract();
        if (merchantDeposit != address(0)) revert AlreadySet();
        uint256 amount = tokenAmount * BUY_ORDER_DEPOSIT_RATE / 10000;
        if (amount == 0) revert ZeroAmount();
        merchantDeposit = depositContract;
        frozenDepositAmount = amount;
        IMerchantDeposit(depositContract).authorizeProduct(address(this));
        IMerchantDeposit(depositContract).freezeDeposit(amount, paymentToken);
        emit BuyerDepositFrozen(depositContract, paymentToken, amount);
    }

    function _releaseDepositForFill(uint256 amount) internal {
        if (merchantDeposit == address(0) || amount == 0) return;
        // [H-05 fix]: Calculate releasable based on actual remaining frozen amount to avoid precision drift
        uint256 remaining = frozenDepositAmount > releasedDepositAmount ? frozenDepositAmount - releasedDepositAmount : 0;
        uint256 releasable = amount * BUY_ORDER_DEPOSIT_RATE / 10000;
        if (releasable > remaining) releasable = remaining;
        if (releasable > 0) {
            releasedDepositAmount += releasable;
            IMerchantDeposit(merchantDeposit).unfreezeDepositAmount(releasable, paymentToken);
            emit BuyerDepositReleased(paymentToken, releasable);
        }
    }

    function _releaseRemainingDeposit() internal {
        if (merchantDeposit == address(0)) return;
        uint256 remaining = frozenDepositAmount > releasedDepositAmount ? frozenDepositAmount - releasedDepositAmount : 0;
        if (remaining > 0) {
            releasedDepositAmount += remaining;
            IMerchantDeposit(merchantDeposit).unfreezeDepositAmount(remaining, paymentToken);
            emit BuyerDepositReleased(paymentToken, remaining);
        }
    }

    /// @notice Forfeit the buyer's proportional buy-order deposit for a disputed fill to the arbitration case (seller won).
    /// @dev Only a factory-created trade may call. Transfers the proportional deposit to the case contract AND
    ///      shrinks tokenAmount by the disputed slice. The disputed amount was NOT a real fill (the seller's escrow
    ///      is returned via _returnToSeller), so we must NOT inflate filledAmount; instead we reduce total capacity.
    ///      This keeps the deposit invariant (remaining frozen = 10% x remaining tokenAmount) and lets filledAmount
    ///      stay a pure "really traded" counter for accurate display.
    /// @param amount Disputed fill amount (the trade's tokenAmount)
    /// @param caseContract Arbitration case contract receiving the forfeited deposit
    /// @param maxForfeit Upper bound on the amount forfeited to the case (arbitration-fee shortfall left
    ///        uncovered by the buyer's MD guarantee). The freed deposit slice above this bound is unfrozen
    ///        back to the buyer's available balance instead of being forfeited — prevents double-charging
    ///        the 10% arbitration fee when the MD guarantee already paid it.
    /// @return forfeit Amount actually deducted to the case
    function forfeitDepositToCase(uint256 amount, address caseContract, uint256 maxForfeit) external nonReentrant returns (uint256 forfeit) {
        if (!IC2CFactory(factory).isFactoryTrade(msg.sender)) revert NotFactoryTrade();
        if (caseContract == address(0)) revert ZeroAddress();
        if (merchantDeposit == address(0)) return 0;
        uint256 remainingAmount = tokenAmount > filledAmount ? tokenAmount - filledAmount : 0;
        uint256 effectiveAmount = amount > remainingAmount ? remainingAmount : amount;
        if (effectiveAmount == 0) return 0;
        // The deposit slice freed by shrinking this disputed capacity.
        uint256 freedSlice = effectiveAmount * BUY_ORDER_DEPOSIT_RATE / 10000;
        uint256 remaining = frozenDepositAmount > releasedDepositAmount ? frozenDepositAmount - releasedDepositAmount : 0;
        if (freedSlice > remaining) freedSlice = remaining;
        // Only the arbitration-fee shortfall is forfeited to the case; the rest returns to the buyer.
        forfeit = freedSlice <= maxForfeit ? freedSlice : maxForfeit;
        uint256 refund = freedSlice - forfeit;
        // NOTE: do NOT release lockedAmount here. The seller-wins arbitration path calls _returnToSeller()
        // (which unlocks) AND this forfeit in the same tx; the unlock is owned by _returnToSeller. We shrink
        // tokenAmount (not filledAmount) so available = total - filled - locked correctly reflects the lost
        // capacity while filledAmount keeps representing only real, completed trades.
        tokenAmount -= effectiveAmount;
        if (freedSlice > 0) {
            releasedDepositAmount += freedSlice;
            if (forfeit > 0) {
                IMerchantDeposit(merchantDeposit).deductFromFrozen(forfeit, caseContract, paymentToken);
            }
            if (refund > 0) {
                // Arbitration fee already covered by the buyer's MD guarantee — return the excess slice
                // to the buyer's available balance rather than forfeiting it.
                IMerchantDeposit(merchantDeposit).unfreezeDepositAmount(refund, paymentToken);
            }
        }
        if (filledAmount >= tokenAmount) {
            // All remaining capacity consumed (and nothing left in flight) -> order is dead.
            status = C2COrderStatus.Filled;
            _releaseRemainingDeposit();
            IC2CFactory(factory).buyOrderEnded(address(this));
        } else if (filledAmount > 0) {
            status = C2COrderStatus.PartiallyFilled;
        }
        // else: no real fill yet, leave status (Active/PartiallyFilled) unchanged so it stays acceptable.
        emit BuyerDepositForfeited(caseContract, paymentToken, forfeit);
    }

    /// @notice Delist this buy order because the buyer was taken to community arbitration on a
    ///         buy-order trade. Sets availableFrozen (available -> 0, no new accepts) and releases
    ///         only the AVAILABLE (unfilled) slice's frozen deposit back to the buyer's MD available balance.
    /// @dev [H-22 fix v3]: Release only the available-slice deposit; PRESERVE the in-flight (locked)
    ///      slice's deposit floor (lockedAmount x 10%). Rationale: each in-flight buy-order trade (e.g.
    ///      A-C, still trading) has its OWN arbitration exposure guaranteed by this locked slice. The
    ///      disputed trade's (A-B) fee/payout is covered by ITS buyerGuarantee, frozen separately at
    ///      dispute-raise time. Releasing the locked slice back to MD available would let the disputed
    ///      trade's buyerGuarantee freeze immediately re-grab it (available balloons by the locked slice),
    ///      so the seller of the disputed trade would wrongly be paid out of the OTHER in-flight trade's
    ///      collateral. This mirrors seizeForArbitration's lockedReserve floor so the two stay consistent.
    ///      Only the factory can call. No-op (returns 0) when the order is not Active/PartiallyFilled,
    ///      so the factory's batch loop is never interrupted.
    /// @return releasedDeposit Amount of deposit released back to MD available
    function freezeAvailableForArbitration() external nonReentrant returns (uint256 releasedDeposit) {
        if (msg.sender != factory) revert NotFactory();
        if (status != C2COrderStatus.Active && status != C2COrderStatus.PartiallyFilled) return 0;
        // Release only the AVAILABLE slice's deposit; keep the locked slice's floor (lockedAmount x 10%)
        // so in-flight trades' own arbitration collateral is never re-grabbed by the disputed trade.
        if (merchantDeposit != address(0)) {
            uint256 remaining = frozenDepositAmount > releasedDepositAmount ? frozenDepositAmount - releasedDepositAmount : 0;
            uint256 lockedReserve = lockedAmount * BUY_ORDER_DEPOSIT_RATE / 10000;
            uint256 releasable = remaining > lockedReserve ? remaining - lockedReserve : 0;
            if (releasable > 0) {
                releasedDepositAmount += releasable;
                IMerchantDeposit(merchantDeposit).unfreezeDepositAmount(releasable, paymentToken);
                releasedDeposit = releasable;
            }
        }
        // Set availableFrozen flag: getAvailable() returns 0 and lockAmount() reverts, so no new accepts.
        // tokenAmount is preserved (not shrunk) so display/original capacity survives.
        availableFrozen = true;
        emit AvailableFrozenForArbitration(releasedDeposit, tokenAmount);
    }

    /// @notice Unfreeze a buy order's available capacity after arbitration resolves (factory-only)
    /// @dev [H-22 fix]: Restore tokenAmount to originalTokenAmount, clear availableFrozen flag
    function unfreezeAvailable() external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (!availableFrozen) return; // Already unfrozen, no-op
        // Restore original capacity
        tokenAmount = originalTokenAmount;
        availableFrozen = false;
        emit AvailableUnfrozen(tokenAmount);
    }

    /// @notice Seize BuyOrder's remaining frozen deposit for post-completion arbitration.
    /// @dev Only a factory-created trade may call. Transfers frozen allocation from BuyOrder to the trade contract
    ///      so the trade can later deductFromFrozen during resolution. If all deposit is consumed, ends the buy order.
    /// @param amount Max amount to seize from the BuyOrder's remaining frozen deposit
    /// @param token Payment token
    /// @return seized Actual amount seized (may be less than requested if insufficient)
    function seizeForArbitration(uint256 amount, address token) external nonReentrant returns (uint256 seized) {
        if (!IC2CFactory(factory).isFactoryTrade(msg.sender)) revert NotFactoryTrade();
        if (merchantDeposit == address(0)) return 0;
        if (token != paymentToken) return 0;
        uint256 remaining = frozenDepositAmount > releasedDepositAmount ? frozenDepositAmount - releasedDepositAmount : 0;
        // Locked floor: never seize the deposit backing in-flight (locked) trades. The remaining frozen
        // deposit covers both the available slice and the locked slice; only the portion above
        // lockedAmount x 10% is seizable. After freezeAvailableForArbitration() this floor makes seize a
        // no-op (remaining == locked x 10%), guaranteeing locked trades' guarantee is preserved.
        uint256 lockedReserve = lockedAmount * BUY_ORDER_DEPOSIT_RATE / 10000;
        uint256 seizable = remaining > lockedReserve ? remaining - lockedReserve : 0;
        seized = amount > seizable ? seizable : amount;
        if (seized > 0) {
            releasedDepositAmount += seized;
            IMerchantDeposit(merchantDeposit).transferFrozenAllocation(seized, msg.sender, token);
        }
        // If all deposit consumed, end the buy order (it can no longer guarantee new trades)
        if (frozenDepositAmount <= releasedDepositAmount) {
            uint256 remainingFillable = tokenAmount > filledAmount ? tokenAmount - filledAmount : 0;
            if (remainingFillable > 0) {
                filledAmount = tokenAmount;
                status = C2COrderStatus.Filled;
                IC2CFactory(factory).buyOrderEnded(address(this));
            }
        }
    }

    // ==================== Auto Cancel ====================

    /**
     * @notice Buy orders do not expire by themselves; expireTime is the post-trade payment window.
     * @dev Kept for ABI compatibility. Buyers can cancel manually and zombie cleanup can cancel by factory.
     */
    function triggerAutoCancel() external pure {
        revert NotExpired();
    }

    // ==================== Query Functions ====================

    /**
     * @notice Get remaining available USDT amount
     * @return Remaining USDT = total - filled - locked (in-flight). Defensive against underflow
     *         because seizeForArbitration may force filledAmount up to tokenAmount.
     * @dev [H-22 fix]: When availableFrozen is set (buyer taken to community arbitration on a
     *      buy-order trade), available is 0 — the order is off the shelf and no new trades can be
     *      accepted. In-flight (locked) trades keep settling normally. This is the read-side that
     *      enforces the freeze; freezeAvailableForArbitration only sets the flag and releases the
     *      available slice's deposit, so without this gate the order would wrongly stay acceptable.
     */
    function getAvailable() external view returns (uint256) {
        if (availableFrozen) return 0;
        uint256 used = filledAmount + lockedAmount;
        return tokenAmount > used ? tokenAmount - used : 0;
    }

    /**
     * @notice Get buy order full info (dual payment channel: return value includes paymentToken)
     */
    function getOrderInfo() external view returns (
        address buyer_, string memory title_, address paymentToken_, uint256 tokenAmount_, uint256 price_,
        uint256 expireTime_, uint256 minTradeAmount_, C2COrderStatus status_
    ) {
        buyer_ = buyer;
        title_ = title;
        paymentToken_ = paymentToken;
        tokenAmount_ = tokenAmount;
        price_ = price;
        expireTime_ = expireTime;
        minTradeAmount_ = minTradeAmount;
        status_ = status;
    }

    function getOrderText() external view returns (string[] memory paymentMethods_, string memory fiatType_) {
        paymentMethods_ = paymentMethods;
        fiatType_ = fiatType;
    }

    function getPaymentMethodCount() external view returns (uint256) {
        return paymentMethods.length;
    }
}
