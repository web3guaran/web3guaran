// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * ============================================================
 *  Shared Interfaces and Data Structures
 *  Interface definitions, enums, and structs shared by all contracts
 * ============================================================
 */

// ============ IERC20 Standard Token Interface ============
interface IERC20 {
    /// @notice Get total token supply
    function totalSupply() external view returns (uint256);                          // Get total token supply
    /// @notice Query token balance of an address
    function balanceOf(address account) external view returns (uint256);             // Query token balance of an address
    /// @notice Transfer tokens to a specified address
    /// @dev Called directly by user or internally by contracts; caller must have sufficient balance
    function transfer(address to, uint256 amount) external returns (bool);           // Transfer tokens to specified address
    /// @notice Query allowance
    function allowance(address owner, address spender) external view returns (uint256); // Query allowance
    /// @notice Approve token spending allowance for an address
    /// @dev Called by user before purchase/deposit, authorizing product/deposit contract to deduct
    function approve(address spender, uint256 amount) external returns (bool);       // Approve token spending allowance
    /// @notice Transfer tokens from an authorized address
    /// @dev Called by product/deposit/trade contracts; requires prior approve authorization
    function transferFrom(address from, address to, uint256 amount) external returns (bool); // Transfer tokens from authorized address
    /// @notice Get token decimals (USDT=6)
    function decimals() external view returns (uint8);                               // Get token decimals
}

// ============ IPlatformSettings Platform Configuration Center Interface ============
interface IPlatformSettings {
    /// @notice Get contract owner address
    function owner() external view returns (address);                               // Get contract owner address
    /// @notice Check if address is admin
    function isAdmin(address addr) external view returns (bool);                    // Check if address is admin
    /// @notice Check if address is customer service
    function isCustomerService(address addr) external view returns (bool);          // Check if address is customer service
    /// @notice Check if address is admin or customer service
    function isAdminOrCS(address addr) external view returns (bool);                // Check if address is admin or customer service
    /// @notice Get fee rate (basis points, 10000=100%)
    /// @dev Called by product/auction/C2C contracts during settlement
    function getFeeRate(uint8 productType) external view returns (uint256);         // Get fee rate (basis points, 10000=100%)
    /// @notice Get risky merchant threshold (basis points)
    function getRiskThreshold() external view returns (uint256);                    // Get risky merchant threshold (basis points)
    /// @notice Get level-1 inviter commission ratio
    function getLevel1Rate() external view returns (uint256);                       // Get level-1 inviter commission ratio
    /// @notice Get level-2 inviter commission ratio
    function getLevel2Rate() external view returns (uint256);                       // Get level-2 inviter commission ratio
    /// @notice Get platform retention ratio
    function getPlatformRate() external view returns (uint256);                     // Get platform retention ratio
    /// @notice Get platform receiving wallet address
    function getPlatformWallet() external view returns (address);                   // Get platform receiving wallet address
    /// @notice Get platform fee splitter contract address
    /// @dev Recipient contracts should transferFrom to splitter and call distribute() in same tx for atomic 3-way split
    function getFeeSplitter() external view returns (address);                      // Get platform fee splitter contract address
    /// @notice Record merchant arbitration count +1 (only authorized contracts can call)
    /// @dev Called by product/auction contracts when arbitration ends, for risk control statistics
    function recordArbitration(address seller) external;                            // Record merchant arbitration count +1
    /// @notice Record merchant completed order count +1 (only authorized contracts can call)
    /// @dev Called by product/auction contracts when order completes
    function recordOrder(address seller) external;                                  // Record merchant completed order count +1
    /// @notice Check if merchant is risky (arbitration rate exceeds threshold)
    function isRiskMerchant(address seller) external view returns (bool);           // Check if merchant is risky
    /// @notice Check if address is an authorized contract
    /// @dev Used for permission checks; only authorized contracts can call write methods like recordArbitration
    function isAuthorizedContract(address addr) external view returns (bool);       // Check if address is authorized contract
    /// @notice Get cooldown manager contract address
    function getCooldownManager() external view returns (address);                  // Get cooldown manager contract address
    /// @notice Get product factory contract address
    function getProductFactory() external view returns (address);                   // Get product factory contract address
    /// @notice Get deposit factory contract address
    function getDepositFactory() external view returns (address);                   // Get deposit factory contract address
    /// @notice Check if address is blacklisted
    function isBlacklisted(address addr) external view returns (bool);              // Check if address is blacklisted
    /// @notice Record fee (accumulated to platform total fees by token)
    /// @dev Called by product/auction/C2C contracts during settlement; token is the payment token used in this transaction (USDT)
    function recordFee(uint256 amount, address token) external;                     // Record fee (accounting by token)
    /// @notice Record deposit in (accumulated to platform total deposit by token)
    /// @dev Called by deposit contract when merchant tops up
    function recordDepositIn(uint256 amount, address token) external;               // Record deposit in (accounting by token)
    /// @notice Record deposit out (deducted from platform total deposit by token)
    /// @dev Called by deposit contract on deduction/redemption
    function recordDepositOut(uint256 amount, address token) external;              // Record deposit out (accounting by token)
    /// @notice Get platform cumulative fee total (by token)
    function getTotalFees(address token) external view returns (uint256);           // Get platform cumulative fee total
    /// @notice Get platform currently held deposit total (by token)
    function getTotalDepositsHeld(address token) external view returns (uint256);   // Get platform currently held deposit total
    // ===== Payment Channel: token registration =====
    /// @notice Check if token is a platform-registered payment channel (USDT)
    function isAcceptedToken(address token) external view returns (bool);
    /// @notice Get all registered payment channel token list
    function getAcceptedTokens() external view returns (address[] memory);
    // ===== Dual Payment Channel: merchant income accounting (7 data groups, nested mapping by (seller, token)) =====
    /// @notice Record order settlement (seller completes an order, accumulated by token for net income and gross amount)
    /// @dev Called by product/auction/C2C templates during _settle; netIncome = order amount minus fees
    /// @param seller Seller address
    /// @param token Payment token used for this order
    /// @param netIncome Seller net income (order amount - platform fee)
    /// @param grossAmount Order gross amount
    function recordSettlement(address seller, address token, uint256 netIncome, uint256 grossAmount) external;
    /// @notice Record refund (seller refunds buyer, accumulated by token)
    /// @dev Called by product/C2C templates during sellerRefund / cancelOrder
    function recordRefund(address seller, address token, uint256 amount) external;
    /// @notice Record arbitration payout (arbitration awards buyer, accumulated by token)
    /// @dev Called by product/auction/arbitration templates during resolveArbitration / communityResolve when buyer wins
    function recordArbitrationPayout(address seller, address token, uint256 amount) external;
    /// @notice Aggregated query of merchant income statistics for a specific token
    /// @return completedAmount Total completed order amount
    /// @return completedCount Completed order count
    /// @return refundedAmount Total refunded amount
    /// @return refundedCount Refund count
    /// @return arbPayoutAmount Total arbitration payout amount
    /// @return arbPayoutCount Arbitration payout count
    /// @return netIncome Cumulative net income (completed minus refunds and payouts)
    function getMerchantIncomeStats(address seller, address token) external view returns (
        uint256 completedAmount,
        uint256 completedCount,
        uint256 refundedAmount,
        uint256 refundedCount,
        uint256 arbPayoutAmount,
        uint256 arbPayoutCount,
        uint256 netIncome
    );
    /// @notice Get merchant last active time
    function getMerchantLastActive(address merchant) external view returns (uint256); // Get merchant last active time
    /// @notice Check if fiat type is approved under multi-language market
    function isFiatTypeApproved(string calldata language, string calldata fiatType) external view returns (bool);
    /// @notice Check if payment method is approved under multi-language market
    function isPaymentMethodApproved(string calldata language, string calldata method) external view returns (bool);
    /// @notice Factory authorizes contract (only deposit factory can call)
    /// @dev Called by DepositFactory after creating deposit contract, to authorize the new contract
    function authorizeContractByFactory(address addr) external;                     // Factory authorizes contract (only deposit factory can call)
    /// @notice Aggregated query of merchant statistics (total orders, arbitrations, last active, is risky)
    function getMerchantStats(address merchant) external view returns (             // Aggregated merchant statistics query
        uint256 totalOrders, uint256 arbitrations, uint256 lastActive, bool isRisk
    );
    /// @notice Get C2C factory contract address
    function getC2CFactory() external view returns (address);                       // Get C2C factory contract address
    /// @notice Add to blacklist (admin only)
    function addBlacklist(address addr) external;                                   // Add to blacklist
    /// @notice Remove from blacklist (admin only)
    function removeBlacklist(address addr) external;                                // Remove from blacklist
    /// @notice Check if country is approved under multi-language market
    function isCountryApproved(string calldata language, string calldata country) external view returns (bool);
    /// @notice Check if province is approved under multi-language market
    function isProvinceApproved(string calldata language, string calldata country, string calldata province) external view returns (bool);
    /// @notice Check if city is approved under multi-language market
    function isCityApproved(string calldata language, string calldata country, string calldata province, string calldata city) external view returns (bool);
    /// @notice Get auction factory contract address
    function getAuctionFactory() external view returns (address);                  // Get auction factory contract address
    /// @notice Get community arbitration factory contract address
    function getCommunityArbitrationFactory() external view returns (address);     // Get community arbitration factory contract address
    /// @notice Check deposit requirement and get max products allowed
    /// @dev Returns (meetsRequirement, maxProducts) - if requireDepositForPublish is true, meetsRequirement = hasDeposit
    function checkDepositRequirement(address seller) external view returns (bool meetsRequirement, uint256 currentDeposit, uint256 maxProducts);
    /// @notice Check if address is in contract wallet whitelist
}

