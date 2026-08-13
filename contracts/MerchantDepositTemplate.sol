// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #4: MerchantDepositTemplate — Merchant Deposit Template Contract
 *
 * Responsibility: Manages a single merchant's USDT deposit in one contract instance.
 *                 Balances and frozen amounts are token-keyed.
 *
 * Deploy order: 4th deployment (as template), instances created by DepositFactory via clone.
 *
 * Business flow:
 *   1. Merchant calls deposit(amount, token) for USDT (>= 500, cumulative <= 1M)
 *   2. While Active, merchant can operate normally; balances tracked per token
 *   3. Admin/CS can freeze (status=Frozen); freeze() marks the whole account
 *   4. Authorized product/case contracts call freezeDeposit to lock funds
 *   5. Arbitration buyer-wins triggers deductFromFrozen
 *   6. Merchant withdraws; status becomes Withdrawn when balance is zero
 */

import "./interfaces/Interfaces.sol";

/// @title MerchantDepositTemplate - Merchant Deposit Escrow (EIP-1167 Clone)
/// @author WEB3GUARANTEE
/// @notice Holds a merchant's USDT deposit in one contract
contract MerchantDepositTemplate {

    // ==================== Anti-Contract Call ====================

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // Audit note [I-03]: clone-safe reentrancy guard with uint256(1->2->1)
    uint256 private _locked;
    modifier nonReentrant() {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ==================== State Variables ====================

    bool public initialized;
    address public merchant;
    address public factory;
    DepositStatus public status;
    IPlatformSettings public settings;

    /// Registered payment channel token list (convention: [0]=USDT, passed in by DepositFactory.initialize)
    address[] public tokens;
    /// token => whether it is a valid payment channel (O(1) check)
    mapping(address => bool) public isToken;

    /// Current balance per token (USDT minimum precision)
    mapping(address => uint256) public balanceOf;
    /// Current total frozen amount per token
    mapping(address => uint256) public frozenAmountOf;
    /// Minimum deposit amount per token (calculated by token decimals)
    mapping(address => uint256) public minDeposit;
    /// Maximum cumulative deposit amount per token (calculated by token decimals)
    mapping(address => uint256) public maxDeposit;

    /// caller => token => frozen amount by this caller on this token (per auction/case contract dimension)
    mapping(address => mapping(address => uint256)) public callerFrozenAmounts;

    /// Authorized product contracts (can call deduct)
    mapping(address => bool) public authorizedProducts;
    /// Authorized arbitration case contracts (can call freezeDeposit / unfreezeDeposit / deductFromFrozen)
    mapping(address => bool) public authorizedCases;

    /// Pending withdrawal balance when transfer fails: to => token => amount
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;
    /// Amount not yet reported to PlatformSettings.recordDepositOut when transfer fails: to => token => amount
    mapping(address => mapping(address => uint256)) public pendingRecordOut;

    /// Zombie deposit threshold period: 365 days (production)
    uint256 public constant ZOMBIE_PERIOD = 365 days; // production
    /// Last activity time
    uint256 public lastActivityTime;

    // ==================== Events ====================

    event Deposited(address indexed merchant, address indexed token, uint256 amount);
    event Withdrawn(address indexed merchant, address indexed token, uint256 amount);
    event Frozen(address indexed token, uint256 amount);
    event Unfrozen(address indexed token, uint256 amount);
    event Deducted(address indexed token, uint256 amount, address to);
    event Recycled(address indexed merchant, address indexed token, uint256 amount);
    event TransferPending(address indexed to, address indexed token, uint256 amount);
    event DepositFrozen(address indexed caller, address indexed token, uint256 amount);
    event DepositUnfrozen(address indexed caller, address indexed token, uint256 amount);
    event DepositDeducted(address indexed caller, address indexed token, uint256 amount, address to);
    // [M-04 fix]: Event for frozen amount adjustment when balance insufficient
    event FrozenAmountAdjusted(address indexed token, uint256 oldAmount, uint256 newAmount, string reason);

    // ==================== Permission Modifiers ====================

    modifier onlyMerchant() {
        if (msg.sender != merchant) revert NotMerchant();
        _;
    }

    modifier onlyAdminOrCS() {
        if (!settings.isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyAuthorizedProduct() {
        if (!authorizedProducts[msg.sender]) revert NotAuthorizedProduct();
        _;
    }

    modifier onlyFreezeAuthorized() {
        if (!authorizedProducts[msg.sender] && !authorizedCases[msg.sender]) revert NotAuthorized();
        _;
    }

    // ==================== Initialization ====================

    /**
     * @notice Initialize deposit contract
     * @dev Can only be called once; called by DepositFactory immediately after cloning.
     *      _tokens convention order: [0]=USDT (guaranteed by DepositFactory)
     */
    function initialize(
        address _merchant,
        address[] calldata _tokens,
        address _settings
    ) external {
        if (initialized) revert AlreadyInit();
        if (_merchant == address(0) || _settings == address(0)) revert ZeroAddress();
        if (_tokens.length == 0) revert ZeroAmount();
        initialized = true;
        _locked = 1;
        merchant = _merchant;
        settings = IPlatformSettings(_settings);
        factory = msg.sender;
        lastActivityTime = block.timestamp;
        status = DepositStatus.Active;
        for (uint256 i = 0; i < _tokens.length;) {
            address t = _tokens[i];
            if (t == address(0)) revert ZeroAddress();
            if (isToken[t]) { unchecked { ++i; } continue; }
            tokens.push(t);
            isToken[t] = true;
            uint8 dec = IERC20(t).decimals();
            uint256 unit = 10 ** uint256(dec);
            minDeposit[t] = 500 * unit;
            maxDeposit[t] = 1000000 * unit;
            unchecked { ++i; }
        }
    }

    // ==================== Merchant Operations ====================

    /// @notice Merchant deposits a specified token (>= 500, cumulative <= 1M)
    function deposit(uint256 amount, address token) external onlyMerchant noContract nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (settings.isBlacklisted(msg.sender)) revert IsBlacklisted();
        if (status != DepositStatus.Active && status != DepositStatus.Deducted && status != DepositStatus.Withdrawn) revert CannotDeposit();
        if (amount < minDeposit[token]) revert MinDeposit500();
        if (balanceOf[token] + amount > maxDeposit[token]) revert ExceedsMaxDeposit();
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        balanceOf[token] += amount;
        lastActivityTime = block.timestamp;
        settings.recordDepositIn(amount, token);
        if (status != DepositStatus.Active) {
            status = DepositStatus.Active;
        }
        emit Deposited(merchant, token, amount);
    }

    /// @notice Merchant withdraws full balance of a specified token; marks Withdrawn when all tokens are zero
    /// @dev Withdraw marks status as Withdrawn when balance reaches zero
    function withdraw(address token) external onlyMerchant noContract nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (status != DepositStatus.Active) revert NotActive();
        uint256 amt = balanceOf[token];
        if (amt == 0) revert NoBalance();
        if (frozenAmountOf[token] > 0) revert HasActiveAuctions();
        address df = settings.getDepositFactory();
        if (df != address(0)) {
            IDepositFactory(df).refreshUnlockCooldown(merchant);
            if (!IDepositFactory(df).canWithdrawDeposit(merchant)) revert CooldownActive();
        }
        balanceOf[token] = 0;
        if (_allBalancesZero()) {
            status = DepositStatus.Withdrawn;
        }
        lastActivityTime = block.timestamp;
        _safeTransferToUser(token, merchant, amt, true);
        emit Withdrawn(merchant, token, amt);
    }

    // ==================== Mechanism Operations ====================

    /// @notice Authorized product contract deduction (only callable by the product contract itself)
    function deduct(uint256 amount, address to, address token) external onlyAuthorizedProduct nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (status != DepositStatus.Frozen && status != DepositStatus.Active) revert InvalidStatus();
        if (amount > balanceOf[token] - frozenAmountOf[token]) revert Insufficient();
        balanceOf[token] -= amount;
        // [M-04 fix]: Emit event when frozen amount is adjusted due to insufficient balance
        if (frozenAmountOf[token] > balanceOf[token]) {
            uint256 oldFrozen = frozenAmountOf[token];
            frozenAmountOf[token] = balanceOf[token];
            emit FrozenAmountAdjusted(token, oldFrozen, balanceOf[token], "deduct-balance-insufficient");
        }
        lastActivityTime = block.timestamp;
        if (_allBalancesZero()) {
            status = DepositStatus.Deducted;
        } else {
            status = DepositStatus.Active;
        }
        _safeTransferToUser(token, to, amount, true);
        emit Deducted(token, amount, to);
    }

    /// @notice Product contract self-authorization (only callable by the product contract itself; validated by Factory or AuctionFactory)
    function authorizeProduct(address product) external {
        if (msg.sender != product) revert NotAuthorized();
        IPlatformSettings _settings = settings;
        address pf = _settings.getProductFactory();
        address af = _settings.getAuctionFactory();
        bool validProduct = (pf != address(0) && IProductFactory(pf).isFactoryProduct(product));
        bool validAuction = (af != address(0) && IAuctionFactory(af).isFactoryAuction(product));
        address cf = _settings.getC2CFactory();
        bool validC2CBuyOrder = (cf != address(0) && IC2CFactory(cf).isFactoryBuyOrder(product));
        bool validC2CTrade = (cf != address(0) && IC2CFactory(cf).isFactoryTrade(product));
        if (!validProduct && !validAuction && !validC2CBuyOrder && !validC2CTrade) revert NotFactoryProduct();
        authorizedProducts[product] = true;
    }

    function revokeProductAuthorization(address product) external {
        if (msg.sender != product) revert OnlyProductCanRevoke();
        authorizedProducts[product] = false;
    }

    function revokeProductByAdmin(address product) external onlyAdminOrCS {
        authorizedProducts[product] = false;
    }

    /// @notice Arbitration case contract self-authorization
    function authorizeCase(address caseContract) external {
        if (msg.sender != caseContract) revert NotAuthorized();
        address arbFactory = settings.getCommunityArbitrationFactory();
        if (arbFactory == address(0)) revert NotAuthorized();
        if (!ICommunityArbitrationFactory(arbFactory).isFactoryCase(caseContract)) revert NotFactoryCase();
        authorizedCases[caseContract] = true;
    }

    // ==================== Unified Freeze (Single Token) ====================

    /// @notice Business contract freezes deposit for a specified token
    function freezeDeposit(uint256 amount, address token) external onlyFreezeAuthorized {
        if (!isToken[token]) revert TokenNotAccepted();
        if (status != DepositStatus.Active) revert NotActive();

        // Race-condition fix: the total after freezing must not exceed the actual balance
        // Prevents concurrent freezes by multiple business contracts from making frozenAmountOf > balanceOf
        if (frozenAmountOf[token] + amount > balanceOf[token]) revert Insufficient();

        frozenAmountOf[token] += amount;
        callerFrozenAmounts[msg.sender][token] += amount;
        lastActivityTime = block.timestamp;
        emit DepositFrozen(msg.sender, token, amount);
    }

    /// @notice Business contract unfreezes partial frozen amount for caller on a specified token
    function unfreezeDepositAmount(uint256 amount, address token) external onlyFreezeAuthorized {
        if (!isToken[token]) revert TokenNotAccepted();
        if (amount == 0) return;
        uint256 amt = callerFrozenAmounts[msg.sender][token];
        if (amount < amt) amt = amount;
        if (amt > frozenAmountOf[token]) amt = frozenAmountOf[token];
        if (amt > 0) {
            frozenAmountOf[token] -= amt;
            callerFrozenAmounts[msg.sender][token] -= amt;
        }
        lastActivityTime = block.timestamp;
        emit DepositUnfrozen(msg.sender, token, amt);
    }

    /// @notice Business contract unfreezes all frozen amount for caller on a specified token
    function unfreezeDeposit(address token) external onlyFreezeAuthorized {
        if (!isToken[token]) revert TokenNotAccepted();
        uint256 amt = callerFrozenAmounts[msg.sender][token];
        if (amt > frozenAmountOf[token]) amt = frozenAmountOf[token];
        if (amt > 0) {
            frozenAmountOf[token] -= amt;
            delete callerFrozenAmounts[msg.sender][token];
        }
        lastActivityTime = block.timestamp;
        emit DepositUnfrozen(msg.sender, token, amt);
    }

    /// @notice Unfreeze all frozen amounts for caller across all tokens (one-time cleanup when arbitration ends)
    function unfreezeAll() external onlyFreezeAuthorized {
        uint256 tLen = tokens.length;
        for (uint256 i = 0; i < tLen;) {
            address t = tokens[i];
            uint256 amt = callerFrozenAmounts[msg.sender][t];
            if (amt == 0) { unchecked { ++i; } continue; }
            if (amt > frozenAmountOf[t]) amt = frozenAmountOf[t];
            frozenAmountOf[t] -= amt;
            delete callerFrozenAmounts[msg.sender][t];
            emit DepositUnfrozen(msg.sender, t, amt);
            unchecked { ++i; }
        }
        lastActivityTime = block.timestamp;
    }

    /// @notice Business contract deducts from frozen amount of a specified token
    function deductFromFrozen(uint256 amount, address to, address token) external onlyFreezeAuthorized nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        if (amount > callerFrozenAmounts[msg.sender][token]) revert Insufficient();
        callerFrozenAmounts[msg.sender][token] -= amount;
        frozenAmountOf[token] -= amount;
        balanceOf[token] -= amount;
        lastActivityTime = block.timestamp;
        if (_allBalancesZero()) {
            status = DepositStatus.Deducted;
        }
        _safeTransferToUser(token, to, amount, true);
        emit DepositDeducted(msg.sender, token, amount, to);
    }

    /// @notice Transfer frozen allocation from caller to another authorized contract
    /// @dev Used when BuyOrder's frozen deposit needs to be seized for arbitration by a TradeTemplate.
    ///      Total frozen amount stays the same; only the accounting of "who froze it" changes.
    function transferFrozenAllocation(uint256 amount, address newCaller, address token) external onlyFreezeAuthorized {
        if (!isToken[token]) revert TokenNotAccepted();
        // [H-03 fix]: Validate newCaller is also authorized to prevent funds locked in unauthorized address
        if (!authorizedProducts[newCaller] && !authorizedCases[newCaller]) revert NotAuthorized();
        if (amount > callerFrozenAmounts[msg.sender][token]) revert Insufficient();
        callerFrozenAmounts[msg.sender][token] -= amount;
        callerFrozenAmounts[newCaller][token] += amount;
        lastActivityTime = block.timestamp;
    }

    // ==================== Query Functions ====================

    /// @notice Get available balance for a specified token (unfrozen portion)
    function getAvailableBalance(address token) external view returns (uint256) {
        return balanceOf[token] - frozenAmountOf[token];
    }

    /// @notice Whether any token has balance and is not withdrawn (used for product/auction listing deposit existence check)
    function hasAnyDeposit() external view returns (bool) {
        if (status == DepositStatus.Withdrawn) return false;
        uint256 tLen = tokens.length;
        for (uint256 i = 0; i < tLen;) {
            if (balanceOf[tokens[i]] > 0) return true;
            unchecked { ++i; }
        }
        return false;
    }

    /// @notice Whether a specified token has sufficient deposit (used by KeywordWeight)
    function isSufficient(address token) external view returns (bool) {
        return balanceOf[token] > 0 && status != DepositStatus.Withdrawn;
    }

    /// @notice Get deposit information
    function getDepositInfo() external view returns (
        address merchantAddr,
        uint256 balanceUsdt,
        DepositStatus status_,
        bool withdrawable,
        uint256 unlockTime,
        uint256 frozenUsdt
    ) {
        merchantAddr = merchant;
        if (tokens.length >= 1) {
            balanceUsdt = balanceOf[tokens[0]];
            frozenUsdt = frozenAmountOf[tokens[0]];
        }
        status_ = status;
        bool ok = true;
        uint256 unlock = 0;
        address df = settings.getDepositFactory();
        if (df != address(0)) {
            (bool conditionsMet, uint256 cooldownStart_, uint256 cooldownEnd_, bool canWithdraw_,,,,) = IDepositFactory(df).getUnlockCooldownInfo(merchant);
            if (!conditionsMet || !canWithdraw_) {
                ok = false;
                unlock = !conditionsMet ? type(uint256).max : (cooldownStart_ == 0 ? 0 : cooldownEnd_);
            }
        }
        bool noBalance = (balanceUsdt == 0);
        if (status_ != DepositStatus.Active || noBalance) ok = false;
        withdrawable = ok;
        unlockTime = unlock;
    }

    /// @notice Refresh activity time (only callable by factory)
    function refreshActivity() external onlyFactory {
        lastActivityTime = block.timestamp;
    }

    // ==================== Zombie Recycling ====================

    /// @notice Force recycle zombie deposit (all tokens transferred to platform wallet)
    function forceRecycle() external onlyFactory nonReentrant {
        if (status != DepositStatus.Active && status != DepositStatus.Deducted) revert InvalidStatus();
        if (block.timestamp <= lastActivityTime + ZOMBIE_PERIOD) revert NotInactiveEnough();
        bool hasBalance = false;
        uint256 tLen = tokens.length;
        for (uint256 i = 0; i < tLen;) {
            if (balanceOf[tokens[i]] > 0) { hasBalance = true; break; }
            unchecked { ++i; }
        }
        if (!hasBalance) revert NoBalance();
        // Audit note: zombie recycling is a platform-level cleanup after proven long inactivity.
        // It intentionally overrides ordinary business locks, but clears aggregate frozen balances so post-recycle views stay consistent.
        // Per-caller frozen mappings are not enumerable; after status becomes Withdrawn, authorized business contracts cannot obtain funds from this deposit.
        // Platform fee prefers the split routing splitter (auto 30/30/40 slicing); falls back to platformWallet when unconfigured
        // Safety: the splitter has no claimPending, so on a "transfer to splitter failed" case _safeTransferToUser must NEVER
        //   record the funds into pendingWithdrawals[splitter] — that would lock them permanently.
        //   On failure it must degrade to the EOA platformWallet (owner can claim or redistribute manually).
        address splitter = settings.getFeeSplitter();
        address platformWallet = settings.getPlatformWallet();
        for (uint256 i = 0; i < tLen;) {
            address t = tokens[i];
            uint256 amt = balanceOf[t];
            if (frozenAmountOf[t] > 0) frozenAmountOf[t] = 0;
            if (amt > 0) {
                balanceOf[t] = 0;

                bool sentToSplitter = false;
                if (splitter != address(0)) {
                    (bool s1, bytes memory d1) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, splitter, amt));
                    bool ok1 = s1 && (d1.length == 0 || abi.decode(d1, (bool)));
                    if (ok1) {
                        settings.recordDepositOut(amt, t);
                        try IPlatformFeeSplitter(splitter).distribute(t, amt) {} catch {}
                        sentToSplitter = true;
                    }
                }
                if (!sentToSplitter) {
                    if (splitter != address(0)) emit SplitterFallback(t, amt, platformWallet);
                    _safeTransferToUser(t, platformWallet, amt, true);
                }
                emit Recycled(merchant, t, amt);
            }
            unchecked { ++i; }
        }
        status = DepositStatus.Withdrawn;
    }

    // ==================== Internal / Pending ====================

    function _allBalancesZero() internal view returns (bool) {
        uint256 tLen = tokens.length;
        for (uint256 i = 0; i < tLen;) {
            if (balanceOf[tokens[i]] > 0) return false;
            unchecked { ++i; }
        }
        return true;
    }

    /// @dev USDT compatible transfer: considers success even if return value is non-standard; on failure, credits amount to pendingWithdrawals
    function _safeTransferToUser(address token, address to, uint256 amount, bool recordOut) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        bool ok = success && (data.length == 0 || abi.decode(data, (bool)));
        if (ok) {
            if (recordOut) settings.recordDepositOut(amount, token);
        } else {
            if (recordOut) pendingRecordOut[to][token] += amount;
            pendingWithdrawals[to][token] += amount;
            emit TransferPending(to, token, amount);
        }
    }

    /// @notice Claim pending token from failed transfers
    function claimPending(address token) external nonReentrant {
        if (!isToken[token]) revert TokenNotAccepted();
        uint256 amount = pendingWithdrawals[msg.sender][token];
        if (amount == 0) revert NoBalance();
        pendingWithdrawals[msg.sender][token] = 0;
        uint256 recordAmt = pendingRecordOut[msg.sender][token];
        if (recordAmt > 0) {
            pendingRecordOut[msg.sender][token] = 0;
            settings.recordDepositOut(recordAmt, token);
        }
        if (!IERC20(token).transfer(msg.sender, amount)) revert TransferFailed();
    }

    /// @notice Get number of registered tokens (for frontend iteration)
    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}
