// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * C2CFactory - C2C Factory Contract
 *
 * Deploys C2C sell/buy/trade contracts via EIP-1167 clone, manages order index.
 * Each order's paymentToken is required (USDT);
 * when creating a trade, the sell order's paymentToken is enforced.
 * Query functions have been split into C2CFactoryReader.
 */

import "./interfaces/Interfaces.sol";
import "./C2CSellOrderTemplate.sol";
import "./C2CBuyOrderTemplate.sol";
import "./C2CTradeTemplate.sol";
import "./ArchiveStore.sol";

/// @title C2CFactory - C2C Order Deployment Factory (Dual Payment Channel)
contract C2CFactory {


    error InvalidAmount();
    error BuyOrderArbitrationActive();

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // ===== Payment channel (USDT only) =====

    address public owner;
    address public sellOrderTemplate;
    address public buyOrderTemplate;
    address public tradeTemplate;
    address public settingsAddr;
    address public usdtAddr;
    address public cooldownManagerAddr;
    address public inviteRegistryAddr;
    address public archiveTemplate;
    address public depositFactoryAddr;

    address[] public activeSellOrders;
    address[] public activeBuyOrders;
    mapping(address => string) public orderLanguage;
    mapping(address => uint256) public sellOrderIndex;
    mapping(address => uint256) public buyOrderIndex;

    /// Language market isolation: index orders by language
    mapping(string => address[]) public sellOrdersByLanguage;
    mapping(string => address[]) public buyOrdersByLanguage;
    mapping(address => uint256) public sellOrderLanguageIndex;
    mapping(address => uint256) public buyOrderLanguageIndex;

    /// Dual payment channel: index orders by payment token (used for frontend 4-tab filtering)
    mapping(address => address[]) public paymentTokenToOrders;
    mapping(address => uint256) public paymentTokenOrderIndex;
    mapping(address => address) public orderPaymentToken;

    ArchiveStore[] public tradeArchives;
    ArchiveStore public currentTradeArchive;
    uint256 public totalTradeCount;

    mapping(address => bool) public isFactorySellOrder;
    mapping(address => bool) public isFactoryBuyOrder;
    mapping(address => address[]) public sellerSellOrders;
    mapping(address => address[]) public buyerBuyOrders;
    mapping(address => uint256) public activeC2COrderCount;

    /// Number of in-progress buy-order arbitrations a buyer is currently a respondent in. While > 0,
    /// the buyer cannot create new buy orders. Incremented when a seller raises a post-completion
    /// community dispute on the buyer's buy-order trade (which also freezes their active buy orders),
    /// decremented when that dispute resolves.
    mapping(address => uint256) public buyerBuyOrderArbCount;

    address[] public disputedTrades;
    mapping(address => uint256) public disputedTradeIndex;
    mapping(address => bool) public isDisputedTrade;
    mapping(address => bool) public isFactoryTrade;

    // === C2C-specific cumulative accumulators (strictly separated by token; independent from the 7 shared mapping groups in PlatformSettings for product orders) ===
    /// (seller, token) => cumulative completed trade amount
    mapping(address => mapping(address => uint256)) public sellerC2CCompletedAmount;
    mapping(address => mapping(address => uint256)) public sellerC2CCompletedCount;
    mapping(address => mapping(address => uint256)) public sellerC2CDisputeAmount;
    mapping(address => mapping(address => uint256)) public sellerC2CDisputeCount;
    /// (buyer, token) => cumulative purchase amount
    mapping(address => mapping(address => uint256)) public buyerC2CCompletedAmount;
    mapping(address => mapping(address => uint256)) public buyerC2CCompletedCount;
    mapping(address => mapping(address => uint256)) public buyerC2CDisputeAmount;
    mapping(address => mapping(address => uint256)) public buyerC2CDisputeCount;

    uint256 public constant MIN_PAYMENT_WINDOW = 15 minutes;
    uint256 public constant MAX_PAYMENT_WINDOW = 90 days;

    // C2C order limits (shared with Product/Auction)
    uint256 public constant MAX_ORDERS_WITHOUT_DEPOSIT = 5;
    uint256 public constant MAX_ORDERS_WITH_DEPOSIT = 20;
    uint256 public constant MAX_ORDERS_PER_LANGUAGE = 10000;  // Maximum orders per language
    uint256 public constant MAX_TOTAL_ORDERS = 100000;        // Global maximum orders

    event SellOrderCreated(address indexed seller, address orderContract, address indexed paymentToken, string language);
    event BuyOrderCreated(address indexed buyer, address orderContract, address indexed paymentToken, string language);
    event TradeCreated(address indexed buyer, address indexed seller, address tradeContract, address paymentToken);
    event DisputeCreated(address indexed trade);
    event C2CTradeRecorded(address indexed seller, address indexed buyer, address indexed token, uint256 amount, bool hadDispute);
    event BuyerBuyOrdersFrozen(address indexed buyer, uint256 count);
    event BuyOrderArbitrationEnded(address indexed buyer);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address _sellTpl, address _buyTpl, address _tradeTpl,
        address _settings, address _cooldownManager, address _inviteRegistry,
        address _usdt, address _archiveTemplate
    ) {
        if (
            _sellTpl == address(0) || _buyTpl == address(0) || _tradeTpl == address(0) ||
            _settings == address(0) || _cooldownManager == address(0) ||
            _inviteRegistry == address(0) || _archiveTemplate == address(0)
        ) revert ZeroAddress();
        if (_usdt == address(0)) revert ZeroAddress();
        owner = msg.sender;
        sellOrderTemplate = _sellTpl;
        buyOrderTemplate = _buyTpl;
        tradeTemplate = _tradeTpl;
        settingsAddr = _settings;
        usdtAddr = _usdt;
        cooldownManagerAddr = _cooldownManager;
        inviteRegistryAddr = _inviteRegistry;
        archiveTemplate = _archiveTemplate;
        depositFactoryAddr = IPlatformSettings(_settings).getDepositFactory();
        currentTradeArchive = ArchiveStore(_cloneArchive(_archiveTemplate));
        tradeArchives.push(currentTradeArchive);
    }

    function setSellOrderTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); sellOrderTemplate = _tpl; }
    function setBuyOrderTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); buyOrderTemplate = _tpl; }
    function setTradeTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); tradeTemplate = _tpl; }
    function setDepositFactory(address _depositFactory) external onlyOwner { if (_depositFactory == address(0)) revert ZeroAddress(); depositFactoryAddr = _depositFactory; }
    function setCooldownManager(address _cooldownManager) external onlyOwner { if (_cooldownManager == address(0)) revert ZeroAddress(); cooldownManagerAddr = _cooldownManager; }
    function setArchiveTemplate(address _archiveTemplate) external onlyOwner { if (_archiveTemplate == address(0)) revert ZeroAddress(); archiveTemplate = _archiveTemplate; }
    function setSettings(address _settings) external onlyOwner { if (_settings == address(0)) revert ZeroAddress(); settingsAddr = _settings; }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    function _cloneArchive(address impl) internal returns (address instance) {
        instance = _clone(impl);
        ArchiveStore(instance).initialize(address(this));
    }

    /// @dev Validate paymentToken is USDT (zero address reverts)
    function _validatePaymentToken(address token) internal view {
        if (token == address(0)) revert PaymentTokenRequired();
        if (token != usdtAddr) revert TokenNotAccepted();
    }

    function _validatePaymentMethods(string[] calldata methods, string calldata language) internal view {
        if (methods.length == 0) revert EmptyString();
        IPlatformSettings _s = IPlatformSettings(settingsAddr);
        for (uint256 i = 0; i < methods.length; ) {
            if (!_s.isPaymentMethodApproved(language, methods[i])) revert NotApproved();
            unchecked { ++i; }
        }
    }

    /// @notice Create C2C sell order (dual payment channel: paymentToken required)
    /// @param _params Sell order parameters (includes paymentToken field)
    function createSellOrder(CreateSellOrderParams calldata _params) external noContract returns (address) {
        address _settings = settingsAddr;
        if (IPlatformSettings(_settings).isBlacklisted(msg.sender)) revert IsBlacklisted();

        // Check shared order limit (C2C orders count toward product limit)
        uint256 maxAllowed = _getMaxOrdersForMerchant(msg.sender);
        uint256 totalActiveOrders = _getTotalActiveOrdersForMerchant(msg.sender);
        if (totalActiveOrders >= maxAllowed) revert MaxActiveProducts();

        // Check language market limit (10,000 orders per language)
        if (sellOrdersByLanguage[_params.language].length + buyOrdersByLanguage[_params.language].length >= MAX_ORDERS_PER_LANGUAGE) revert TooHigh();

        // Check global order limit (100,000 total orders)
        if (activeSellOrders.length + activeBuyOrders.length >= MAX_TOTAL_ORDERS) revert TooHigh();

        if (_params.buyerDepositRate > 10000) revert InvalidDepositRate();
        if (_params.requireBuyerDeposit && _params.buyerDepositRate == 0) revert InvalidDepositRate();
        if (_params.tokenAmount == 0) revert ZeroAmount();
        if (_params.price == 0) revert InvalidPrice();
        if (_params.expireTime < MIN_PAYMENT_WINDOW) revert DeadlineTooSoon();
        if (_params.expireTime > MAX_PAYMENT_WINDOW) revert TooHigh();
        if (_params.minTradeAmount == 0 || _params.minTradeAmount > _params.tokenAmount) revert InvalidAmount();
        _validatePaymentToken(_params.paymentToken);
        if (!IPlatformSettings(_settings).isFiatTypeApproved(_params.language, _params.fiatType)) revert NotApproved();
        _validatePaymentMethods(_params.paymentMethods, _params.language);
        address clone = _clone(sellOrderTemplate);
        C2CSellOrderTemplate(clone).initialize(SellOrderInitParams({
            seller: msg.sender,
            language: _params.language,
            title: _params.title,
            paymentToken: _params.paymentToken,
            tokenAmount: _params.tokenAmount,
            price: _params.price,
            paymentMethods: _params.paymentMethods,
            fiatType: _params.fiatType,
            expireTime: _params.expireTime,
            minTradeAmount: _params.minTradeAmount,
            requireBuyerDeposit: _params.requireBuyerDeposit,
            buyerDepositRate: _params.buyerDepositRate,
            factory: address(this),
            cooldownManager: cooldownManagerAddr
        }));
        // Seller locks tokens: use the order's paymentToken
        if (!IERC20(_params.paymentToken).transferFrom(msg.sender, clone, _params.tokenAmount)) revert TransferFailed();
        _registerSellOrder(clone, _params.language, _params.paymentToken);
        _refreshDeposit(msg.sender);
        emit SellOrderCreated(msg.sender, clone, _params.paymentToken, _params.language);
        return clone;
    }

    function _registerSellOrder(address clone, string calldata _language, address _paymentToken) internal {
        sellOrderIndex[clone] = activeSellOrders.length;
        activeSellOrders.push(clone);
        isFactorySellOrder[clone] = true;
        sellerSellOrders[msg.sender].push(clone);
        activeC2COrderCount[msg.sender]++;
        orderLanguage[clone] = _language;
        orderPaymentToken[clone] = _paymentToken;
        paymentTokenOrderIndex[clone] = paymentTokenToOrders[_paymentToken].length;
        paymentTokenToOrders[_paymentToken].push(clone);

        // Language market isolation: add to language-specific index
        sellOrderLanguageIndex[clone] = sellOrdersByLanguage[_language].length;
        sellOrdersByLanguage[_language].push(clone);
    }

    /// @notice Create C2C buy order (dual payment channel: paymentToken required)
    function createBuyOrder(CreateBuyOrderParams calldata _params) external noContract returns (address) {
        address _settings = settingsAddr;
        if (IPlatformSettings(_settings).isBlacklisted(msg.sender)) revert IsBlacklisted();
        if (buyerBuyOrderArbCount[msg.sender] > 0) revert BuyOrderArbitrationActive();

        // Check shared order limit (C2C orders count toward product limit)
        uint256 maxAllowed = _getMaxOrdersForMerchant(msg.sender);
        uint256 totalActiveOrders = _getTotalActiveOrdersForMerchant(msg.sender);
        if (totalActiveOrders >= maxAllowed) revert MaxActiveProducts();

        // Check language market limit (10,000 orders per language)
        if (sellOrdersByLanguage[_params.language].length + buyOrdersByLanguage[_params.language].length >= MAX_ORDERS_PER_LANGUAGE) revert TooHigh();

        // Check global order limit (100,000 total orders)
        if (activeSellOrders.length + activeBuyOrders.length >= MAX_TOTAL_ORDERS) revert TooHigh();

        if (_params.tokenAmount == 0) revert ZeroAmount();
        if (_params.price == 0) revert InvalidPrice();
        if (_params.expireTime < MIN_PAYMENT_WINDOW) revert DeadlineTooSoon();
        if (_params.expireTime > MAX_PAYMENT_WINDOW) revert TooHigh();
        if (_params.minTradeAmount == 0 || _params.minTradeAmount > _params.tokenAmount) revert InvalidAmount();
        _validatePaymentToken(_params.paymentToken);
        if (!IPlatformSettings(_settings).isFiatTypeApproved(_params.language, _params.fiatType)) revert NotApproved();
        _validatePaymentMethods(_params.paymentMethods, _params.language);
        address clone = _clone(buyOrderTemplate);
        C2CBuyOrderTemplate(clone).initialize(BuyOrderInitParams({
            buyer: msg.sender,
            language: _params.language,
            title: _params.title,
            paymentToken: _params.paymentToken,
            tokenAmount: _params.tokenAmount,
            price: _params.price,
            paymentMethods: _params.paymentMethods,
            fiatType: _params.fiatType,
            expireTime: _params.expireTime,
            minTradeAmount: _params.minTradeAmount,
            factory: address(this)
        }));
        buyOrderIndex[clone] = activeBuyOrders.length;
        activeBuyOrders.push(clone);
        isFactoryBuyOrder[clone] = true;
        buyerBuyOrders[msg.sender].push(clone);
        activeC2COrderCount[msg.sender]++;
        orderLanguage[clone] = _params.language;
        orderPaymentToken[clone] = _params.paymentToken;
        paymentTokenOrderIndex[clone] = paymentTokenToOrders[_params.paymentToken].length;
        paymentTokenToOrders[_params.paymentToken].push(clone);

        // Language market isolation: add to language-specific index
        buyOrderLanguageIndex[clone] = buyOrdersByLanguage[_params.language].length;
        buyOrdersByLanguage[_params.language].push(clone);

        address df = IPlatformSettings(_settings).getDepositFactory();
        if (df == address(0)) revert NoDepositContract();
        address depositContract = IDepositFactory(df).getDeposit(msg.sender);
        C2CBuyOrderTemplate(clone).lockBuyerDeposit(depositContract);
        _refreshDeposit(msg.sender);
        emit BuyOrderCreated(msg.sender, clone, _params.paymentToken, _params.language);
        return clone;
    }

    /// @notice Buyer creates a C2C trade. The payment deadline is derived from the seller-configured payment window.
    /// @dev The third parameter is kept for ABI compatibility and ignored.
    function createTrade(
        address _sellOrder, uint256 _amount, uint256
    ) external noContract returns (address) {
        // [C-09 fix]: Reject zero-amount trades at factory level
        if (_amount == 0) revert ZeroAmount();
        if (!isFactorySellOrder[_sellOrder]) revert InvalidSellOrder();
        address _settings = settingsAddr;
        if (IPlatformSettings(_settings).isBlacklisted(msg.sender)) revert IsBlacklisted();
        C2CSellOrderTemplate sellOrder = C2CSellOrderTemplate(_sellOrder);
        uint256 paymentWindow = sellOrder.expireTime();
        if (paymentWindow < MIN_PAYMENT_WINDOW) revert DeadlineTooSoon();
        if (paymentWindow > MAX_PAYMENT_WINDOW) revert TooHigh();
        uint256 paymentDeadline = block.timestamp + paymentWindow;

        address orderSeller = sellOrder.seller();
        if (msg.sender == orderSeller) revert CannotTradeWithSelf();
        (, bool reqDeposit, uint256 depositRate,) = sellOrder.getOrderConfig();
        address tradeToken = sellOrder.paymentToken();

        sellOrder.lockAmount(_amount);
        address clone = _clone(tradeTemplate);
        sellOrder.authorizeTrade(clone);
        address _cm = cooldownManagerAddr;
        ICooldownManager(_cm).authorizeTrade(clone);

        C2CTradeTemplate(clone).initialize(TradeInitParams({
            buyer: msg.sender,
            seller: orderSeller,
            sellOrder: _sellOrder,
            buyOrder: address(0),
            paymentToken: tradeToken,
            tokenAmount: _amount,
            price: sellOrder.price(),
            requireBuyerDeposit: reqDeposit,
            buyerDepositRate: depositRate,
            paymentDeadline: paymentDeadline,
            settings: _settings,
            cooldownManager: _cm,
            inviteRegistry: inviteRegistryAddr
        }));

        if (reqDeposit) {
            uint256 depositAmt = _amount * depositRate / 10000;
            ICooldownManager(_cm).receiveDeposit(msg.sender, depositAmt, tradeToken);
            C2CTradeTemplate(clone).factorySetDepositPaid();
        }

        ICooldownManager(_cm).tradeStarted(msg.sender);
        ICooldownManager(_cm).tradeStarted(orderSeller);
        _refreshDeposit(msg.sender);
        _refreshDeposit(orderSeller);
        _registerTrade(clone, orderSeller);

        emit TradeCreated(msg.sender, orderSeller, clone, tradeToken);
        return clone;
    }

    function acceptBuyOrder(address _buyOrder, uint256 _amount) external noContract returns (address) {
        // [C-09 fix]: Reject zero-amount trades at factory level
        if (_amount == 0) revert ZeroAmount();
        if (!isFactoryBuyOrder[_buyOrder]) revert InvalidBuyOrder();
        address _settings = settingsAddr;
        if (IPlatformSettings(_settings).isBlacklisted(msg.sender)) revert IsBlacklisted();
        C2CBuyOrderTemplate buyOrder = C2CBuyOrderTemplate(_buyOrder);
        address orderBuyer = buyOrder.buyer();
        if (msg.sender == orderBuyer) revert CannotTradeWithSelf();
        uint256 paymentWindow = buyOrder.expireTime();
        if (paymentWindow < MIN_PAYMENT_WINDOW) revert DeadlineTooSoon();
        if (paymentWindow > MAX_PAYMENT_WINDOW) revert TooHigh();
        uint256 paymentDeadline = block.timestamp + paymentWindow;
        address tradeToken = buyOrder.paymentToken();
        uint256 available = buyOrder.getAvailable();
        if (_amount > available) revert Insufficient();
        if (_amount < buyOrder.minTradeAmount()) revert BelowMin();
        // Reserve the amount immediately so concurrent/in-flight accepts cannot over-commit
        // beyond the order's remaining capacity (mirrors sell-order lockAmount).
        buyOrder.lockAmount(_amount);
        address clone = _clone(tradeTemplate);
        if (!IERC20(tradeToken).transferFrom(msg.sender, clone, _amount)) revert TransferFailed();
        address _cm = cooldownManagerAddr;
        ICooldownManager(_cm).authorizeTrade(clone);
        C2CTradeTemplate(clone).initialize(TradeInitParams({
            buyer: orderBuyer,
            seller: msg.sender,
            sellOrder: address(0),
            buyOrder: _buyOrder,
            paymentToken: tradeToken,
            tokenAmount: _amount,
            price: buyOrder.price(),
            requireBuyerDeposit: false,
            buyerDepositRate: 0,
            paymentDeadline: paymentDeadline,
            settings: _settings,
            cooldownManager: _cm,
            inviteRegistry: inviteRegistryAddr
        }));
        ICooldownManager(_cm).tradeStarted(orderBuyer);
        ICooldownManager(_cm).tradeStarted(msg.sender);
        _refreshDeposit(msg.sender);
        _refreshDeposit(orderBuyer);
        _registerTrade(clone, orderBuyer);
        emit TradeCreated(orderBuyer, msg.sender, clone, tradeToken);
        return clone;
    }

    function buyOrderTradeFilled(address _buyOrder, uint256 _amount) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        if (!isFactoryBuyOrder[_buyOrder]) revert NotFactoryBuyOrder();
        C2CBuyOrderTemplate(_buyOrder).updateFilled(_amount);
    }

    /// @notice Release a buy order's locked amount when a buy-order trade is cancelled/timed out.
    /// @dev Only a factory-created trade may call (forwarded). Mirrors sell-order unlockAmount on cancel.
    function buyOrderTradeUnlock(address _buyOrder, uint256 _amount) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        if (!isFactoryBuyOrder[_buyOrder]) revert NotFactoryBuyOrder();
        C2CBuyOrderTemplate(_buyOrder).unlockAmount(_amount);
    }

    function _registerTrade(address clone, address orderSeller) internal {
        currentTradeArchive.pushUser(msg.sender, clone);
        currentTradeArchive.pushUser(orderSeller, clone);
        bool isFull = currentTradeArchive.pushGlobal(clone);
        if (isFull) {
            currentTradeArchive = ArchiveStore(_cloneArchive(archiveTemplate));
            tradeArchives.push(currentTradeArchive);
        }
        unchecked { totalTradeCount++; }
        isFactoryTrade[clone] = true;
        IPlatformSettings(settingsAddr).authorizeContractByFactory(clone);
    }

    /// @notice Dual payment channel: C2C trade completion accumulator (called by C2CTradeTemplate)
    /// @dev Independent from PlatformSettings' 7 shared mapping groups -- used for frontend to calculate C2C portion separately
    function recordC2CTrade(address seller, address buyer, address token, uint256 amount, bool hadDispute) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        sellerC2CCompletedAmount[seller][token] += amount;
        sellerC2CCompletedCount[seller][token] += 1;
        buyerC2CCompletedAmount[buyer][token] += amount;
        buyerC2CCompletedCount[buyer][token] += 1;
        if (hadDispute) {
            sellerC2CDisputeAmount[seller][token] += amount;
            sellerC2CDisputeCount[seller][token] += 1;
            buyerC2CDisputeAmount[buyer][token] += amount;
            buyerC2CDisputeCount[buyer][token] += 1;
        }
        emit C2CTradeRecorded(seller, buyer, token, amount, hadDispute);
    }

    function disputeCreated(address trade) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        if (msg.sender != trade) revert Mismatch();
        if (isDisputedTrade[trade]) revert WrongStatus();
        disputedTradeIndex[trade] = disputedTrades.length;
        disputedTrades.push(trade);
        isDisputedTrade[trade] = true;
        emit DisputeCreated(trade);
    }

    function disputeResolved(address trade) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        if (msg.sender != trade) revert Mismatch();
        if (!isDisputedTrade[trade]) revert WrongStatus();
        _removeDisputedTrade(trade);
    }

    function sellOrderEnded(address order) external {
        if (!isFactorySellOrder[msg.sender]) revert NotFactorySellOrder();
        if (msg.sender != order) revert Mismatch();
        _removeActiveSellOrder(order);
        _removeFromLanguageIndex(order, true);
        _removeFromTokenIndex(order);
        address seller = IC2CSellOrder(msg.sender).seller();
        if (activeC2COrderCount[seller] > 0) activeC2COrderCount[seller]--;
        _refreshDeposit(seller);
    }

    function buyOrderEnded(address order) external {
        if (!isFactoryBuyOrder[msg.sender]) revert NotFactoryBuyOrder();
        if (msg.sender != order) revert Mismatch();
        _removeActiveBuyOrder(order);
        _removeFromLanguageIndex(order, false);
        _removeFromTokenIndex(order);
        address buyer = IC2CBuyOrder(msg.sender).buyer();
        if (activeC2COrderCount[buyer] > 0) activeC2COrderCount[buyer]--;
        // [C-04 fix]: When a buy order ends while the buyer has an active arbitration hold
        // (buyerBuyOrderArbCount > 0), we must decrement the counter. Otherwise, if the buy
        // order terminates (expires/cancelled/filled) before its trade's arbitration resolves,
        // the counter will never reach 0 and the buyer is permanently blocked from creating
        // new buy orders. The trade's communityResolveDispute will still call endBuyOrderArbitration
        // (a safe no-op when counter is already 0), so this prevents permanent lock-out.
        if (buyerBuyOrderArbCount[buyer] > 0) {
            buyerBuyOrderArbCount[buyer]--;
        }
        _refreshDeposit(buyer);
    }

    function tradeActivityRefresh(address _merchant) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        _refreshDeposit(_merchant);
    }

    function _refreshDeposit(address merchant) internal {
        address df = IPlatformSettings(settingsAddr).getDepositFactory();
        if (df != address(0)) {
            IDepositFactory(df).refreshMerchantActivity(merchant);
        }
    }

    function refreshUserDeposit(address merchant) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        _refreshDeposit(merchant);
    }

    uint256 public constant CANCEL_BATCH_SIZE = 50;
    uint256 public constant FREEZE_BATCH_SIZE = 50;

    /// @notice Freeze down the AVAILABLE capacity of all of a buyer's active buy orders because the
    ///         buyer is a respondent in a post-completion buy-order community dispute. Only the
    ///         disputing trade may call. Does NOT touch sell orders or any other business. In-flight
    ///         (locked) trades on those buy orders keep their deposit and settle normally.
    /// @dev Iterates buyerBuyOrders[buyer] in reverse, popping cancelled/filled/frozen orders after processing.
    ///      Processes up to FREEZE_BATCH_SIZE per call; returns false if more orders remain for next batch.
    ///      freezeAvailableForArbitration is idempotent (no-op on already-frozen or non-active orders).
    /// @return allDone True if all buy orders processed, false if more batches needed
    function freezeBuyerActiveBuyOrders(address buyer) external returns (bool allDone) {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        address[] storage orders = buyerBuyOrders[buyer];
        uint256 n = orders.length > FREEZE_BATCH_SIZE ? FREEZE_BATCH_SIZE : orders.length;
        uint256 processed = 0;
        for (uint256 i = 0; i < n;) {
            uint256 lastIdx = orders.length - 1;
            try C2CBuyOrderTemplate(orders[lastIdx]).freezeAvailableForArbitration() {} catch {}
            // [H-08 fix]: Pop processed orders to allow processing beyond batch size on subsequent calls
            orders.pop();
            unchecked { i++; processed++; }
        }
        allDone = orders.length == 0;
        if (processed > 0 && buyerBuyOrderArbCount[buyer] == 0) {
            buyerBuyOrderArbCount[buyer] = 1;
        }
        emit BuyerBuyOrdersFrozen(buyer, processed);
        return allDone;
    }

    /// @notice Decrement a buyer's in-progress buy-order arbitration counter when their buy-order
    ///         dispute resolves. Only the resolving trade may call. Once the counter reaches 0 the
    ///         buyer may create new buy orders again.
    function endBuyOrderArbitration(address buyer) external {
        if (!isFactoryTrade[msg.sender]) revert NotFactoryTrade();
        if (buyerBuyOrderArbCount[buyer] > 0) buyerBuyOrderArbCount[buyer] -= 1;
        emit BuyOrderArbitrationEnded(buyer);
    }

    // [H-06 fix]: Pop orders after cancel to process all orders beyond batch size
    function cancelAllOrdersFor(address merchant) external returns (bool allDone) {
        address df = IPlatformSettings(settingsAddr).getDepositFactory();
        if (msg.sender != df) revert NotAuthorized();

        address[] storage sellOrders = sellerSellOrders[merchant];
        uint256 batchSize = sellOrders.length > CANCEL_BATCH_SIZE ? CANCEL_BATCH_SIZE : sellOrders.length;
        for (uint256 i = 0; i < batchSize;) {
            uint256 lastIdx = sellOrders.length - 1;
            try C2CSellOrderTemplate(sellOrders[lastIdx]).cancelByFactory() {} catch {}
            sellOrders.pop();
            unchecked { i++; }
        }

        address[] storage buyOrders = buyerBuyOrders[merchant];
        batchSize = buyOrders.length > CANCEL_BATCH_SIZE ? CANCEL_BATCH_SIZE : buyOrders.length;
        for (uint256 i = 0; i < batchSize;) {
            uint256 lastIdx = buyOrders.length - 1;
            try C2CBuyOrderTemplate(buyOrders[lastIdx]).cancelByFactory() {} catch {}
            buyOrders.pop();
            unchecked { i++; }
        }

        allDone = sellOrders.length == 0 && buyOrders.length == 0;
    }

    function activeOrderCountOf(address merchant) external view returns (uint256) { return activeC2COrderCount[merchant]; }
    function getSellOrderCount() external view returns (uint256) { return activeSellOrders.length; }
    function getBuyOrderCount() external view returns (uint256) { return activeBuyOrders.length; }
    function getTradeCount() external view returns (uint256) { return totalTradeCount; }
    function getTradeArchiveCount() external view returns (uint256) { return tradeArchives.length; }
    function getDisputedTradeCount() external view returns (uint256) { return disputedTrades.length; }
    function getPaymentTokenOrderCount(address token) external view returns (uint256) { return paymentTokenToOrders[token].length; }
    function getSellerSellOrderCount(address seller) external view returns (uint256) { return sellerSellOrders[seller].length; }
    function getBuyerBuyOrderCount(address buyer) external view returns (uint256) { return buyerBuyOrders[buyer].length; }

    /// @notice Get max order limit for a merchant based on their deposit status
    /// @param _merchant Merchant address
    /// @return Maximum number of orders (C2C + products + auctions) this merchant can have active
    function _getMaxOrdersForMerchant(address _merchant) internal view returns (uint256) {
        address depositAddr = IDepositFactory(depositFactoryAddr).getDeposit(_merchant);
        if (depositAddr == address(0)) {
            return MAX_ORDERS_WITHOUT_DEPOSIT;
        }
        try IMerchantDeposit(depositAddr).balanceOf(usdtAddr) returns (uint256 balance) {
            if (balance > 0) {
                return MAX_ORDERS_WITH_DEPOSIT;
            }
        } catch {}
        return MAX_ORDERS_WITHOUT_DEPOSIT;
    }

    /// @notice Get total active orders for a merchant (C2C + products + auctions)
    /// @param _merchant Merchant address
    /// @return Total active order count across all factories
    function _getTotalActiveOrdersForMerchant(address _merchant) internal view returns (uint256) {
        uint256 total = activeC2COrderCount[_merchant];

        // Add product count from ProductFactory
        address pf = IPlatformSettings(settingsAddr).getProductFactory();
        if (pf != address(0)) {
            try IProductFactory(pf).getDelistInfo(_merchant) returns (uint256 activeProducts, uint256, bool) {
                total += activeProducts;
            } catch {}
        }

        // Add auction count from AuctionFactory
        address af = IPlatformSettings(settingsAddr).getAuctionFactory();
        if (af != address(0)) {
            try IAuctionFactory(af).activeSellerAuctionCount(_merchant) returns (uint256 activeAuctions) {
                total += activeAuctions;
            } catch {}
        }

        return total;
    }

    /// Language market isolation: get order counts by language
    function getSellOrderCountByLanguage(string calldata language) external view returns (uint256) {
        return sellOrdersByLanguage[language].length;
    }
    function getBuyOrderCountByLanguage(string calldata language) external view returns (uint256) {
        return buyOrdersByLanguage[language].length;
    }

    function _removeActiveSellOrder(address order) internal {
        uint256 idx = sellOrderIndex[order];
        uint256 lastIdx = activeSellOrders.length - 1;
        if (idx != lastIdx) {
            address last = activeSellOrders[lastIdx];
            activeSellOrders[idx] = last;
            sellOrderIndex[last] = idx;
        }
        activeSellOrders.pop();
        delete sellOrderIndex[order];
    }

    function _removeActiveBuyOrder(address order) internal {
        uint256 idx = buyOrderIndex[order];
        uint256 lastIdx = activeBuyOrders.length - 1;
        if (idx != lastIdx) {
            address last = activeBuyOrders[lastIdx];
            activeBuyOrders[idx] = last;
            buyOrderIndex[last] = idx;
        }
        activeBuyOrders.pop();
        delete buyOrderIndex[order];
    }

    function _removeDisputedTrade(address trade) internal {
        uint256 idx = disputedTradeIndex[trade];
        uint256 lastIdx = disputedTrades.length - 1;
        if (idx != lastIdx) {
            address last = disputedTrades[lastIdx];
            disputedTrades[idx] = last;
            disputedTradeIndex[last] = idx;
        }
        disputedTrades.pop();
        delete disputedTradeIndex[trade];
        delete isDisputedTrade[trade];
    }

    function _removeFromTokenIndex(address order) internal {
        address pt = orderPaymentToken[order];
        if (pt != address(0)) {
            address[] storage ptArr = paymentTokenToOrders[pt];
            uint256 ptIdx = paymentTokenOrderIndex[order];
            uint256 ptLast = ptArr.length - 1;
            if (ptIdx != ptLast) {
                address lastOrder = ptArr[ptLast];
                ptArr[ptIdx] = lastOrder;
                paymentTokenOrderIndex[lastOrder] = ptIdx;
            }
            ptArr.pop();
            delete paymentTokenOrderIndex[order];
            delete orderPaymentToken[order];
        }
    }

    /// @notice Language market isolation: remove an ended order from its language-specific index (swap-pop)
    /// @param order The order being removed
    /// @param isSell true for sell-order array, false for buy-order array
    /// @dev Must be called before _removeFromTokenIndex (which clears orderLanguage). Mirrors EVM
    ///      active-array maintenance so by-language queries never surface ended/cancelled orders.
    function _removeFromLanguageIndex(address order, bool isSell) internal {
        string memory lang = orderLanguage[order];
        if (bytes(lang).length == 0) return;
        if (isSell) {
            address[] storage arr = sellOrdersByLanguage[lang];
            uint256 idx = sellOrderLanguageIndex[order];
            uint256 lastIdx = arr.length - 1;
            if (idx != lastIdx) {
                address last = arr[lastIdx];
                arr[idx] = last;
                sellOrderLanguageIndex[last] = idx;
            }
            arr.pop();
            delete sellOrderLanguageIndex[order];
        } else {
            address[] storage arr = buyOrdersByLanguage[lang];
            uint256 idx = buyOrderLanguageIndex[order];
            uint256 lastIdx = arr.length - 1;
            if (idx != lastIdx) {
                address last = arr[lastIdx];
                arr[idx] = last;
                buyOrderLanguageIndex[last] = idx;
            }
            arr.pop();
            delete buyOrderLanguageIndex[order];
        }
    }

    function _clone(address impl) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(96, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
            if iszero(instance) { revert(0, 0) }
        }
    }
}