// ============ IPlatformFeeSplitter Platform Fee Splitter Interface ============
interface IPlatformFeeSplitter {
    /// @notice Distribute the specified amount of token already held by the splitter to the 7 payees
    /// @dev Caller must ensure splitter holds at least `amount` of `token` before calling (typically by calling transferFrom to splitter in the same tx)
    function distribute(address token, uint256 amount) external;
    /// @notice Get payee addresses (used by PlatformSettings.setFeeSplitter for locked-payee validation)
    function payee0() external view returns (address);
    function payee1() external view returns (address);
    function payee2() external view returns (address);
    function payee3() external view returns (address);
    function payee4() external view returns (address);
    function payee5() external view returns (address);
    function payee6() external view returns (address);
    function payee7() external view returns (address);
}

// ============ IInviteRegistry Invite Relationship Registration Interface ============
interface IInviteRegistry {
    /// @notice Get user's level-1 and level-2 inviters
    function getInviters(address user) external view returns (address level1, address level2); // Get user's level-1 and level-2 inviters
    /// @notice Distribute fee to inviters and platform
    /// @dev Called by product/auction/C2C contracts during settlement, distributes fee proportionally to level1/level2/platform
    function distributeFee(address user, uint256 feeAmount, IERC20 token) external;            // Distribute fee to inviters and platform
    /// @notice Get user's cumulative commission earned
    function totalEarned(address user) external view returns (uint256);                        // Get user's cumulative commission earned
}

// ============ IKeywordWeight Keyword Weight Aggregation Interface ============
interface IKeywordWeight {
    /// @notice Record sale (update product sales amount and order count)
    /// @dev Called by product contract when order settlement completes
    function recordSale(address product, uint256 amount) external;                 // Record sale (update product sales and order count)
    /// @notice Get product cumulative historical order count (sales count)
    function getTotalOrders(address product) external view returns (uint256);      // Get product cumulative historical order count
    /// @notice Factory authorizes clone contract as caller
    /// @dev Called by ProductFactory after creating product clone
    function addAuthorizedCallerByFactory(address caller) external;                // Factory authorizes clone contract as caller
}

// ============ IKeywordAuction Keyword Bidding Ranking Interface ============
interface IKeywordAuction {
    /// @notice Product-level bidding, leaderboard isolated by language + keyword
    /// @dev Called by product seller, requires prior USDT approve to this contract
    function bid(string calldata language, string calldata keyword, address product, uint256 amount) external; // Product-level bidding
    /// @notice Get today's top 20 bidding products and amounts for a language keyword
    function getTopProducts(string calldata language, string calldata keyword) external view returns (address[20] memory, uint256[20] memory); // Get today's top 20 bidding products and amounts for a language keyword
    /// @notice Check if product is in top 20
    function isTopProduct(string calldata language, string calldata keyword, address product) external view returns (bool); // Check if product is in top 20
    /// @notice Get current day number (timestamp/86400)
    function getCurrentDay() external view returns (uint256);                       // Get current day number (timestamp/86400)
    /// @notice Get today's top 20 service bidding products for a full (language,keyword,country,province,city) key
    function getTopServiceProducts(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) external view returns (address[20] memory, uint256[20] memory);
}

// ============ IDepositFactory Deposit Factory Interface ============
interface IDepositFactory {
    /// @notice Check if merchant has a deposit contract
    function hasDeposit(address merchant) external view returns (bool);              // Check if merchant has deposit contract
    /// @notice Get merchant's deposit contract address
    function getDeposit(address merchant) external view returns (address);           // Get merchant's deposit contract address
    /// @notice Create deposit contract
    /// @dev Called directly by merchant; each merchant can only create one
    function createDeposit() external returns (address);                             // Create deposit contract
    /// @notice Admin recycles zombie deposit (365 days inactive)
    /// @dev Called by admin; will first batch delist products and cancel C2C orders
    function adminRecycleDeposit(address merchant) external;                        // Admin recycles zombie deposit
    /// @notice Get total deposit contract count
    function getDepositCount() external view returns (uint256);                      // Get total deposit contract count
    /// @notice Paginated query of all deposit contracts
    function getAllDeposits(uint256 offset, uint256 limit) external view returns (address[] memory); // Paginated query of all deposit contracts
    /// @notice Refresh merchant deposit activity time (only three major factories can call)
    /// @dev Called by product/auction/C2C factory on shipment/trade
    function refreshMerchantActivity(address merchant) external;                    // Refresh merchant deposit activity time (only three major factories can call)
    /// @notice Refresh unified deposit unlock cooldown (only three major factories can call)
    function refreshUnlockCooldown(address merchant) external;
    /// @notice Check if unified deposit cooldown has completed
    function canWithdrawDeposit(address merchant) external view returns (bool);
    /// @notice Query unified deposit cooldown details
    function getUnlockCooldownInfo(address merchant) external view returns (bool, uint256, uint256, bool, uint256, uint256, uint256, uint256);
}

// ============ IMerchantDeposit Merchant Deposit Interface ============
/// @dev Single deposit contract holds USDT; all amount-based operations require token param.
interface IMerchantDeposit {
    /// @notice Get merchant address
    function merchant() external view returns (address);
    /// @notice Get deposit balance for a specific token
    function balanceOf(address token) external view returns (uint256);
    /// @notice Get deposit status (shared, consistent across tokens)
    function status() external view returns (DepositStatus);
    /// @notice Check if deposit is sufficient (any token balance > 0 and not withdrawn)
    function hasAnyDeposit() external view returns (bool);
    /// @notice Check if specific token is sufficient (balance > 0 and not withdrawn) -- used for KeywordWeight calculation
    function isSufficient(address token) external view returns (bool);
    /// @notice Force recycle zombie deposit (only factory can call, transfers both tokens to platform wallet)
    function forceRecycle() external;
    /// @notice Get last activity time
    function lastActivityTime() external view returns (uint256);
    /// @notice Deduct deposit (only authorized product contracts can call, deducts by token and transfers to buyer)
    function deduct(uint256 amount, address to, address token) external;
    /// @notice Merchant authorizes product contract to deduct
    function authorizeProduct(address product) external;
    /// @notice Revoke product contract authorization
    function revokeProductAuthorization(address product) external;
    /// @notice Freeze deposit for a specific token (auction/arbitration general purpose)
    function freezeDeposit(uint256 amount, address token) external;
    /// @notice Unfreeze partial deposit for a specific token (by caller dimension)
    function unfreezeDepositAmount(uint256 amount, address token) external;
    /// @notice Unfreeze deposit for a specific token (by caller dimension)
    function unfreezeDeposit(address token) external;
    /// @notice Unfreeze all frozen amounts across all tokens for caller (one-time cleanup when arbitration ends)
    function unfreezeAll() external;
    /// @notice Deduct from frozen amount by token (when arbitration awards buyer)
    function deductFromFrozen(uint256 amount, address to, address token) external;
    /// @notice Transfer frozen allocation from caller to another contract (for arbitration seizure)
    function transferFrozenAllocation(uint256 amount, address newCaller, address token) external;
    /// @notice Query caller's frozen amount for a specific token
    function callerFrozenAmounts(address caller, address token) external view returns (uint256);
    /// @notice Get available balance for a specific token (unfrozen portion)
    function getAvailableBalance(address token) external view returns (uint256);
    /// @notice Authorize arbitration case contract to operate deposit
    function authorizeCase(address caseContract) external;
    /// @notice Get current total frozen amount for a specific token
    function frozenAmountOf(address token) external view returns (uint256);
    /// @notice Get deposit complete info
    /// @return merchantAddr Merchant address
    /// @return balanceUsdt USDT balance
    /// @return status_ Deposit status
    /// @return withdrawable Whether redeemable
    /// @return unlockTime Unlock timestamp (0=already redeemable; max=active orders/trades, cannot estimate)
    /// @return frozenUsdt USDT frozen amount
    function getDepositInfo() external view returns (
        address merchantAddr,
        uint256 balanceUsdt,
        DepositStatus status_,
        bool withdrawable,
        uint256 unlockTime,
        uint256 frozenUsdt
    );
    /// @notice Refresh activity time (only factory can call)
    function refreshActivity() external;
}

