// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "./interfaces/Interfaces.sol";

contract PlatformSettings {

    // ==================== State Variables ====================
    // Audit note [L-01]: owner will be transferred to a multisig wallet, which itself provides two-step confirmation,
    // so there is no need to implement a pendingOwner pattern. After production deployment, core addresses are immutable (AlreadySet check).

    address public owner;           // Contract owner (highest privilege)
    address public platformWallet;  // Platform receiving wallet address (legacy single-recipient EOA, retained for backward compat & emergencies)
    address public feeSplitter;     // PlatformFeeSplitter contract — preferred destination for all platform fees (auto 30/30/40 split)

    // ============ Splitter payees lock ============
    // Locks the splitter's 3 payee addresses, preventing a stolen owner key from replacing it with a "fake splitter" routing funds to malicious addresses.
    // Call lockSplitterPayees() once at deployment to lock; afterwards setFeeSplitter must be passed a contract whose payees match exactly.
    // Once locked, the splitter shares (immutable in PlatformFeeSplitter) are also guaranteed unchanged by code.
    address[8] public lockedPayees;
    bool public splitterPayeesLocked;

    /// Contract deployment timestamp (for 24-hour time lock)
    uint256 public immutable deployTimestamp;

    mapping(address => bool) public customerServices;    // Customer service list
    mapping(address => bool) public authorizedContracts; // Authorized contract list (allowed to call sensitive methods)

    /// Fee rates (basis points, 10000 = 100%)
    /// 0=physical 3%=300, 1=virtual 3%=300, 2=service 5%=500, 3=C2C 0.2%=20, 4=auction 5%=500, 5=want-to-buy 3%=300
    mapping(uint8 => uint256) public feeRates;

    /// Invite commission rates (basis points, percentage of fee)
    uint256 public level1Rate = 2000;    // Level-1 inviter commission 20%
    uint256 public level2Rate = 1000;    // Level-2 inviter commission 10%
    uint256 public platformRate = 7000;  // Platform retention 70%

    uint256 public riskThreshold = 5000;       // Risk merchant threshold (50%, in basis points)

    /// Merchant risk control data
    mapping(address => uint256) public merchantArbitrations;  // Number of arbitrations against merchant
    mapping(address => uint256) public merchantTotalOrders;   // Merchant total completed orders

    /// Cooldown manager contract address (C2C cooldown locking mechanism)
    address public cooldownManager;

    /// Product factory contract address (for product delist cooldown checks)
    address public productFactory;

    /// Deposit factory contract address (for authorizing deposit contracts to call sensitive methods)
    address public depositFactory;

    /// C2C factory contract address (for authorizing trade contracts to call sensitive methods)
    address public c2cFactory;

    /// Auction factory contract address (for authorizing auction contracts to call sensitive methods)
    address public auctionFactory;

    /// Community arbitration factory contract address
    address public communityArbitrationFactory;

    /// Shuifang factory contract address
    address public shuifangFactory;

    /// Blacklist (prohibits creating products, deposits, paying deposits, creating C2C orders)
    mapping(address => bool) public blacklisted;

    /// Merchant last active time (updated on recordOrder)
    mapping(address => uint256) public merchantLastActive;

    // ==================== Deposit and Product Publishing Limits ====================

    /// Deposit requirement toggle (admin can enable)
    bool public requireDepositForPublish = false;

    /// Minimum deposit amount (USDT, 18-decimal precision)
    uint256 public minimumDepositAmount = 0;

    /// Product publishing cap for merchants without a deposit
    uint256 public maxProductsWithoutDeposit = 5; // production

    /// Product publishing cap for merchants with a deposit
    uint256 public maxProductsWithDeposit = 20; // production

    // ==================== Unified Lightweight Dictionary (Isolated by Language Market) ====================

    uint8 private constant DICT_FIAT = 0;
    uint8 private constant DICT_PAYMENT = 1;
    uint8 private constant DICT_COUNTRY = 2;
    uint8 private constant DICT_PROVINCE = 3;
    uint8 private constant DICT_CITY = 4;

    mapping(bytes32 => bool) public dictionaryApproved;
    mapping(bytes32 => bool) internal dictionaryListed;
    mapping(bytes32 => string[]) internal dictionaryValues;

    // ==================== Payment Channel (USDT) ====================

    /// Registered payment channel token list (USDT)
    address[] public acceptedTokensList;

    /// token => whether registered
    mapping(address => bool) public acceptedTokenSet;

    /// token => platform cumulative fee total (replaces old totalFeesCollected single-value field)
    mapping(address => uint256) public totalFeesPerToken;

    /// token => platform current deposit total held (replaces old totalDepositsHeld single-value field)
    mapping(address => uint256) public totalDepositsHeldPerToken;

    // === 7 groups of merchant income accounting (seller => token => uint256), naturally isolated by dual tokens ===

    /// Total completed order amount
    mapping(address => mapping(address => uint256)) public merchantCompletedAmount;
    /// Completed order count
    mapping(address => mapping(address => uint256)) public merchantCompletedCount;
    /// Total refunded amount
    mapping(address => mapping(address => uint256)) public merchantRefundedAmount;
    /// Refund count
    mapping(address => mapping(address => uint256)) public merchantRefundedCount;
    /// Total arbitration payout amount
    mapping(address => mapping(address => uint256)) public merchantArbPayoutAmount;
    /// Arbitration payout count
    mapping(address => mapping(address => uint256)) public merchantArbPayoutCount;
    /// Cumulative net income = seller earnings from completed orders - refunds - arbitration payouts
    mapping(address => mapping(address => uint256)) public merchantNetIncome;

    event TokenAccepted(address indexed token);
    event TokenRemoved(address indexed token);
    event SettlementRecorded(address indexed seller, address indexed token, uint256 netIncome, uint256 grossAmount);
    event RefundRecorded(address indexed seller, address indexed token, uint256 amount);
    event ArbitrationPayoutRecorded(address indexed seller, address indexed token, uint256 amount);
    event RequireDepositForPublishUpdated(bool required);
    event MinimumDepositAmountUpdated(uint256 amount);
    event MaxProductsWithoutDepositUpdated(uint256 max);
    event MaxProductsWithDepositUpdated(uint256 max);

    // ==================== Modifiers ====================

    /// Only contract owner can call
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// Only authorized contracts can call (factory contracts, product contracts, etc.)
    modifier onlyAuthorized() {
        if (!authorizedContracts[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier onlyAdminOrCS() {
        if (msg.sender != owner && !customerServices[msg.sender]) revert NotAdminOrCS();
        _;
    }

    /// Only callable within 24 hours after deployment (locks contract address modification operations)
    modifier onlyBeforeLock() {
        if (block.timestamp >= deployTimestamp + 24 hours) revert LockedAfter24h();
        _;
    }

    // ==================== Constructor ====================

    constructor(address _platformWallet) {
        owner = msg.sender;
        // [M-02 fix]: If platformWallet not specified, default to owner for automatic tracking
        platformWallet = _platformWallet != address(0) ? _platformWallet : msg.sender;
        deployTimestamp = block.timestamp;

        // Initialize fee rates
        feeRates[0] = 300;  // Physical products 3%
        feeRates[1] = 300;  // Virtual products 3%
        feeRates[2] = 500;  // Service products 5%
        feeRates[3] = 20;   // C2C trades 0.2%
        feeRates[4] = 500;  // Auctions 5%
        feeRates[5] = 300;  // Want-to-buy products 3%

        // Deposit amount is now free-form input (500~1,000,000 USDT), validated internally by MerchantDepositTemplate
    }

    // ==================== Role Management ====================

    /// @notice Add customer service agent (owner only)
    /// @param addr Customer service address
    function addCustomerService(address addr) external onlyOwner {
        customerServices[addr] = true;
    }
    /// @notice Remove customer service agent (owner only)
    /// @param addr Customer service address
    function removeCustomerService(address addr) external onlyOwner {
        customerServices[addr] = false;
    }
    /// @notice Authorize contract address (allows calling sensitive methods like recordArbitration/recordOrder)
    /// @param addr Contract address to authorize
    function authorizeContract(address addr) external onlyOwner onlyBeforeLock {
        authorizedContracts[addr] = true;
    }
    /// @notice Revoke contract authorization
    /// @param addr Contract address to revoke
    function revokeContract(address addr) external onlyOwner onlyBeforeLock {
        authorizedContracts[addr] = false;
    }

    // ==================== Query Methods ====================

    /// @notice Check if address is owner
    /// @param addr Address to query
    /// @return Whether the address is the owner
    function isAdmin(address addr) external view returns (bool) {
        return addr == owner;
    }
    /// @notice Check if address is a customer service agent
    /// @param addr Address to query
    /// @return Whether the address is a customer service agent
    function isCustomerService(address addr) external view returns (bool) {
        return customerServices[addr];
    }
    /// @notice Check if address is owner or customer service (used for arbitration/keyword review permissions)
    /// @param addr Address to query
    /// @return Whether the address is owner or customer service
    function isAdminOrCS(address addr) external view returns (bool) {
        return addr == owner || customerServices[addr];
    }
    /// @notice Check if address is an authorized contract
    /// @param addr Address to query
    /// @return Whether the address is authorized
    function isAuthorizedContract(address addr) external view returns (bool) {
        return authorizedContracts[addr];
    }
    /// @notice Get fee rate
    /// @param productType Product type (0=physical, 1=virtual, 2=service, 3=C2C)
    /// @return Rate in basis points
    function getFeeRate(uint8 productType) external view returns (uint256) {
        return feeRates[productType];
    }
    /// @notice Get risk merchant threshold
    /// @return Threshold in basis points
    function getRiskThreshold() external view returns (uint256) {
        return riskThreshold;
    }
    /// @notice Get level-1 inviter commission rate
    /// @return Rate in basis points
    function getLevel1Rate() external view returns (uint256) {
        return level1Rate;
    }
    /// @notice Get level-2 inviter commission rate
    /// @return Rate in basis points
    function getLevel2Rate() external view returns (uint256) {
        return level2Rate;
    }
    /// @notice Get platform retention rate
    /// @return Rate in basis points
    function getPlatformRate() external view returns (uint256) {
        return platformRate;
    }
    /// @notice Get platform receiving wallet address
    /// @return Platform wallet address
    function getPlatformWallet() external view returns (address) {
        return platformWallet;
    }

    /// @notice Get platform fee splitter contract address
    /// @return Splitter contract address (zero if not set, callers must fall back to platformWallet)
    function getFeeSplitter() external view returns (address) {
        return feeSplitter;
    }

    // ==================== Configuration ====================

    /// @notice Set fee rate (admin only, productType: 0=physical, 1=virtual, 2=service, 3=C2C)
    /// @param productType Product type (0=physical, 1=virtual, 2=service, 3=C2C)
    /// @param rate Fee rate (basis points, max 2000 i.e. 20%)
    // Audit note [L-02]: feeRate cap is 2000 (20%), controlled by onlyOwner.
    // If owner key is compromised, high fee rates can be set, but owner will be transferred to a multisig wallet (see [L-01]),
    // which provides two-step confirmation protection. For stricter limits, lower the RateExceeds20Pct threshold.
    function setFeeRate(uint8 productType, uint256 rate) external onlyOwner {
        if (rate > 2000) revert RateExceeds20Pct();
        feeRates[productType] = rate;
    }
    /// @notice Set invite commission rates (sum of all three must equal 10000)
    /// @param _l1 Level-1 inviter commission rate
    /// @param _l2 Level-2 inviter commission rate
    /// @param _platform Platform retention rate
    function setInviteRates(uint256 _l1, uint256 _l2, uint256 _platform) external onlyOwner {
        if (_l1 + _l2 + _platform != 10000) revert MustSumTo10000();
        level1Rate = _l1;
        level2Rate = _l2;
        platformRate = _platform;
    }
    /// @notice Set risk merchant threshold
    /// @param _threshold Threshold (basis points, e.g. 5000=50%)
    function setRiskThreshold(uint256 _threshold) external onlyOwner {
        if (_threshold > 10000) revert TooHigh();
        riskThreshold = _threshold;
    }
    /// @notice Set platform receiving wallet address (owner only)
    /// @param _wallet New platform wallet address
    function setPlatformWallet(address _wallet) external onlyOwner {
        if (_wallet == address(0)) revert ZeroAddress();
        platformWallet = _wallet;
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = _newOwner;
        // [M-02 fix]: If platformWallet was set to old owner, auto-update to new owner
        // This ensures fallback wallet follows ownership transfers automatically
        if (platformWallet == oldOwner) {
            platformWallet = _newOwner;
        }
    }

    /// @notice Set platform fee splitter contract address (owner only)
    /// @dev When set, recipient contracts route platform fees through the splitter for atomic 3-way split.
    ///      Set to address(0) to fall back to single-recipient platformWallet behavior.
    ///      If splitterPayeesLocked=true, the new splitter's 8 payees must match the locked set exactly
    ///      (order-independent) -- even if the owner key is compromised, an attacker cannot redirect funds to new addresses.
    /// @param _splitter PlatformFeeSplitter contract address (or zero to disable)
    function setFeeSplitter(address _splitter) external onlyOwner {
        if (_splitter != address(0) && splitterPayeesLocked) {
            address[8] memory p;
            p[0] = IPlatformFeeSplitter(_splitter).payee0();
            p[1] = IPlatformFeeSplitter(_splitter).payee1();
            p[2] = IPlatformFeeSplitter(_splitter).payee2();
            p[3] = IPlatformFeeSplitter(_splitter).payee3();
            p[4] = IPlatformFeeSplitter(_splitter).payee4();
            p[5] = IPlatformFeeSplitter(_splitter).payee5();
            p[6] = IPlatformFeeSplitter(_splitter).payee6();
            p[7] = IPlatformFeeSplitter(_splitter).payee7();
            if (!_payeesMatchLocked(p)) revert PayeesMismatch();
        }
        feeSplitter = _splitter;
    }

    /// @notice One-time lock of the 8 splitter payees (owner only, irreversible).
    /// @dev Call once to lock the 8 payee addresses. Once locked, setFeeSplitter must be passed a splitter with the same payees,
    ///      preventing the fund path from being hijacked if the owner key is compromised. Recommended to call immediately after first deploying the splitter.
    function lockSplitterPayees(address[8] calldata _payees) external onlyOwner {
        if (splitterPayeesLocked) revert AlreadySet();
        for (uint256 i = 0; i < 8; i++) {
            if (_payees[i] == address(0)) revert ZeroAddress();
            lockedPayees[i] = _payees[i];
        }
        splitterPayeesLocked = true;
    }

    /// @dev Check whether the 8 passed payees (order-independent) are exactly equal to the locked set
    function _payeesMatchLocked(address[8] memory p) internal view returns (bool) {
        // Set equality: the 8 addresses must be mutually distinct, and each must hit the locked set
        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = i + 1; j < 8; j++) {
                if (p[i] == p[j]) return false;
            }
            bool hit;
            for (uint256 k = 0; k < 8; k++) {
                if (p[i] == lockedPayees[k]) { hit = true; break; }
            }
            if (!hit) return false;
        }
        return true;
    }
    /// @notice Set cooldown manager contract address (owner only, locked after 24h)
    /// @param _cm CooldownManager contract address
    function setCooldownManager(address _cm) external onlyOwner onlyBeforeLock {
        if (_cm == address(0)) revert ZeroAddress();
        cooldownManager = _cm;
    }
    /// @notice Get cooldown manager contract address
    /// @return CooldownManager contract address
    function getCooldownManager() external view returns (address) {
        return cooldownManager;
    }
    /// @notice Set product factory contract address (owner only, locked after 24h)
    /// @param _pf ProductFactory contract address
    function setProductFactory(address _pf) external onlyOwner onlyBeforeLock {
        if (_pf == address(0)) revert ZeroAddress();
        productFactory = _pf;
    }
    /// @notice Get product factory contract address
    /// @return ProductFactory contract address
    function getProductFactory() external view returns (address) {
        return productFactory;
    }

    // ==================== Deposit and Product Publishing Limit Management ====================

    /// @notice Set the deposit requirement toggle
    /// @param _require Whether a deposit is required
    function setRequireDepositForPublish(bool _require) external onlyOwner {
        requireDepositForPublish = _require;
        emit RequireDepositForPublishUpdated(_require);
    }

    /// @notice Set the minimum deposit amount
    /// @param _amount Minimum deposit amount (USDT, 18-decimal precision)
    function setMinimumDepositAmount(uint256 _amount) external onlyOwner {
        minimumDepositAmount = _amount;
        emit MinimumDepositAmountUpdated(_amount);
    }

    /// @notice Set the product publishing cap for merchants without a deposit
    /// @param _max Maximum number of products
    function setMaxProductsWithoutDeposit(uint256 _max) external onlyOwner {
        maxProductsWithoutDeposit = _max;
        emit MaxProductsWithoutDepositUpdated(_max);
    }

    /// @notice Set the product publishing cap for merchants with a deposit
    /// @param _max Maximum number of products
    function setMaxProductsWithDeposit(uint256 _max) external onlyOwner {
        maxProductsWithDeposit = _max;
        emit MaxProductsWithDepositUpdated(_max);
    }

    /// @notice Check whether a merchant meets the deposit requirement
    /// @param seller Merchant address
    /// @return meetsRequirement Whether the deposit requirement is met
    /// @return currentDeposit Current deposit balance
    /// @return maxProducts Maximum number of products allowed to publish
    function checkDepositRequirement(address seller) external view returns (
        bool meetsRequirement,
        uint256 currentDeposit,
        uint256 maxProducts
    ) {
        // Get the merchant's deposit balance
        currentDeposit = 0;
        if (depositFactory != address(0)) {
            try IDepositFactory(depositFactory).getDeposit(seller) returns (address depositAddr) {
                if (depositAddr != address(0)) {
                    // Get the first registered token address (usually USDT)
                    if (acceptedTokensList.length > 0) {
                        address tokenAddr = acceptedTokensList[0];
                        try IMerchantDeposit(depositAddr).getAvailableBalance(tokenAddr) returns (uint256 balance) {
                            currentDeposit = balance;
                        } catch {}
                    }
                }
            } catch {}
        }

        // Determine whether there is sufficient deposit
        bool hasDeposit = currentDeposit >= minimumDepositAmount;

        // Set the maximum number of products
        maxProducts = hasDeposit ? maxProductsWithDeposit : maxProductsWithoutDeposit;

        // If the deposit requirement toggle is on, a deposit is mandatory
        if (requireDepositForPublish) {
            meetsRequirement = hasDeposit;
        } else {
            // Toggle off: always meets the requirement (but still affects the product count cap)
            meetsRequirement = true;
        }
    }

    // ==================== Merchant Risk Control ====================

    // Audit note [3.3.4]: recordArbitration records the number of arbitrations against a merchant (win or lose),
    // recordOrder records completed order count. Naming is clear in business context; changing the interface would affect multiple contracts.
    function recordArbitration(address seller) external onlyAuthorized {
        merchantArbitrations[seller]++;
    }
    /// @notice Record merchant completed order count +1 (only authorized contracts)
    /// @param seller Merchant address
    function recordOrder(address seller) external onlyAuthorized {
        merchantTotalOrders[seller]++;
        merchantLastActive[seller] = block.timestamp;
    }
    /// @notice Check if merchant is a risk merchant (arbitration count / total orders > threshold)
    /// @param seller Merchant address
    /// @return Whether the merchant is a risk merchant
    function isRiskMerchant(address seller) external view returns (bool) {
        uint256 total = merchantTotalOrders[seller];
        if (total == 0) return false;
        return (merchantArbitrations[seller] * 10000 / total) > riskThreshold;
    }

    // ==================== Blacklist Management ====================

    event Blacklisted(address indexed addr);
    event Unblacklisted(address indexed addr);

    /// @notice Add to blacklist (admin only)
    /// @param addr Address to blacklist
    function addBlacklist(address addr) external onlyOwner {
        blacklisted[addr] = true;
        emit Blacklisted(addr);
    }
    /// @notice Remove from blacklist (admin only)
    /// @param addr Address to remove from blacklist
    function removeBlacklist(address addr) external onlyOwner {
        blacklisted[addr] = false;
        emit Unblacklisted(addr);
    }
    /// @notice Check if address is blacklisted
    /// @param addr Address to query
    /// @return Whether the address is blacklisted
    function isBlacklisted(address addr) external view returns (bool) {
        return blacklisted[addr];
    }

    // ==================== Platform Statistics (Dual Payment Channel Token Accounting) ====================

    event FeeRecorded(address indexed token, uint256 amount);
    event DepositOutUnderflow(address indexed token, uint256 amount, uint256 held);

    /// @notice Record fee (authorized contracts only, accounted by token)
    /// @param amount Fee amount (USDT smallest precision)
    /// @param token Payment token used in this transaction
    function recordFee(uint256 amount, address token) external onlyAuthorized {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        totalFeesPerToken[token] += amount;
        emit FeeRecorded(token, amount);
    }

    /// @notice Record deposit in (accumulate platform total deposit by token)
    function recordDepositIn(uint256 amount, address token) external onlyAuthorized {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        totalDepositsHeldPerToken[token] += amount;
    }

    /// @notice Record deposit out (deduct from platform total deposit by token; underflow resets to zero with event, no revert)
    /// @dev Audit note [L-05]: totalDepositsHeld is a statistics-only variable and does not hold actual assets.
    ///      On underflow, a DepositOutUnderflow event is emitted for off-chain monitoring alerts.
    function recordDepositOut(uint256 amount, address token) external onlyAuthorized {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        uint256 held = totalDepositsHeldPerToken[token];
        if (amount > held) {
            emit DepositOutUnderflow(token, amount, held);
            totalDepositsHeldPerToken[token] = 0;
        } else {
            totalDepositsHeldPerToken[token] = held - amount;
        }
    }

    /// @notice Get cumulative platform fee total for specified token
    function getTotalFees(address token) external view returns (uint256) {
        return totalFeesPerToken[token];
    }

    /// @notice Get current platform deposit total held for specified token
    function getTotalDepositsHeld(address token) external view returns (uint256) {
        return totalDepositsHeldPerToken[token];
    }

    /// @notice Get merchant last active time
    function getMerchantLastActive(address merchant) external view returns (uint256) {
        return merchantLastActive[merchant];
    }

    // ==================== Payment Channel: Token Registration ====================

    /// @notice Register payment channel token (USDT), owner only
    /// @dev Can register new tokens outside the 24h lock window (unlike onlyBeforeLock fields, token registration needs long-term extensibility)
    function addAcceptedToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (acceptedTokenSet[token]) revert AlreadyRegistered();
        acceptedTokenSet[token] = true;
        acceptedTokensList.push(token);
        emit TokenAccepted(token);
    }

    /// @notice Remove payment channel token (owner only, use with caution -- existing deposits/orders in this token are unaffected)
    function removeAcceptedToken(address token) external onlyOwner {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        acceptedTokenSet[token] = false;
        // Remove from list (order doesn't matter, find with O(n) then swap with last element)
        uint256 len = acceptedTokensList.length;
        for (uint256 i = 0; i < len;) {
            if (acceptedTokensList[i] == token) {
                acceptedTokensList[i] = acceptedTokensList[len - 1];
                acceptedTokensList.pop();
                break;
            }
            unchecked { ++i; }
        }
        emit TokenRemoved(token);
    }

    /// @notice Check if token is a registered payment channel
    function isAcceptedToken(address token) external view returns (bool) {
        return acceptedTokenSet[token];
    }

    /// @notice Get all registered payment channel token list
    function getAcceptedTokens() external view returns (address[] memory) {
        return acceptedTokensList;
    }

    // ==================== Dual Payment Channel: Merchant Income Accounting (7 Groups) ====================

    /// @notice Record order settlement (seller completes an order, accumulated by token)
    /// @dev Called by product/auction/C2C templates during _settle
    /// @param seller Seller address
    /// @param token Order payment token
    /// @param netIncome Seller net income (order amount - platform fee)
    /// @param grossAmount Order gross amount
    function recordSettlement(address seller, address token, uint256 netIncome, uint256 grossAmount) external onlyAuthorized {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        merchantCompletedAmount[seller][token] += grossAmount;
        merchantCompletedCount[seller][token] += 1;
        merchantNetIncome[seller][token] += netIncome;
        emit SettlementRecorded(seller, token, netIncome, grossAmount);
    }

    /// @notice Record refund (seller refunds buyer)
    function recordRefund(address seller, address token, uint256 amount) external onlyAuthorized {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        merchantRefundedAmount[seller][token] += amount;
        merchantRefundedCount[seller][token] += 1;
        // Net income deduction (underflow protection: refund won't exceed recorded net income, but if payout path didn't record settlement first, underflow resets to zero)
        uint256 net = merchantNetIncome[seller][token];
        merchantNetIncome[seller][token] = amount > net ? 0 : net - amount;
        emit RefundRecorded(seller, token, amount);
    }

    /// @notice Record arbitration payout (arbitration rules in favor of buyer)
    function recordArbitrationPayout(address seller, address token, uint256 amount) external onlyAuthorized {
        if (!acceptedTokenSet[token]) revert TokenNotAccepted();
        merchantArbPayoutAmount[seller][token] += amount;
        merchantArbPayoutCount[seller][token] += 1;
        uint256 net = merchantNetIncome[seller][token];
        merchantNetIncome[seller][token] = amount > net ? 0 : net - amount;
        emit ArbitrationPayoutRecorded(seller, token, amount);
    }

    /// @notice Aggregate query of merchant's 7-group income statistics for a specified token
    function getMerchantIncomeStats(address seller, address token) external view returns (
        uint256 completedAmount,
        uint256 completedCount,
        uint256 refundedAmount,
        uint256 refundedCount,
        uint256 arbPayoutAmount,
        uint256 arbPayoutCount,
        uint256 netIncome
    ) {
        completedAmount = merchantCompletedAmount[seller][token];
        completedCount = merchantCompletedCount[seller][token];
        refundedAmount = merchantRefundedAmount[seller][token];
        refundedCount = merchantRefundedCount[seller][token];
        arbPayoutAmount = merchantArbPayoutAmount[seller][token];
        arbPayoutCount = merchantArbPayoutCount[seller][token];
        netIncome = merchantNetIncome[seller][token];
    }

    // ==================== Factory Address Management ====================

    /// @notice Set deposit factory contract address (owner only, locked after 24h)
    /// @param _df DepositFactory contract address
    function setDepositFactory(address _df) external onlyOwner onlyBeforeLock {
        if (_df == address(0)) revert ZeroAddress();
        depositFactory = _df;
    }
    /// @notice Get deposit factory contract address
    /// @return DepositFactory contract address
    function getDepositFactory() external view returns (address) {
        return depositFactory;
    }

    /// @notice Set C2C factory contract address (owner only, locked after 24h)
    /// @param _c2c C2CFactory contract address
    function setC2CFactory(address _c2c) external onlyOwner onlyBeforeLock {
        if (_c2c == address(0)) revert ZeroAddress();
        c2cFactory = _c2c;
    }
    /// @notice Get C2C factory contract address
    /// @return C2CFactory contract address
    function getC2CFactory() external view returns (address) {
        return c2cFactory;
    }

    /// @notice Set auction factory contract address (owner only, locked after 24h)
    /// @param _af AuctionFactory contract address
    function setAuctionFactory(address _af) external onlyOwner onlyBeforeLock {
        if (_af == address(0)) revert ZeroAddress();
        auctionFactory = _af;
    }
    /// @notice Get auction factory contract address
    /// @return AuctionFactory contract address
    function getAuctionFactory() external view returns (address) {
        return auctionFactory;
    }

    /// @notice Set community arbitration factory contract address (owner only, locked after 24h)
    /// @param _caf CommunityArbitrationFactory contract address
    function setCommunityArbitrationFactory(address _caf) external onlyOwner onlyBeforeLock {
        if (_caf == address(0)) revert ZeroAddress();
        communityArbitrationFactory = _caf;
    }
    /// @notice Get community arbitration factory contract address
    /// @return CommunityArbitrationFactory contract address
    function getCommunityArbitrationFactory() external view returns (address) {
        return communityArbitrationFactory;
    }

    /// @notice Set shuifang factory contract address (owner only, locked after 24h)
    /// @param _sf ShuifangFactory contract address
    function setShuifangFactory(address _sf) external onlyOwner onlyBeforeLock {
        if (_sf == address(0)) revert ZeroAddress();
        shuifangFactory = _sf;
    }
    /// @notice Get shuifang factory contract address
    /// @return ShuifangFactory contract address
    function getShuifangFactory() external view returns (address) {
        return shuifangFactory;
    }

    /// @notice Factory authorizes contract (only five factories can call, grants authorization to newly created clone contracts)
    /// @param addr Contract address to authorize
    // Audit note [H-01]: This function allows five factory contracts to authorize new clone contracts indefinitely, which is normal business requirement.
    // Security guarantee: All factory setters are protected by onlyOwner + onlyBeforeLock (24h after deployment),
    // factory addresses are immutable once locked, and factories themselves are immutable contracts (no proxy/upgrade).
    function authorizeContractByFactory(address addr) external {
        if (
            msg.sender != depositFactory &&
            msg.sender != productFactory &&
            msg.sender != c2cFactory &&
            msg.sender != auctionFactory &&
            msg.sender != communityArbitrationFactory &&
            msg.sender != shuifangFactory
        ) revert NotAuthorized();
        authorizedContracts[addr] = true;
    }

    // ==================== Unified Lightweight Dictionary (Isolated by Language Market) ====================

    event DictionaryItemAdded(uint8 indexed kind, string language, string parent1, string parent2, string value);
    event DictionaryItemRemoved(uint8 indexed kind, string language, string parent1, string parent2, string value);

    function _dictKey(uint8 kind, string memory language, string memory parent1, string memory parent2, string memory value) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(kind, ":", language, ":", parent1, ":", parent2, ":", value));
    }

    function _dictListKey(uint8 kind, string memory language, string memory parent1, string memory parent2) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(kind, ":", language, ":", parent1, ":", parent2));
    }

    function _validateDict(string memory language, string memory value) internal pure {
        if (bytes(language).length == 0 || bytes(value).length == 0) revert ZeroAddress();
        if (bytes(language).length > 16) revert InvalidLanguage();
    }

    function _addDictionaryItem(uint8 kind, string memory language, string memory parent1, string memory parent2, string memory value) internal {
        _validateDict(language, value);
        bytes32 key = _dictKey(kind, language, parent1, parent2, value);
        if (dictionaryApproved[key]) revert AlreadyRegistered();
        dictionaryApproved[key] = true;
        bytes32 listKey = _dictListKey(kind, language, parent1, parent2);
        if (!dictionaryListed[key]) {
            dictionaryListed[key] = true;
            dictionaryValues[listKey].push(value);
        }
        emit DictionaryItemAdded(kind, language, parent1, parent2, value);
    }

    function _removeDictionaryItem(uint8 kind, string memory language, string memory parent1, string memory parent2, string memory value) internal {
        bytes32 key = _dictKey(kind, language, parent1, parent2, value);
        if (!dictionaryApproved[key]) revert ZeroAddress();
        dictionaryApproved[key] = false;
        emit DictionaryItemRemoved(kind, language, parent1, parent2, value);
    }

    function _getDictionaryItems(uint8 kind, string memory language, string memory parent1, string memory parent2) internal view returns (string[] memory) {
        string[] storage src = dictionaryValues[_dictListKey(kind, language, parent1, parent2)];
        uint256 count;
        uint256 srcLen = src.length;
        for (uint256 i = 0; i < srcLen;) { if (dictionaryApproved[_dictKey(kind, language, parent1, parent2, src[i])]) count++; unchecked { ++i; } }
        string[] memory out = new string[](count);
        uint256 j;
        for (uint256 i = 0; i < srcLen;) { if (dictionaryApproved[_dictKey(kind, language, parent1, parent2, src[i])]) out[j++] = src[i]; unchecked { ++i; } }
        return out;
    }

    /// @notice Paginated version: only iterates the required range
    function _getDictionaryItemsPaginated(uint8 kind, string memory language, string memory parent1, string memory parent2, uint256 offset, uint256 limit)
        internal view returns (string[] memory results, uint256 total) {
        string[] storage src = dictionaryValues[_dictListKey(kind, language, parent1, parent2)];
        uint256 srcLen = src.length;

        // Count the total
        for (uint256 i = 0; i < srcLen;) {
            if (dictionaryApproved[_dictKey(kind, language, parent1, parent2, src[i])]) total++;
            unchecked { ++i; }
        }

        if (offset >= total) return (new string[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 resultLen = end - offset;
        results = new string[](resultLen);

        uint256 found;
        uint256 added;
        for (uint256 i = 0; i < srcLen && added < resultLen;) {
            if (dictionaryApproved[_dictKey(kind, language, parent1, parent2, src[i])]) {
                if (found >= offset) {
                    results[added++] = src[i];
                }
                found++;
            }
            unchecked { ++i; }
        }
    }

    function isFiatTypeApproved(string memory language, string memory fiatType) external view returns (bool) { return dictionaryApproved[_dictKey(DICT_FIAT, language, "", "", fiatType)]; }
    function isPaymentMethodApproved(string memory language, string memory method) external view returns (bool) { return dictionaryApproved[_dictKey(DICT_PAYMENT, language, "", "", method)]; }
    function getAllFiatTypes(string memory language) external view returns (string[] memory) { return _getDictionaryItems(DICT_FIAT, language, "", ""); }
    function getAllPaymentMethods(string memory language) external view returns (string[] memory) { return _getDictionaryItems(DICT_PAYMENT, language, "", ""); }

    /// @notice Paginated version: avoids the 400K gas cost of 200+ entries
    function getAllFiatTypesPaginated(string memory language, uint256 offset, uint256 limit)
        external view returns (string[] memory results, uint256 total) {
        return _getDictionaryItemsPaginated(DICT_FIAT, language, "", "", offset, limit);
    }

    function getAllPaymentMethodsPaginated(string memory language, uint256 offset, uint256 limit)
        external view returns (string[] memory results, uint256 total) {
        return _getDictionaryItemsPaginated(DICT_PAYMENT, language, "", "", offset, limit);
    }

    function addFiatType(string memory language, string memory fiatType) external onlyAdminOrCS { _addDictionaryItem(DICT_FIAT, language, "", "", fiatType); }
    function batchAddFiatTypes(string calldata language, string[] calldata fiatTypes) external onlyAdminOrCS { for (uint i; i < fiatTypes.length; i++) _addDictionaryItem(DICT_FIAT, language, "", "", fiatTypes[i]); }
    function removeFiatType(string memory language, string memory fiatType) external onlyAdminOrCS { _removeDictionaryItem(DICT_FIAT, language, "", "", fiatType); }
    function addPaymentMethod(string memory language, string memory method) external onlyAdminOrCS { _addDictionaryItem(DICT_PAYMENT, language, "", "", method); }
    function batchAddPaymentMethods(string calldata language, string[] calldata methods) external onlyAdminOrCS { for (uint i; i < methods.length; i++) _addDictionaryItem(DICT_PAYMENT, language, "", "", methods[i]); }
    function removePaymentMethod(string memory language, string memory method) external onlyAdminOrCS { _removeDictionaryItem(DICT_PAYMENT, language, "", "", method); }

    function getAllCountries(string memory language) external view returns (string[] memory) { return _getDictionaryItems(DICT_COUNTRY, language, "", ""); }
    function getProvincesByCountry(string memory language, string memory country) external view returns (string[] memory) { return _getDictionaryItems(DICT_PROVINCE, language, country, ""); }
    function getCitiesByProvince(string memory language, string memory country, string memory province) external view returns (string[] memory) { return _getDictionaryItems(DICT_CITY, language, country, province); }

    /// @notice Paginated version: avoids the gas cost of large arrays
    function getAllCountriesPaginated(string memory language, uint256 offset, uint256 limit)
        external view returns (string[] memory results, uint256 total) {
        return _getDictionaryItemsPaginated(DICT_COUNTRY, language, "", "", offset, limit);
    }

    function getProvincesByCountryPaginated(string memory language, string memory country, uint256 offset, uint256 limit)
        external view returns (string[] memory results, uint256 total) {
        return _getDictionaryItemsPaginated(DICT_PROVINCE, language, country, "", offset, limit);
    }

    function getCitiesByProvincePaginated(string memory language, string memory country, string memory province, uint256 offset, uint256 limit)
        external view returns (string[] memory results, uint256 total) {
        return _getDictionaryItemsPaginated(DICT_CITY, language, country, province, offset, limit);
    }
    function isCountryApproved(string memory language, string memory country) public view returns (bool) { return dictionaryApproved[_dictKey(DICT_COUNTRY, language, "", "", country)]; }
    function isProvinceApproved(string memory language, string memory country, string memory province) public view returns (bool) { return dictionaryApproved[_dictKey(DICT_PROVINCE, language, country, "", province)]; }
    function isCityApproved(string memory language, string memory country, string memory province, string memory city) external view returns (bool) { return dictionaryApproved[_dictKey(DICT_CITY, language, country, province, city)]; }
    function addCountry(string memory language, string memory country) external onlyAdminOrCS { _addDictionaryItem(DICT_COUNTRY, language, "", "", country); }
    function batchAddCountries(string calldata language, string[] calldata countries) external onlyAdminOrCS { for (uint i; i < countries.length; i++) _addDictionaryItem(DICT_COUNTRY, language, "", "", countries[i]); }
    function removeCountry(string memory language, string memory country) external onlyAdminOrCS { _removeDictionaryItem(DICT_COUNTRY, language, "", "", country); }
    function addProvince(string memory language, string memory country, string memory province) external onlyAdminOrCS { if (!isCountryApproved(language, country)) revert NotApproved(); _addDictionaryItem(DICT_PROVINCE, language, country, "", province); }
    function batchAddProvinces(string calldata language, string calldata country, string[] calldata provinces) external onlyAdminOrCS { if (!isCountryApproved(language, country)) revert NotApproved(); for (uint i; i < provinces.length; i++) _addDictionaryItem(DICT_PROVINCE, language, country, "", provinces[i]); }
    function removeProvince(string memory language, string memory country, string memory province) external onlyAdminOrCS { _removeDictionaryItem(DICT_PROVINCE, language, country, "", province); }
    function addCity(string memory language, string memory country, string memory province, string memory city) external onlyAdminOrCS { if (!isProvinceApproved(language, country, province)) revert NotApproved(); _addDictionaryItem(DICT_CITY, language, country, province, city); }
    function batchAddCities(string calldata language, string calldata country, string calldata province, string[] calldata cities) external onlyAdminOrCS { if (!isProvinceApproved(language, country, province)) revert NotApproved(); for (uint i; i < cities.length; i++) _addDictionaryItem(DICT_CITY, language, country, province, cities[i]); }
    function removeCity(string memory language, string memory country, string memory province, string memory city) external onlyAdminOrCS { _removeDictionaryItem(DICT_CITY, language, country, province, city); }

    // ==================== Aggregate Query ====================

    /// @notice Aggregate query of merchant statistics
    /// @param merchant Merchant address
    /// @return totalOrders Total completed orders
    /// @return arbitrations Number of arbitrations
    /// @return lastActive Last active time
    /// @return isRisk Whether the merchant is a risk merchant
    function getMerchantStats(address merchant) external view returns (
        uint256 totalOrders, uint256 arbitrations, uint256 lastActive, bool isRisk
    ) {
        totalOrders = merchantTotalOrders[merchant];
        arbitrations = merchantArbitrations[merchant];
        lastActive = merchantLastActive[merchant];
        isRisk = totalOrders > 0 && (arbitrations * 10000 / totalOrders) > riskThreshold;
    }


}