// ============ IProductFactory Product Factory Interface ============
interface IProductFactory {
    /// @notice Check if product contract was created by factory
    function isFactoryProduct(address product) external view returns (bool);        // Check if product contract was created by factory
    /// @notice Get product type
    function productType(address product) external view returns (uint8);            // Get product type
    /// @notice Product delisting notification (called by product contract)
    /// @dev Called by product template on delisting, updates seller active product count
    function productDelisted(address _seller) external;                             // Product delisting notification (called by product contract)
    /// @notice Buyer purchase notification (called by product contract)
    /// @dev Called by product template on order creation, records buyer order index
    function orderCreated(address buyer) external;                                  // Buyer purchase notification (records buyer order index)
    /// @notice Arbitration creation callback (called by product contract)
    /// @dev Called by product template when arbitration is initiated, updates disputed product list
    function disputeCreated(address product) external;                             // Arbitration creation callback (called by product contract)
    /// @notice Arbitration completion callback (called by product contract)
    /// @dev Called by product template when arbitration ends, removes disputed product
    function disputeResolved(address product) external;                            // Arbitration completion callback (called by product contract)
    /// @notice Query product keyword
    function productKeyword(address product) external view returns (string memory); // Query product keyword
    /// @notice Check if merchant can redeem deposit (all products delisted and cooldown met)
    /// @dev Called by deposit contract when merchant redeems
    function canWithdrawDeposit(address _seller) external view returns (bool);      // Check if merchant can redeem deposit (all products delisted 24h)
    /// @notice Get delisting info: active product count, last delist time, can redeem
    function getDelistInfo(address _seller) external view returns (uint256, uint256, bool); // Active product count, last delist time, can redeem
    /// @notice Batch delist all merchant products during zombie recycling (only deposit factory can call)
    /// @dev Called by DepositFactory during adminRecycleDeposit
    function delistAllProductsFor(address seller) external;                        // Batch delist all merchant products during zombie recycling (only deposit factory can call)
    /// @notice Get delisting cooldown duration (seconds)
    function DELIST_COOLDOWN() external view returns (uint256);                     // Get delisting cooldown duration (seconds)
    /// @notice Product shipment notification (called by product contract)
    /// @dev Called by product template on shipment, refreshes deposit activity
    function orderShipped(address _seller) external;                               // Product shipment notification (refreshes deposit activity)
    /// @notice Want-to-buy seller acceptance notification (called by WantToBuy contract)
    /// @dev Records seller-to-WantToBuy contract association for seller order lookup
    function orderAcceptedBySeller(address _seller) external;                      // Want-to-buy seller acceptance notification (records seller index)
    /// @notice Get keyword seed for pagination
    function keywordSeed(bytes32 key) external view returns (uint256);             // Get keyword seed for pagination
    /// @notice Bump seed externally (called by KeywordAuction when ranking changes)
    function bumpSeedExternal(string calldata language, string calldata keyword) external; // Bump seed externally
    /// @notice Bump seed on product sale (called by KeywordWeight)
    /// @dev Called by KeywordWeight.recordSale to trigger seed refresh on transaction completion
    function bumpSeedOnSale(address product) external;                            // Bump seed on product sale (called by KeywordWeight)
    /// @notice Bump seed on product activity (purchase/ship/receive)
    /// @dev Called by factory products during normal business activities to increase exposure
    function bumpSeedOnActivity(address product) external;                        // Bump seed on product activity
    /// @notice Get the ServiceLocationIndex address (service geographic index)
    function serviceLocationIndex() external view returns (address);              // Service geographic index address
}

// ============ IServiceLocationIndex Service Geographic Index (register/remove + read for bid city-binding + ranking) ============
interface IServiceLocationIndex {
    /// @notice Register a service product under its geographic hierarchy (factory only)
    function registerProduct(address product, string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) external;
    /// @notice Remove a service product from its city index (factory only)
    function removeProduct(address product) external;
    /// @notice cityKey a product is registered under: keccak256(abi.encode(language,keyword,country,province,city))
    function productCityKey(address product) external view returns (bytes32);
    /// @notice Number of products under a city
    function getCityProductCount(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) external view returns (uint256);
    /// @notice Indexed access into a city's product list (public array getter)
    function cityProducts(bytes32 cityKey, uint256 index) external view returns (address);
}

// ============ IProductTemplate Product Template Common Interface (for batch settlement) ============
interface IProductTemplate {
    /// @notice Get seller address
    function seller() external view returns (address);                              // Get seller address
    /// @notice Get keyword
    function keyword() external view returns (string memory);                       // Get keyword
    function language() external view returns (string memory);                      // Get language code
    function metadataURI() external view returns (string memory);                   // Get metadata URI
    /// @notice Whether delisted
    function delisted() external view returns (bool);                               // Whether delisted
    /// @notice Active order count
    function activeOrderCount() external view returns (uint256);                     // Active order count
    /// @notice Get all active order expiry info (for batch auto-receive)
    function getActiveOrderExpiryInfos() external view returns (bytes16[] memory, OrderStatus[] memory, uint64[] memory, uint256[] memory);
    /// @notice Trigger auto-receive (anyone can call after timeout)
    /// @dev Called by backend scheduled task or anyone after autoReceiveDeadline expires
    function triggerAutoReceive(bytes16 orderId) external;                           // Trigger auto-receive (callable after timeout)
    /// @notice Admin force delist
    /// @dev Called directly by admin/customer service
    function adminDelistProduct() external;                                         // Admin force delist
    /// @notice Factory proxy delist (for zombie recycling)
    /// @dev Called by ProductFactory during delistAllProductsFor
    function delistByFactory(address _seller) external;                             // Factory proxy delist
}

// ============ Three Product Template initialize Interfaces (called by ProductFactory after cloning) ============
/// @dev The following three initialize interfaces are called by ProductFactory immediately after cloning a product template, to complete initialization
interface IPhysicalProductTemplate {
    /// @notice Initialize physical product template clone
    /// @dev Called by ProductFactory during createProduct, can only be called once
    function initialize(
        address _seller, ProductStrings calldata _strings,
        Spec[] calldata _specs, string[] calldata _images,
        uint8 _deliveryMethod,
        PlatformContracts calldata _contracts,
        address _merchantDeposit
    ) external;
    /// @notice Get product info (for seed bump on sale)
    function getProductInfo() external view returns (
        address seller_, string memory keyword_, string memory language_,
        string memory metadataURI_, uint8 deliveryMethod_, bool delisted_,
        uint256 activeOrderCount_,
        string[] memory specNames, uint256[] memory specPrices, uint256[] memory specStocks
    );
}

interface IVirtualProductTemplate {
    /// @notice Initialize virtual product template clone
    function initialize(
        address _seller, ProductStrings calldata _strings,
        Spec[] calldata _specs, string[] calldata _images,
        PlatformContracts calldata _contracts,
        address _merchantDeposit
    ) external;
}

interface IServiceProductTemplate {
    /// @notice Initialize service product template clone
    function initialize(
        address _seller, ServiceStrings calldata _strings,
        string[] calldata _images, ServiceItem[] calldata _serviceItems,
        PlatformContracts calldata _contracts,
        address _merchantDeposit
    ) external;
}

interface IWantToBuyTemplate {
    function initialize(
        address _buyer, ProductStrings calldata _strings,
        uint256 _requestPrice, uint256 _stock,
        string[] calldata _images,
        PlatformContracts calldata _contracts
    ) external;
    function buyer() external view returns (address);
    function keyword() external view returns (string memory);
    function language() external view returns (string memory);
    function delisted() external view returns (bool);
    function activeOrderCount() external view returns (uint256);
    function delistByFactory(address _buyer) external;
    function adminDelistProduct() external;
    function getProductInfo() external view returns (
        address buyer_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_, uint256 requestPrice_, uint256 stock_, uint256 originalStock_
    );
}

// ============ IC2CSellOrder / IC2CBuyOrder Minimal Read Interface ============
interface IC2CSellOrder {
    /// @notice Get seller address
    function seller() external view returns (address);                              // Get seller address
}
interface IC2CBuyOrder {
    /// @notice Get buyer address
    function buyer() external view returns (address);                               // Get buyer address
    /// @notice Lock an amount for an in-flight trade (factory only)
    function lockAmount(uint256 amount) external;
    /// @notice Release a locked amount back to available (factory only)
    function unlockAmount(uint256 amount) external;
    /// @notice Remaining available USDT = total - filled - locked
    function getAvailable() external view returns (uint256);
    /// @notice Forfeit buyer's buy-order deposit for a disputed fill to the arbitration case (seller won).
    /// @param maxForfeit Upper bound on how much of the freed deposit slice may be forfeited to the case
    ///        (the arbitration-fee shortfall left uncovered by the buyer's MD guarantee). Any excess is
    ///        unfrozen back to the buyer's available balance instead of being forfeited.
    function forfeitDepositToCase(uint256 amount, address caseContract, uint256 maxForfeit) external returns (uint256);
    /// @notice Seize buy-order frozen deposit for post-completion arbitration (transfers allocation to caller)
    function seizeForArbitration(uint256 amount, address token) external returns (uint256);
    /// @notice Freeze down available capacity (release available-slice deposit, keep locked deposit)
    function freezeAvailableForArbitration() external returns (uint256);
    /// @notice Whether available capacity has been frozen down for arbitration (display flag)
    function availableFrozen() external view returns (bool);
    /// @notice Get buy-order language (for arbitration language inheritance)
    function language() external view returns (string memory);
}

// ============ IC2CFactory C2C Factory Callback Interface ============
interface IC2CFactory {
    /// @notice Dispute creation callback (called by trade contract)
    /// @dev Called by C2CTrade when dispute is raised, updates disputed trade list
    function disputeCreated(address trade) external;                               // Dispute creation callback (called by trade contract)
    /// @notice Dispute resolution callback (called by trade contract)
    /// @dev Called by C2CTrade when arbitration ends, removes disputed trade
    function disputeResolved(address trade) external;                              // Dispute resolution callback (called by trade contract)
    /// @notice Sell order ended callback (called by sell order contract)
    /// @dev Called by C2CSellOrder on cancellation/full fill
    function sellOrderEnded(address order) external;                               // Sell order ended callback (called by sell order contract)
    /// @notice Buy order ended callback (called by buy order contract)
    /// @dev Called by C2CBuyOrder on cancellation/full fill
    function buyOrderEnded(address order) external;                                // Buy order ended callback (called by buy order contract)
    /// @notice Verify sell order was created by factory
    function isFactorySellOrder(address order) external view returns (bool);       // Verify sell order was created by factory
    /// @notice Verify buy order was created by factory
    function isFactoryBuyOrder(address order) external view returns (bool);        // Verify buy order was created by factory
    /// @notice Verify trade was created by factory
    function isFactoryTrade(address trade) external view returns (bool);           // Verify trade was created by factory
    /// @notice Get active sell orders (paginated)
    function getActiveSellOrders(uint256 offset, uint256 limit) external view returns (address[] memory); // Get active sell orders
    /// @notice Get active buy orders (paginated)
    function getActiveBuyOrders(uint256 offset, uint256 limit) external view returns (address[] memory); // Get active buy orders
    /// @notice Get disputed trades (paginated)
    function getDisputedTrades(uint256 offset, uint256 limit) external view returns (address[] memory); // Get disputed trades
    /// @notice Get PlatformSettings contract address
    function settingsAddr() external view returns (address);                       // Get PlatformSettings contract address
    /// @notice Batch cancel merchant orders during zombie recycling (max 50 per call)
    /// @dev Called by DepositFactory during adminRecycleDeposit, returns whether all done
    function cancelAllOrdersFor(address merchant) external returns (bool allDone);  // Batch cancel merchant orders during zombie recycling (max 50, returns whether all done)
    /// @notice Freeze available capacity of all of a buyer's active buy orders for a buy-order arbitration
    /// @dev Called by the disputing trade in requestCommunityDispute (post-completion + isBuyOrderTrade only)
    function freezeBuyerActiveBuyOrders(address buyer) external;
    /// @notice Decrement the buyer's in-progress buy-order arbitration counter on dispute resolve
    /// @dev Called by the resolving trade in communityResolveDispute (only if it had triggered freeze)
    function endBuyOrderArbitration(address buyer) external;
    /// @notice Number of in-progress buy-order arbitrations a buyer is a respondent in
    function buyerBuyOrderArbCount(address buyer) external view returns (uint256);
    /// @notice Query user's active C2C order count
    function activeOrderCountOf(address merchant) external view returns (uint256);
    /// @notice Refresh merchant deposit activity (called by trade contract)
    /// @dev Called by C2CTrade when trade completes
    function tradeActivityRefresh(address _merchant) external;                     // Refresh merchant deposit activity (called by trade contract)
    /// @notice Record C2C trade completion (C2C-specific accumulator, separate from PlatformSettings shared statistics)
    /// @dev Called by C2CTrade._completeTrade / communityResolveDispute when trade completes
    /// @param seller Seller address
    /// @param buyer Buyer address
    /// @param token Trade payment token (must match order paymentToken)
    /// @param amount Trade amount (USDT smallest unit)
    /// @param hadDispute Whether arbitration occurred
    function recordC2CTrade(address seller, address buyer, address token, uint256 amount, bool hadDispute) external;
    /// @notice Update buy order filledAmount after buy-order trade completes
    function buyOrderTradeFilled(address buyOrder, uint256 amount) external;
    /// @notice Release a buy order's locked amount when a buy-order trade is cancelled/timed out
    function buyOrderTradeUnlock(address buyOrder, uint256 amount) external;
    /// @notice Dual payment channel: USDT token address (hardcoded at construction)
    function usdtAddr() external view returns (address);
}

// ============ ICooldownManager C2C Cooldown Lock Management Interface (Dual Payment Channel Version) ============
/// @dev Cooldown period / active trade count are user-level state, not per token; but deposit funds are accounted separately by token.
interface ICooldownManager {
    /// @notice Authorize trade contract (only C2CFactory can call)
    function authorizeTrade(address trade) external;
    /// @notice Record user trade started (active count +1)
    function tradeStarted(address user) external;
    /// @notice Record user trade ended (active count -1)
    function tradeEnded(address user) external;
    /// @notice Dispute raised, reset cooldown
    function disputeRaised(address user) external;
    /// @notice [M-05 fix]: Clear dispute status after arbitration completes
    function disputeResolved(address user) external;
    /// @notice Receive buyer deposit (dual-deposit mode, credited by token)
    /// @dev Called by C2CTrade when buyer pays deposit; token must match order paymentToken
    function receiveDeposit(address buyer, uint256 amount, address token) external;
    /// @notice Penalize buyer deposit to seller (arbitration seller wins, transfer by token)
    function penalize(address buyer, address seller, uint256 amount, address token) external;
    /// @notice Release buyer deposit (normal completion / buyer wins arbitration, refund by token)
    function releaseDeposit(address buyer, uint256 amount, address token) external;
    /// @notice Check if user can withdraw deposit (no active trades and cooldown expired; token-independent)
    function canWithdraw(address user) external view returns (bool);
    /// @notice Buyer withdraws deposit for a specific token
    function withdrawDeposit(address token) external;
    /// @notice Get user active trade count (not per token)
    function activeTradeCount(address user) external view returns (uint256);
    /// @notice Get user cooldown start time
    function cooldownStart(address user) external view returns (uint256);
    /// @notice Get deposit info query for a specific token
    /// @return depositBalance Current deposit balance
    /// @return frozenAmount Frozen amount
    /// @return active Active trade count (same as activeTradeCount)
    /// @return canWithdraw_ Whether withdrawable
    /// @return unlockTime Unlock timestamp
    function getDepositInfo(address buyer, address token) external view returns (
        uint256 depositBalance,
        uint256 frozenAmount,
        uint256 active,
        bool canWithdraw_,
        uint256 unlockTime
    );
    /// @notice Get cooldown period duration (seconds)
    function COOLDOWN_PERIOD() external view returns (uint256);
    /// @notice Penalize buyer deposit to arbitration case contract (arbitration fee, by token)
    function penalizeToCase(address buyer, address caseContract, uint256 amount, address token) external;
    /// @notice Partial release of buyer deposit (by token)
    function releasePartialDeposit(address buyer, uint256 amount, address token) external;
}

// ============ IAuctionTemplate Auction Template Interface ============
interface IAuctionTemplate {
    /// @notice Get seller address
    function seller() external view returns (address);                             // Get seller address
    /// @notice Get current highest bidder
    function highestBidder() external view returns (address);                      // Get current highest bidder
    /// @notice Get current highest bid
    function highestBid() external view returns (uint256);                         // Get current highest bid
    /// @notice Get total bid count
    function bidCount() external view returns (uint256);                           // Get total bid count
    /// @notice Get auction status
    function auctionStatus() external view returns (AuctionStatus);                // Get auction status
    /// @notice Get auction basic info (title, description, images, price params)
    function getAuctionInfo() external view returns (                              // Get auction basic info
        address seller_, string memory title_, string memory description_,
        string[] memory images_, uint256 startPrice_, uint256 buyNowPrice_,
        uint256 minBidIncrement_
    );
    /// @notice Get auction bidding info (time, status, highest bid, orderId)
    function getAuctionBidInfo() external view returns (                           // Get auction bidding info
        uint256 startTime_, uint256 endTime_, AuctionStatus status_,
        address highestBidder_, uint256 highestBid_, uint256 bidCount_,
        bytes16 orderId_
    );
}

// ============ IAuctionFactory Auction Factory Interface ============
interface IAuctionFactory {
    /// @notice Verify auction was created by factory
    function isFactoryAuction(address auction) external view returns (bool);        // Verify auction was created by factory
    /// @notice Auction ended callback (called by auction contract)
    /// @dev Called by AuctionTemplate on auction end/no-bid/cancel
    function auctionEnded(address auction) external;                // Auction ended callback (called by auction contract)
    /// @notice Arbitration creation callback (called by auction contract)
    function disputeCreated(address auction) external;                             // Arbitration creation callback (called by auction contract)
    /// @notice Arbitration completion callback (called by auction contract)
    function disputeResolved(address auction) external;                            // Arbitration completion callback (called by auction contract)
    /// @notice Get PlatformSettings contract address
    function settingsAddr() external view returns (address);                       // Get PlatformSettings contract address
    /// @notice Auction shipment notification (called by auction contract)
    /// @dev Called by AuctionTemplate on shipment, refreshes deposit activity
    function auctionShipped(address _seller) external;                             // Auction shipment notification (refreshes deposit activity)
    /// @notice Check if seller has active auctions
    function hasActiveAuctions(address _seller) external view returns (bool);     // Check if seller has active auctions
    /// @notice Query seller's active auction count
    function activeSellerAuctionCount(address _seller) external view returns (uint256);
    /// @notice Bump seed on auction activity (bid/buyNow/ship/receive)
    /// @dev Called by auction contracts during normal business activities to increase exposure
    function bumpSeedOnActivity(address auction) external;                        // Bump seed on auction activity
}

// ============ ICommunityArbitrationFactory Community Arbitration Factory Interface ============
interface ICommunityArbitrationFactory {
    /// @notice Verify case was created by factory
    function isFactoryCase(address caseAddr) external view returns (bool);          // Verify case was created by factory
    /// @notice Check if address is a qualified arbitrator
    function isQualifiedArbitrator(address addr) external view returns (bool);      // Check if address is qualified arbitrator
    /// @notice Create arbitration case (dual payment channel: carries order paymentToken)
    /// @dev Initiated by business contracts (product/auction/C2C); paymentToken determines case settlement token
    function createCase(CaseInitParams calldata params, address paymentToken) external returns (address);
    /// @notice Case resolved callback (called by case contract)
    function caseResolved(address caseAddr) external;                               // Case resolved callback
    /// @notice Record arbitrator vote result (correct/incorrect)
    function recordVoteResult(address arbitrator, bool wasCorrect) external;        // Record arbitrator vote result
    /// @notice Update global vote time
    function updateGlobalVoteTime() external;                                       // Update global vote time
    /// @notice Get last global vote time
    function lastGlobalVoteTime() external view returns (uint256);                  // Get last global vote time
    /// @notice Get active case list (paginated)
    function getActiveCases(uint256 offset, uint256 limit) external view returns (address[] memory); // Get active case list
    /// @notice Get community arbitration case for a specific business order
    function getCaseForBusiness(address businessContract, bytes16 orderId) external view returns (address);
    /// @notice Get arbitrator info (qualify time, wrong votes, cooldown deadline, is qualified)
    function getArbitratorInfo(address addr) external view returns (                // Get arbitrator info
        uint256 qualifyTime, uint256 wrongVotes, uint256 cooldownUntil, bool qualified
    );
    /// @notice Get vote interval duration
    function VOTE_INTERVAL() external view returns (uint256);                       // Get vote interval duration
    /// @notice Get arbitration window duration
    function ARBITRATION_WINDOW() external view returns (uint256);
    /// @notice Get standard arbitration fee rate (basis points)
    function ARBITRATION_FEE_RATE() external view returns (uint256);                  // Get arbitration fee rate
    /// @notice Get payment token for a specific case (USDT)
    function getCaseToken(address caseAddr) external view returns (address);
    /// @notice Dual payment channel: USDT token address (for arbitrator qualification check)
    function usdtAddr() external view returns (address);
}

// ============ ICommunityArbitrationTemplate Community Arbitration Case Template Interface ============
interface ICommunityArbitrationTemplate {
    /// @notice Initialize arbitration case
    /// @dev Called by factory after cloning, can only be called once
    function initialize(
        CaseInitParams calldata params,
        uint256 evidenceWindow,
        uint256 votingDuration,
        uint256 maxArbitrators
    ) external;
    /// @notice Respondent submits evidence
    function submitRespondentEvidence(string calldata evidence, string[] calldata images) external; // Respondent submits evidence
    /// @notice Start voting phase
    function startVoting() external;                                                // Start voting phase
    /// @notice Arbitrator votes
    function vote(bool voteForBuyer) external;                                      // Arbitrator votes
    /// @notice Admin ruling (on tie or timeout)
    function adminRule(bool buyerWins, string calldata reasonHash) external;         // Admin ruling
    /// @notice Finalize case (execute compensation/refund)
    function finalize() external;                                                   // Finalize case
    /// @notice Distribute arbitrator rewards
    function distributeRewards() external;                                          // Distribute arbitrator rewards
    /// @notice Get case language (for market isolation indexing)
    function language() external view returns (string memory);                      // Get case language
}

// ============ IProductFactoryKeywords Keyword Management Interface ============
/// @dev Keyword approval sub-contract interface, delegated by ProductFactory
interface IProductFactoryKeywords {
    /// @notice Check if keyword is approved for a given language
    function isApproved(string calldata language, string calldata keyword) external view returns (bool);
    /// @notice Get keyword unique key
    function getKeywordKey(string memory language, string memory keyword) external pure returns (bytes32);
    /// @notice Query keyword approval status (direct mapping access)
    function approvedKeywordKeys(bytes32 keywordKey) external view returns (bool);
    /// @notice Get keyword type (0=Physical, 1=Virtual, 2=Service)
    function keywordTypeByKey(bytes32 keywordKey) external view returns (uint8);
    /// @notice Get keyword list by language and type
    function getKeywordsByType(string calldata language, uint8 _type) external view returns (string[] memory);
    /// @notice Get all approved keywords for a given language
    function getAllKeywords(string calldata language) external view returns (string[] memory);
    /// @notice Get pending keyword count
    function getPendingCount() external view returns (uint256);
}

// IFiatPaymentRegistry: merged into PlatformSettings

// IGeoRegistry: merged into PlatformSettings

// ============ Shared Enums ============

/**
 * Order status enum
 * Product types: 0=Physical, 1=Virtual, 2=Service
 */
enum OrderStatus {
    None,               // 0 - No order (initial state)
    Confirmed,          // 1 - Paid / pending processing
    Shipped,            // 2 - Shipped (physical)
    Delivered,          // 3 - Delivered (virtual)
    ServiceStarted,     // 4 - Service started
    Completed,          // 5 - Completed (settled)
    Cancelled,          // 6 - Cancelled (refunded)
    RefundRequested,    // 7 - Buyer requested refund
    Arbitrating,        // 8 - Under arbitration
    Resolved            // 9 - Arbitration resolved
}

/// Deposit status enum
enum DepositStatus {
    Active,     // 0 - Deposit active
    Frozen,     // 1 - Frozen during arbitration
    Deducted,   // 2 - After arbitration deduction
    Withdrawn   // 3 - Merchant has withdrawn and exited
}

/// C2C order status enum
enum C2COrderStatus {
    Active,           // 0 - Active and tradeable
    PartiallyFilled,  // 1 - Partially filled
    Filled,           // 2 - Fully filled
    Cancelled         // 3 - Cancelled
}

/// C2C trade status enum
enum C2CTradeStatus {
    Created,          // 0 - Created (awaiting buyer deposit if dual-deposit mode)
    BuyerDeposited,   // 1 - Buyer has paid deposit
    AwaitingPayment,  // 2 - Awaiting buyer fiat payment
    PaymentConfirmed, // 3 - Buyer confirmed fiat payment
    Completed,        // 4 - Trade completed
    Cancelled,        // 5 - Trade cancelled
    Disputed,         // 6 - Under dispute
    Resolved          // 7 - Dispute resolved
}

/// Auction status enum
enum AuctionStatus {
    Created,      // 0 - Created, awaiting start time
    Active,       // 1 - Bidding in progress
    Ended,        // 2 - Ended (has bids), awaiting seller shipment
    Shipped,      // 3 - Shipped, awaiting buyer confirmation
    Completed,    // 4 - Buyer confirmed receipt, settled
    Cancelled,    // 5 - Seller cancelled (no bids)
    Arbitrating,  // 6 - Under arbitration
    Resolved,     // 7 - Arbitration resolved
    Failed        // 8 - No bids at expiry (failed auction)
}

/// Community arbitration case status enum
enum CaseStatus {
    EvidencePhase,   // 0 - Evidence submission phase
    VotingPhase,     // 1 - Arbitrator voting phase
    Resolved,        // 2 - Majority vote resolution complete
    Tied,            // 3 - 0:0 tie, full refund
    AdminResolved    // 4 - Admin intervention ruling
}

/// Business type enum (business type associated with arbitration case)
enum BusinessType {
    Product,   // 0 - B2C product (physical/virtual/service)
    Auction,   // 1 - Auction
    C2C        // 2 - C2C trade
}

// ============ Shared Structs ============

/// Product specification (used by physical and virtual products)
struct Spec {
    string name;       // Spec name (e.g. "Red-Large")
    uint256 price;     // Unit price (USDT, 6 decimals, e.g. 10000000 = 10 USDT)
    uint256 stock;     // Stock quantity (max 99999)
}

/// Shipping info removed (users exchange shipping addresses privately via chat)

/// Physical product order (compact packing, 4 storage slots; dual payment channel: paymentToken in slot3)
struct PhysicalOrder {
    address buyer;              // slot0: 20 bytes
    uint8 specIndex;            // slot0: +1
    OrderStatus orderStatus;    // slot0: +1 (enum fits uint8)
    bool buyerReviewed;         // slot0: +1
    bool sellerReviewed;        // slot0: +1
    bool hadArbitration;        // slot0: +1
    bool settled;               // slot0: +1 = 26 bytes

    uint64 quantity;            // slot1: 8 bytes
    uint64 orderTime;           // slot1: +8
    uint64 shipTime;            // slot1: +8
    uint64 autoReceiveDeadline; // slot1: +8 = 32 bytes

    uint256 orderAmount;        // slot2

    address paymentToken;       // slot3: Payment token used for this order (USDT)
}

/// Virtual product order (compact packing, 4 storage slots; dual payment channel)
struct VirtualOrder {
    address buyer;              // slot0: 20 bytes
    uint8 specIndex;            // slot0: +1
    OrderStatus orderStatus;    // slot0: +1
    bool buyerReviewed;         // slot0: +1
    bool sellerReviewed;        // slot0: +1
    bool hadArbitration;        // slot0: +1
    bool settled;               // slot0: +1 = 26 bytes

    uint64 quantity;            // slot1: 8 bytes
    uint64 orderTime;           // slot1: +8
    uint64 deliveryTime;        // slot1: +8
    uint64 autoReceiveDeadline; // slot1: +8 = 32 bytes

    uint256 orderAmount;        // slot2

    address paymentToken;       // slot3: Payment token used for this order
}

/// Service product order (compact packing, 4 storage slots; dual payment channel)
struct ServiceOrder {
    address buyer;              // slot0: 20 bytes
    uint8 serviceItemIndex;     // slot0: +1
    OrderStatus orderStatus;    // slot0: +1
    bool serviceStarted;        // slot0: +1
    bool buyerReviewed;         // slot0: +1
    bool sellerReviewed;        // slot0: +1
    bool hadArbitration;        // slot0: +1
    bool settled;               // slot0: +1 = 28 bytes

    uint64 orderTime;           // slot1: 8 bytes

    uint256 orderAmount;        // slot2

    address paymentToken;       // slot3: Payment token used for this order
}

/// Want-to-buy product order (buyer posts request, seller accepts and delivers)
struct WantToBuyOrder {
    address seller;             // slot0: Accepting seller
    OrderStatus orderStatus;    // slot0
    bool buyerReviewed;         // slot0
    bool sellerReviewed;        // slot0
    bool hadArbitration;        // slot0
    bool settled;               // slot0
    bool cancelRequested;       // slot0: Whether buyer has requested cancellation

    uint64 orderTime;           // slot1: Acceptance time
    uint64 shipTime;            // slot1: Seller shipment time (0=not shipped)
    uint64 cancelRequestTime;   // slot1: Buyer cancel request time (0=not requested)
    uint64 autoReceiveDeadline; // slot1: Auto-confirm receipt deadline

    uint256 orderAmount;        // slot2: Order amount

    uint256 sellerDeposit;      // slot3: Seller's 10% deposit

    address paymentToken;       // slot4: Payment token
}

/// Service item (used by service products)
struct ServiceItem {
    string name;       // Service item name
    uint256 price;     // Price (USDT, 6 decimals)
    uint256 stock;     // Stock / serviceable count
}

/// Platform contract address collection (used for template contract initialization, avoids stack too deep from too many params)
struct PlatformContracts {
    address usdt;            // USDT token contract address
    address settings;        // Platform settings contract address
    address inviteRegistry;  // Invite registry contract address
    address keywordWeight;   // Keyword weight contract address
}

/// Physical/Virtual product string parameter collection (packs 3 strings to reduce stack depth)
struct ProductStrings {
    string language;     // Product language code (e.g. zh/en/ja)
    string title;        // Product title
    string keyword;      // Product keyword
    string description;  // Product description (backward compatible with old frontend display)
    string metadataURI;  // Product metadata URI (IPFS/Arweave etc.)
}

/// Service product string parameter collection (adds language/metadataURI, supports multi-language grouping and decentralized metadata)
struct ServiceStrings {
    string language;     // Product language code (e.g. zh/en/ja)
    string keyword;      // Service keyword
    string country;      // Country
    string province;     // First-level administrative region (province/state)
    string city;         // Second-level administrative region (city/district)
    string basicInfo;    // Basic information
    string location;     // Location
    string consumption;  // Consumption description
    string introduction; // Detailed introduction
    string metadataURI;  // Service metadata URI (IPFS/Arweave etc.)
}

/// Auction parameter collection (avoids stack too deep)
struct AuctionParams {
    string title;            // Auction title
    string description;      // Product description
    string language;         // Language market isolation
    string[] images;         // Product image URL array (max 9)
    uint256 startPrice;      // Starting price (token smallest precision)
    uint256 buyNowPrice;     // Buy-now price (token smallest precision)
    uint256 minBidIncrement; // Minimum bid increment (token smallest precision)
    uint256 startTime;       // Start time (Unix timestamp)
    uint256 endTime;         // End time (Unix timestamp)
}

/// Community arbitration case initialization parameter collection (avoids stack too deep)
struct CaseInitParams {
    address initiator;          // Initiator address
    address respondent;         // Respondent address
    bool initiatorIsBuyer;      // Whether initiator is buyer (maps buyerWins to actual buyer/seller)
    address businessContract;   // Associated business contract address
    bytes16 orderId;            // On-chain order ID
    BusinessType businessType;  // Business type
    uint256 disputeAmount;      // Dispute amount
    string evidence;            // Initiator text evidence
    string[] evidenceImages;    // Initiator image CID array (max 9)
}

/// Arbitrator vote record (compact packing, 1 storage slot: 20+1+8=29 bytes)
struct VoteRecord {
    address arbitrator;    // 20 bytes - Arbitrator address
    bool votedForBuyer;    // 1 byte - Whether voted for buyer
    uint64 voteTime;       // 8 bytes - Vote time
}

/// C2C sell order creation parameter collection (factory external call parameter packing, avoids stack too deep)
/// @dev paymentToken is required (USDT), validated as non-zero and registered payment channel at creation
struct CreateSellOrderParams {
    string language;             // C2C language market
    string title;                // Order title
    address paymentToken;        // Payment token (required, USDT, zero address reverts)
    uint256 tokenAmount;         // Total token amount to sell (USDT smallest unit)
    uint256 price;               // Fiat unit price (1e6 precision)
    string[] paymentMethods;      // Supported payment method identifier array
    string fiatType;             // Fiat type
    uint256 expireTime;          // Payment window in seconds after buyer places order (field name kept for ABI compatibility)
    uint256 minTradeAmount;      // Minimum trade amount per transaction
    bool requireBuyerDeposit;    // Whether buyer deposit is required
    uint256 buyerDepositRate;    // Buyer deposit rate (basis points)
}


/// C2C buy order creation parameter collection (avoids stack too deep)
struct CreateBuyOrderParams {
    string language;
    string title;
    address paymentToken;
    uint256 tokenAmount;
    uint256 price;
    string[] paymentMethods;
    string fiatType;
    uint256 expireTime;
    uint256 minTradeAmount;
}

/// C2C sell order initialization parameter collection (avoids stack too deep)
struct SellOrderInitParams {
    address seller;              // Seller address
    string language;             // C2C language market
    string title;                // Order title
    address paymentToken;        // Payment token (USDT)
    uint256 tokenAmount;         // Total token amount to sell
    uint256 price;               // Fiat unit price (1e6 precision)
    string[] paymentMethods;      // Supported payment method identifier array
    string fiatType;             // Fiat type
    uint256 expireTime;          // Payment window in seconds after buyer places order (field name kept for ABI compatibility)
    uint256 minTradeAmount;      // Minimum trade amount per transaction
    bool requireBuyerDeposit;    // Whether buyer deposit is required
    uint256 buyerDepositRate;    // Buyer deposit rate (basis points)
    address factory;             // Factory contract address
    address cooldownManager;     // Cooldown manager contract address
}

/// C2C buy order initialization parameter collection (avoids stack too deep)
struct BuyOrderInitParams {
    address buyer;               // Buyer address
    string language;             // C2C language market
    string title;                // Order title
    address paymentToken;        // Payment token (USDT)
    uint256 tokenAmount;         // Total token amount to buy
    uint256 price;               // Fiat unit price (1e6 precision)
    string[] paymentMethods;      // Supported payment method identifier array
    string fiatType;             // Fiat type
    uint256 expireTime;          // Expiration timestamp
    uint256 minTradeAmount;      // Minimum trade amount per transaction
    address factory;             // Factory contract address
}

/// C2C trade initialization parameter collection (avoids stack too deep)
/// @dev Dual payment channel: paymentToken is forced to use the order's token; counterparty cannot switch tokens
struct TradeInitParams {
    address buyer;               // Buyer address
    address seller;              // Seller address
    address sellOrder;           // Associated sell order contract address (address(0) for buy-order trades)
    address buyOrder;            // Associated buy order contract address (address(0) for sell-order trades)
    address paymentToken;        // Payment token
    uint256 tokenAmount;         // Trade amount (USDT smallest unit)
    uint256 price;               // Fiat unit price
    bool requireBuyerDeposit;    // Whether buyer deposit is required
    uint256 buyerDepositRate;    // Buyer deposit rate (basis points)
    uint256 paymentDeadline;     // Payment deadline
    address settings;            // Platform settings contract address
    address cooldownManager;     // Cooldown manager contract address
    address inviteRegistry;      // Invite registry contract address (fee distribution)
}

// ============ Shared Custom Errors (replaces require strings, saves Gas) ============

// --- Permission errors ---
/// @dev Contract addresses cannot call directly (prevents contract wallet attacks)
// Audit note [H-02]: noContract (msg.sender != tx.origin) is intentional, prevents flash loan attacks and malicious contract callbacks.
// Currently does not support ERC-4337 / Gnosis Safe smart contract wallet users; this is a security vs compatibility tradeoff.
// Future: whitelist mechanism or removal of this restriction can enable smart wallet support.
error NoContractCalls();
/// @dev Caller is not the contract owner
error NotOwner();
/// @dev Caller is not an admin
error NotAdmin();
/// @dev Caller is not admin or customer service
error NotAdminOrCS();
/// @dev Caller is not the seller
error NotSeller();
/// @dev Caller is not the buyer
error NotBuyer();
/// @dev Caller is not the factory contract
error NotFactory();
/// @dev Caller is not a factory-created product contract
error NotFactoryProduct();
/// @dev Caller is not authorized
error NotAuthorized();
/// @dev Caller is not an authorized trade contract
error NotAuthorizedTrade();
/// @dev Caller is not one of the trade parties
error NotParty();
/// @dev Caller is not the merchant (deposit contract owner)
error NotMerchant();
/// @dev Caller is not an authorized product contract (for deposit deduction)
error NotAuthorizedProduct();
/// @dev Address is blacklisted
error IsBlacklisted();
/// @dev Invalid product type
error InvalidProductType();

// --- Status errors ---
/// @dev Current status does not allow this operation
error WrongStatus();
/// @dev Contract already initialized, cannot re-initialize
error AlreadyInit();
/// @dev Data already migrated
error AlreadyMigrated();
/// @dev Keyword/fiat already approved
error AlreadyApproved();
/// @dev Product already delisted
error AlreadyDelisted();
/// @dev Order already settled
error AlreadySettled();
/// @dev Reentrancy guard triggered
error ReentrancyGuard();
/// @dev Invite relationship already registered
error AlreadyRegistered();
/// @dev Keyword already in pending review queue
error AlreadyPending();
/// @dev Value already set (prevents duplicate setting)
error AlreadySet();
/// @dev Merchant already has a deposit contract
error AlreadyHasDeposit();
/// @dev Escrow already exists for this (productId, partyB) pair
error AlreadyExists();
/// @dev Product is delisted, cannot operate
error IsDelisted();
/// @dev Active orders exist, cannot delist/redeem
error ActiveOrder();
/// @dev Order ID does not exist
error OrderNotFound();
/// @dev Operation not yet completed
error NotDone();
/// @dev Operation already completed, cannot repeat
error IsDone();
/// @dev Order is not in arbitration status
error NotArbitrating();
/// @dev Keyword/fiat not approved
error NotApproved();
/// @dev Order/auction not expired
error NotExpired();
/// @dev Order/auction not in active status
error NotActive();
/// @dev Deposit not in frozen status
error NotFrozen();
/// @dev Keyword not in pending review status
error NotPending();
/// @dev Trade not in dispute status
error NotDisputed();
/// @dev Auction not ended
error NotEnded();

// --- Parameter/amount errors ---
/// @dev Zero address provided
error ZeroAddress();
/// @dev Zero amount provided
error ZeroAmount();
/// @dev Invalid price parameter (zero or exceeds limit)
error InvalidPrice();
/// @dev Invalid arbitration winner (neither buyer nor seller)
error InvalidWinner();
/// @dev Invalid archive generation number
error InvalidGeneration();
/// @dev Spec index out of bounds
error InvalidSpec();
/// @dev Service item index out of bounds
error InvalidItem();
/// @dev Invalid purchase quantity (zero or exceeds stock)
error InvalidQty();
/// @dev Insufficient stock
error OutOfStock();
/// @dev Invalid inviter address
error InvalidInviter();
/// @dev Invalid sell order address (not factory-created)
error InvalidSellOrder();
/// @dev Invalid buy order address (not factory-created)
error InvalidBuyOrder();
/// @dev Invalid status parameter
error InvalidStatus();
/// @dev Invalid type parameter
error InvalidType();
/// @dev Parameter mismatch (array length, etc.)
error Mismatch();
/// @dev Insufficient balance/allowance
error Insufficient();
/// @dev Insufficient deposit balance for deduction
error InsufficientDeposit();
/// @dev Contract has no balance to operate on
error NoBalance();
/// @dev Compensation amount exceeds order amount
error CompensationExceedsOrder();
/// @dev Keyword is empty string
error EmptyKeyword();
/// @dev String parameter is empty
error EmptyString();
/// @dev Keyword exceeds maximum length
error InvalidLanguage();
error KeywordTooLong();
/// @dev Fee rate exceeds 20% cap
error RateExceeds20Pct();
/// @dev Three-level share ratios must sum to 10000
error MustSumTo10000();
/// @dev Parameter value too high
error TooHigh();
/// @dev Deadline too soon
error DeadlineTooSoon();
/// @dev Time parameter must be in the future
error MustBeFuture();
/// @dev End time must be later than start time
error MustBeLater();

// --- Business errors ---
/// @dev USDT transfer failed
error TransferFailed();
/// @dev User has locked trades, cannot withdraw deposit
error HasLockedTrades();
/// @dev Cooldown period not met, cannot operate
error CooldownActive();
/// @dev Update operation in cooldown (prevents frequent calls)
error UpdateCooldown();
/// @dev Merchant has no deposit contract
error NoMerchantDeposit();
/// @dev Deposit contract does not exist
error NoDepositContract();
/// @dev No deposit balance
error NoDeposit();
/// @dev This trade does not require buyer deposit
error NoDepositRequired();
/// @dev Buyer deposit rate: >10000 invalid; if requireBuyerDeposit must be 1-10000 bps, otherwise must be 0
error InvalidDepositRate();
/// @dev (Historical) C2C sell orders once required buyer deposit; now optional, this error may no longer be thrown by factory
error DepositRequired();
/// @dev Keyword not approved
error KeywordNotApproved();
/// @dev Not a factory escrow
error NotFactoryEscrow();
/// @dev Not the seller or admin
error NotSellerOrAdmin();
/// @dev Country not approved
error CountryNotApproved();
/// @dev Province not approved
error ProvinceNotApproved();
/// @dev City not approved
error CityNotApproved();
/// @dev Trade created over 24h ago, cannot cancel
error LockedAfter24h();
/// @dev Image count exceeds limit (9 images)
error TooManyImages();
/// @dev Product count exceeds limit
error TooManyProducts();
/// @dev Locked amount exceeds deposit balance
error OverLocked();
/// @dev No pending request
error NoRequest();
/// @dev No refund request
error NoRefundRequest();
/// @dev Current status does not allow deposit payment
error CannotDeposit();
/// @dev Cannot buy own product
error CannotBuyOwn();
/// @dev Cannot trade with self
error CannotTradeWithSelf();
/// @dev Cannot invite self
error CannotInviteSelf();
/// @dev Invite relationship forms a loop
error CircularInvite();
/// @dev Deposit exceeds maximum limit (1M USDT)
error ExceedsMaxDeposit();
/// @dev Minimum deposit is 500 USDT
error MinDeposit500();
/// @dev Minimum bid is 1 USDT
error MinBid1USDT();
/// @dev Amount below minimum trade amount
error BelowMin();
/// @dev Merchant active product count reached limit (20)
error MaxActiveProducts();
/// @dev Merchant has no active products
error NoActiveProduct();
/// @dev User has no active trades
error NoActiveTrade();
/// @dev Buy order has active (locked) transactions in flight
error HasActiveTransactions();
/// @dev No expired orders for auto-receive
error NoExpiredOrders();
/// @dev Array length mismatch
error LengthMismatch();
/// @dev No products delisted (during batch delist)
error NoProductsDelisted();
/// @dev No funds to claim
error NothingToClaim();
/// @dev No tokens to rescue
error NothingToRescue();
/// @dev Only the product contract itself can revoke authorization
error OnlyProductCanRevoke();
/// @dev Order has expired
error OrderExpired();
/// @dev Sell order has expired
error SellOrderExpired();
/// @dev Product factory address not set
error ProductFactoryNotSet();
/// @dev Merchant still has active products or cooldown not met
error ProductsActiveOrCooldown();
/// @dev Merchant activity does not meet zombie recycle conditions
error NotInactiveEnough();
/// @dev Service already started, cannot cancel
error ServiceStarted();
/// @dev Operation too early
error TooEarly();
/// @dev Payment deadline exceeded
error PaymentDeadlineExceeded();
/// @dev Not a factory-created buy order
error NotFactoryBuyOrder();
/// @dev Not a factory-created sell order
error NotFactorySellOrder();
/// @dev Not a factory-created trade
error NotFactoryTrade();

// --- Auction errors ---
/// @dev Auction not in active bidding status
error AuctionNotActive();
/// @dev Auction not ended
error AuctionNotEnded();
/// @dev Auction not shipped
error AuctionNotShipped();
/// @dev Auction not in arbitration status
error AuctionNotArbitrating();
/// @dev Auction has bids, cannot cancel
error AuctionHasBids();
/// @dev Seller has active auctions, cannot redeem deposit
error HasActiveAuctions();
/// @dev Bid lower than current highest + minimum increment
error BidTooLow();
/// @dev [M-06] Bid >= buy-now price, should use buyNow()
error UseBuyNow();
/// @dev Auction duration exceeds maximum
error AuctionDurationTooLong();
/// @dev Start time must be in the future
error StartTimeMustBeFuture();
/// @dev End time must be later than start time
error EndTimeBeforeStart();
/// @dev Caller is not the auction factory
error NotAuctionFactory();
/// @dev Caller is not the highest bidder
error NotHighestBidder();

// --- Community arbitration errors ---
/// @dev Not a qualified arbitrator
error NotQualifiedArbitrator();
/// @dev Evidence submission window closed
error EvidenceWindowClosed();
/// @dev Not in voting phase
error VotingNotActive();
/// @dev Already voted on this case
error AlreadyVoted();
/// @dev Cannot arbitrate own case
error CannotArbitrateOwnCase();
/// @dev Arbitration window (test: 30 minutes; production: 7 days) expired
error ArbitrationWindowExpired();
/// @dev Active case already exists for this order
error CaseAlreadyExists();
/// @dev Case not found
error NoCaseFound();
/// @dev Global vote interval not met
error VoteIntervalNotMet();
/// @dev Case arbitrator limit reached
error MaxArbitratorsReached();
/// @dev Caller is not the respondent
error NotRespondent();
/// @dev Case not yet resolved
error CaseNotResolved();
/// @dev Rewards already distributed
error RewardsAlreadyDistributed();
/// @dev Not a factory-created case contract
error NotFactoryCase();

// --- Whitelist application errors ---
/// @dev Duplicate whitelist application
error DuplicateApplication();
/// @dev Application already processed
error AlreadyProcessed();

// --- Payment channel errors ---
/// @dev Token is not a platform-registered payment channel (USDT)
error TokenNotAccepted();
/// @dev Token does not match order/case paymentToken
error TokenMismatch();
/// @dev paymentToken required field is zero address
error PaymentTokenRequired();
/// @dev New splitter payees do not match locked payees (H-2 protection)
error PayeesMismatch();

// ============ Shared Events (splitter fallback monitoring) ============
/// @dev Emitted when splitter path fails and platform fee falls back to single-recipient EOA (M-1 monitoring)
event SplitterFallback(address indexed token, uint256 amount, address indexed fallbackRecipient);

// ============ IShuifangEscrow Shuifang Escrow Template Interface ============
interface IShuifangEscrow {
    function initialize(address _partyA, address _partyB, bytes32 _withdrawHashA, bytes32 _withdrawHashB, address _usdt, address _settings) external;
    function deposit(uint256 amount) external;
    function requestWithdraw(bytes32 _secret) external;
    function payFee(uint256 amount) external;
    function adminTransfer(address from, address to, uint256 amount) external;
    function adminReleaseSingle(address party) external;
    function adminReleaseAll() external;
    function getInfo() external view returns (
        address _partyA, address _partyB,
        uint256 depositA, uint256 depositB,
        uint256 _totalDeposits, uint256 _firstDepositTime,
        bool withdrawRequestedA, bool withdrawRequestedB,
        bool _bothWithdrawn,
        uint256 _feePaid
    );
    function partyA() external view returns (address);
    function partyB() external view returns (address);
    function deposits(address) external view returns (uint256);
    function totalDeposits() external view returns (uint256);
    function withdrawRequested(address) external view returns (bool);
    function bothWithdrawn() external view returns (bool);
    function firstDepositTime() external view returns (uint256);
    function feePaid() external view returns (uint256);
    function withdrawHashA() external view returns (bytes32);
    function withdrawHashB() external view returns (bytes32);
}

// ============ IShuifangFactory Shuifang Factory Interface ============
interface IShuifangFactory {
    function createProduct(string calldata keyword, string calldata language, uint8 productType, string calldata metadataURI) external returns (uint256);
    function createEscrow(uint256 productId, address partyB, bytes32 withdrawHashA, bytes32 withdrawHashB) external returns (address);
    function isFactoryEscrow(address) external view returns (bool);
    function getProductCount() external view returns (uint256);
    function getProduct(uint256 productId) external view returns (address seller, uint8 productType, bool isDelisted, string memory keyword, string memory language, string memory metadataURI);
    function getProductsByKeyword(string calldata language, string calldata keyword) external view returns (uint256[] memory);
    function getProductsByLanguage(string calldata language) external view returns (uint256[] memory);
    function getProductsBySeller(address seller) external view returns (uint256[] memory);
    function getEscrowCount() external view returns (uint256);
    function getEscrow(uint256 index) external view returns (address);
    function getProductEscrows(uint256 productId) external view returns (address[] memory);
    function escrowProductId(address) external view returns (uint256);
    function delistProduct(uint256 productId) external;
    function keywordSeed(bytes32 key) external view returns (uint256);
}

// ============ IShuifangKeywords Shuifang Keyword Management Interface ============
interface IShuifangKeywords {
    function isApproved(string calldata language, string calldata keyword) external view returns (bool);
    function getKeywordKey(string memory language, string memory keyword) external pure returns (bytes32);
    function addApprovedKeyword(string calldata language, string calldata keyword) external;
    function removeKeyword(string calldata language, string calldata keyword) external;
    function getAllKeywords(string calldata language) external view returns (string[] memory);
    function getKeywordCount(string calldata language) external view returns (uint256);
}

// ============ Safe Transfer Events (declared internally in each contract) ============

