// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * ServiceProductTemplate — Service product template (multi-order, USDT only)
 * Fee: 5% (settings.getFeeRate(2))
 */

import "./interfaces/Interfaces.sol";
import "./ProductLib.sol";

/// @title ServiceProductTemplate - Service Escrow (EIP-1167 Clone, USDT Only)
contract ServiceProductTemplate {

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    uint256 private _locked;
    modifier nonReentrant() {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    bool public initialized;
    address public seller;
    address public factory;
    string public language;
    string public keyword;
    string public metadataURI;
    ServiceItem[] public serviceItems;
    bool public delisted;

    mapping(bytes16 => ServiceOrder) public orders;
    bytes16[] public orderIds;
    uint256 public orderNonce;
    uint256 public activeOrderCount;
    // [C-02 fix]: Track pending orders count to avoid gas DoS on delist
    uint256 public pendingOrderCount;
    uint256 public totalStock;

    /// Dual payment channel: pendingWithdrawals[token][to] => amount
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;
    mapping(bytes16 => uint64) public confirmReceiptTime;
    mapping(bytes16 => bool) public guaranteeFromDeposit;
    mapping(bytes16 => uint256) public guaranteeAmount;
    mapping(bytes16 => address) public buyerDepositContract;
    mapping(bytes16 => uint256) public orderFrozenForArbitration;

    address public usdtAddr;
    IPlatformSettings public settings;
    IInviteRegistry public inviteRegistry;
    IKeywordWeight public keywordWeight;
    IMerchantDeposit public merchantDeposit;

    event OrderCreated(bytes16 indexed orderId, address indexed buyer, uint256 amount, address paymentToken);
    event ServiceStartedEvent(bytes16 indexed orderId);
    event OrderCancelled(bytes16 indexed orderId, string reason);
    event ArbitrationRequested(bytes16 indexed orderId, address indexed by);
    event ArbitrationResolved(bytes16 indexed orderId, address winner);

    modifier onlySeller() { if (msg.sender != seller) revert NotSeller(); _; }
    modifier onlyAdminOrCS() { if (!settings.isAdminOrCS(msg.sender)) revert NotAdminOrCS(); _; }

    function _getOrder(bytes16 _orderId) internal view returns (ServiceOrder storage o) {
        o = orders[_orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
    }

    /// @notice Initialize service product contract (USDT only)
    function initialize(
        address _seller, ServiceStrings calldata _strings,
        string[] calldata, ServiceItem[] calldata _serviceItems,
        PlatformContracts calldata _contracts,
        address _merchantDeposit
    ) external {
        if (initialized) revert AlreadyInit();
        initialized = true;
        _locked = 1;
        seller = _seller;
        factory = msg.sender;
        language = _strings.language;
        keyword = _strings.keyword;
        for (uint i = 0; i < _serviceItems.length; ) {
            serviceItems.push(_serviceItems[i]);
            totalStock += _serviceItems[i].stock;
            unchecked { i++; }
        }
        metadataURI = _strings.metadataURI;
        usdtAddr = _contracts.usdt;
        settings = IPlatformSettings(_contracts.settings);
        inviteRegistry = IInviteRegistry(_contracts.inviteRegistry);
        keywordWeight = IKeywordWeight(_contracts.keywordWeight);
        merchantDeposit = IMerchantDeposit(_merchantDeposit);
    }

    function _validatePaymentToken(address _token) internal view {
        if (_token != usdtAddr) revert TokenNotAccepted();
    }

    /// @notice Buyer purchases service (dual payment channel)
    function purchase(uint256 _serviceItemIndex, address _token) external noContract nonReentrant {
        if (delisted) revert IsDelisted();
        if (msg.sender == seller) revert CannotBuyOwn();
        if (_serviceItemIndex >= serviceItems.length) revert InvalidItem();
        ServiceItem storage item = serviceItems[_serviceItemIndex];
        if (item.stock == 0) revert OutOfStock();
        _validatePaymentToken(_token);
        uint256 total = item.price;
        if (total == 0) revert Insufficient();
        if (!IERC20(_token).transferFrom(msg.sender, address(this), total)) revert TransferFailed();
        unchecked { item.stock--; totalStock--; }
        uint256 nonce; unchecked { nonce = orderNonce++; }
        bytes16 id = bytes16(keccak256(abi.encodePacked(address(this), msg.sender, block.timestamp, nonce)));
        ServiceOrder storage o = orders[id];
        o.buyer = msg.sender;
        o.serviceItemIndex = uint8(_serviceItemIndex);
        o.orderAmount = total;
        o.orderTime = uint64(block.timestamp);
        o.orderStatus = OrderStatus.Confirmed;
        o.paymentToken = _token;
        orderIds.push(id);
        // Audit note [L-04]: unchecked increment/decrement of activeOrderCount is safe,
        // because each order increments on creation and decrements on cancel/complete/arbitration, so underflow cannot occur logically.
        unchecked { activeOrderCount++; }
        // [C-02 fix]: Increment pending order count
        unchecked { pendingOrderCount++; }
        if (address(merchantDeposit) != address(0)) {
            merchantDeposit.authorizeProduct(address(this));
        }
        emit OrderCreated(id, msg.sender, total, _token);
        IProductFactory(factory).orderCreated(msg.sender);
        IProductFactory(factory).bumpSeedOnActivity(address(this));
    }

    function cancelOrder(bytes16 _orderId) external noContract nonReentrant {
        ServiceOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Confirmed) revert WrongStatus();
        if (msg.sender != seller && msg.sender != o.buyer) revert NotParty();
        o.orderStatus = OrderStatus.Cancelled;
        _restoreServiceStock(o.serviceItemIndex);
        unchecked { activeOrderCount--; }
        // [C-02 fix]: Decrement pending order count
        unchecked { pendingOrderCount--; }
        ProductLib._safeTransferToUser(o.paymentToken, o.buyer, o.orderAmount, pendingWithdrawals);
        emit OrderCancelled(_orderId, "Cancelled");
    }

    // Audit note [H-01]: startService settles immediately — this is intentional by design.
    // Rationale: Service products are intangible and cannot be "shipped" like physical goods.
    // The service lifecycle is: purchase (Confirmed) -> buyer starts service -> immediate settlement.
    // Once the buyer clicks startService, the service is considered consumed (e.g., access granted, consultation begun),
    // and funds are released to the seller. This mirrors real-world service consumption where payment is due upon service initiation.
    // Frontend must display a prominent confirmation dialog warning that funds will be irrevocably released to the seller.
    // If the service is not delivered after starting, the buyer can initiate community arbitration to seek compensation.
    // This design choice trades off pre-delivery escrow for simplicity, as ongoing service quality cannot be objectively
    // verified on-chain and would otherwise require an impractical "seller confirms service delivered" step that sellers
    // could indefinitely withhold, locking buyer funds.
    function startService(bytes16 _orderId) external noContract nonReentrant {
        ServiceOrder storage o = _getOrder(_orderId);
        if (msg.sender != o.buyer) revert NotBuyer();
        if (o.orderStatus != OrderStatus.Confirmed) revert WrongStatus();
        // [H-12 fix]: Check settled flag before settling to prevent double settlement
        if (o.settled) revert AlreadySettled();
        o.orderStatus = OrderStatus.ServiceStarted;
        o.serviceStarted = true;
        // pendingOrderCount not decremented here - only when order completes
        IProductFactory(factory).bumpSeedOnActivity(address(this));
        _settle(_orderId);
        emit ServiceStartedEvent(_orderId);
    }

    // ==================== Community Arbitration ====================

    function requestCommunityArbitration(bytes16 _orderId, string calldata evidence, string[] calldata _images) external noContract nonReentrant {
        ServiceOrder storage o = _getOrder(_orderId);
        // Design note: Product-type community arbitration only allows the buyer to initiate.
        // Seller-side risk is covered by merchant deposit freeze/deduction; sellers cannot initiate product community arbitration to trigger buyer wallet deductions.
        if (msg.sender != o.buyer) revert NotBuyer();
        if (_images.length > 9) revert TooManyImages();

        address arbFactory = settings.getCommunityArbitrationFactory();
        if (arbFactory == address(0)) revert ZeroAddress();

        bool isCompleted = (o.orderStatus == OrderStatus.Completed);
        if (isCompleted) {
            uint256 window = ICommunityArbitrationFactory(arbFactory).ARBITRATION_WINDOW();
            if (block.timestamp > confirmReceiptTime[_orderId] + window) revert ArbitrationWindowExpired();
        } else if (
            o.orderStatus != OrderStatus.Confirmed &&
            o.orderStatus != OrderStatus.ServiceStarted &&
            o.orderStatus != OrderStatus.RefundRequested
        ) {
            revert WrongStatus();
        }

        // [H-14 fix]: Cache order status before external calls (CEI pattern compliance)
        address depAddr = address(merchantDeposit);
        if (depAddr == address(0)) {
            address df = settings.getDepositFactory();
            if (df != address(0)) {
                depAddr = IDepositFactory(df).getDeposit(seller);
                if (depAddr != address(0)) merchantDeposit = IMerchantDeposit(depAddr);
            }
        }

        uint256 freezeAmt = o.orderAmount * 1000 / 10000;
        if (isCompleted && depAddr != address(0)) {
            freezeAmt = o.orderAmount * 11000 / 10000;
        }

        CaseInitParams memory params = CaseInitParams({
            initiator: msg.sender,
            respondent: msg.sender == o.buyer ? seller : o.buyer,
            initiatorIsBuyer: msg.sender == o.buyer,
            businessContract: address(this),
            orderId: _orderId,
            businessType: BusinessType.Product,
            disputeAmount: o.orderAmount,
            evidence: evidence,
            evidenceImages: _images
        });

        address caseAddr = ICommunityArbitrationFactory(arbFactory).createCase(params, o.paymentToken);

        if (depAddr != address(0) && freezeAmt > 0) {
            uint256 available = IMerchantDeposit(depAddr).getAvailableBalance(o.paymentToken);
            uint256 actualFreeze = freezeAmt > available ? available : freezeAmt;
            if (actualFreeze > 0) {
                // Seller deposit may have been created/funded after this product was listed,
                // in which case purchase() never authorized this product on it. Self-authorize
                // before freezing (mirrors the buyer-guarantee branch); authorizeProduct is
                // idempotent and validates this is a factory product.
                IMerchantDeposit(depAddr).authorizeProduct(address(this));
                IMerchantDeposit(depAddr).freezeDeposit(actualFreeze, o.paymentToken);
            }
            orderFrozenForArbitration[_orderId] = actualFreeze;
        }

        _handleBuyerGuarantee(_orderId, o.buyer, o.orderAmount, o.paymentToken, caseAddr);

        // [H-14 fix]: Update state after all external interactions (CEI pattern)
        o.orderStatus = OrderStatus.Arbitrating;
        o.hadArbitration = true;

        IProductFactory(factory).disputeCreated(address(this));
    }

    function _handleBuyerGuarantee(bytes16 _orderId, address _buyer, uint256 _orderAmount, address _token, address) internal {
        uint256 g = _orderAmount * 1000 / 10000;
        if (g == 0) return;
        address dep = IDepositFactory(settings.getDepositFactory()).getDeposit(_buyer);
        if (dep != address(0) && IMerchantDeposit(dep).getAvailableBalance(_token) >= g) {
            IMerchantDeposit(dep).authorizeProduct(address(this));
            IMerchantDeposit(dep).freezeDeposit(g, _token);
            guaranteeFromDeposit[_orderId] = true;
            buyerDepositContract[_orderId] = dep;
        } else {
            if (!IERC20(_token).transferFrom(_buyer, address(this), g)) revert TransferFailed();
        }
        guaranteeAmount[_orderId] = g;
    }

    function communityResolve(bytes16 _orderId, address winner, uint256 arbFee, uint256) external nonReentrant {
        address arbFactory = settings.getCommunityArbitrationFactory();
        if (!ICommunityArbitrationFactory(arbFactory).isFactoryCase(msg.sender)) revert NotFactoryCase();
        if (ICommunityArbitrationFactory(arbFactory).getCaseForBusiness(address(this), _orderId) != msg.sender) revert NotFactoryCase();

        ServiceOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Arbitrating) revert NotArbitrating();
        bool wasSettled = o.settled;
        o.orderStatus = OrderStatus.Resolved;
        settings.recordArbitration(seller);

        address depAddr = address(merchantDeposit);

        if (winner == o.buyer) {
            if (!wasSettled) {
                unchecked { activeOrderCount--; }
                _restoreServiceStock(o.serviceItemIndex);
                ProductLib._safeTransferToUser(o.paymentToken, o.buyer, o.orderAmount, pendingWithdrawals);
                // Order completed via arbitration - decrement pending count (only if not already settled)
                unchecked { pendingOrderCount--; }
            }
            uint256 actualArbDeducted;
            if (depAddr != address(0)) {
                uint256 orderFrozen = orderFrozenForArbitration[_orderId];
                uint256 totalDeducted;
                uint256 arbDeduct = arbFee > orderFrozen ? orderFrozen : arbFee;
                if (arbDeduct > 0) {
                    IMerchantDeposit(depAddr).deductFromFrozen(arbDeduct, msg.sender, o.paymentToken);
                    actualArbDeducted = arbDeduct;
                    totalDeducted += arbDeduct;
                }
                if (wasSettled) {
                    uint256 remainingFrozen = orderFrozen > totalDeducted ? orderFrozen - totalDeducted : 0;
                    uint256 orderDeduct = o.orderAmount > remainingFrozen ? remainingFrozen : o.orderAmount;
                    if (orderDeduct > 0) {
                        IMerchantDeposit(depAddr).deductFromFrozen(orderDeduct, o.buyer, o.paymentToken);
                        totalDeducted += orderDeduct;
                    }
                }
                uint256 leftover = orderFrozen > totalDeducted ? orderFrozen - totalDeducted : 0;
                if (leftover > 0) {
                    IMerchantDeposit(depAddr).unfreezeDepositAmount(leftover, o.paymentToken);
                }
                delete orderFrozenForArbitration[_orderId];
            }
            if (wasSettled) {
                settings.recordRefund(seller, o.paymentToken, o.orderAmount);
            }
            if (actualArbDeducted > 0) settings.recordArbitrationPayout(seller, o.paymentToken, actualArbDeducted);
            // Buyer wins: refund buyer's guarantee (winner doesn't pay)
            if (guaranteeFromDeposit[_orderId] && guaranteeAmount[_orderId] > 0) {
                address buyerDepAddr = buyerDepositContract[_orderId];
                if (buyerDepAddr != address(0)) {
                    IMerchantDeposit(buyerDepAddr).unfreezeDepositAmount(guaranteeAmount[_orderId], o.paymentToken);
                }
            } else if (guaranteeAmount[_orderId] > 0) {
                ProductLib._safeTransferToUser(o.paymentToken, o.buyer, guaranteeAmount[_orderId], pendingWithdrawals);
            }
        } else {
            if (!wasSettled) {
                _settle(_orderId);
                // _settle already decrements pendingOrderCount, no need to decrement again
            }
            if (depAddr != address(0)) {
                uint256 orderFrozen = orderFrozenForArbitration[_orderId];
                if (orderFrozen > 0) {
                    IMerchantDeposit(depAddr).unfreezeDepositAmount(orderFrozen, o.paymentToken);
                }
                delete orderFrozenForArbitration[_orderId];
            }
            // Seller wins: buyer's guarantee goes to case (loser pays arbitration fee)
            if (guaranteeFromDeposit[_orderId] && guaranteeAmount[_orderId] > 0) {
                address buyerDepAddr = buyerDepositContract[_orderId];
                if (buyerDepAddr != address(0)) {
                    IMerchantDeposit(buyerDepAddr).deductFromFrozen(guaranteeAmount[_orderId], msg.sender, o.paymentToken);
                }
            } else if (guaranteeAmount[_orderId] > 0) {
                ProductLib._safeTransferToUser(o.paymentToken, msg.sender, guaranteeAmount[_orderId], pendingWithdrawals);
            }
            settings.recordArbitrationPayout(o.buyer, o.paymentToken, guaranteeAmount[_orderId]);
        }

        IProductFactory(factory).disputeResolved(address(this));
    }

    function updateServiceItems(ServiceItem[] calldata _items) external onlySeller noContract {
        if (activeOrderCount > 0) revert ActiveOrder();
        // [H-13 fix]: Prevent updating to empty service items array
        if (_items.length == 0) revert EmptyString();
        delete serviceItems;
        totalStock = 0;
        for (uint i = 0; i < _items.length; ) {
            serviceItems.push(_items[i]);
            totalStock += _items[i].stock;
            unchecked { i++; }
        }
    }

    function _delist() internal {
        if (delisted) revert AlreadyDelisted();
        // [C-05 fix]: Only check for orders that require seller action (Confirmed state).
        // ServiceStarted orders should not block delisting because the seller has completed
        // their obligation. This prevents zombie deposits from being stuck due to buyers who
        // never confirm completion, and allows factory recycling to proceed.
        uint256 pendingCount = _countPendingOrders();
        if (pendingCount > 0) revert ActiveOrder();
        delisted = true;
        IProductFactory(factory).productDelisted(seller);
    }

    /// @notice Count orders in Confirmed state (requiring seller action)
    /// @return count Number of pending orders
    function _countPendingOrders() internal view returns (uint256 count) {
        // [C-02 fix]: Return cached counter instead of looping
        return pendingOrderCount;
    }

    function delistProduct() external onlySeller noContract {
        _delist();
    }

    function adminDelistProduct() external {
        if (!settings.isAdmin(msg.sender)) revert NotAdminOrCS();
        // Admin can force delist regardless of pending orders
        if (delisted) revert AlreadyDelisted();
        delisted = true;
        IProductFactory(factory).productDelisted(seller);
    }

    function delistByFactory(address _seller) external {
        if (msg.sender != factory) revert NotFactory();
        if (_seller != seller) revert NotSeller();
        _delist();
    }

    function claimPending(address token) external nonReentrant {
        ProductLib.claimPending(token, pendingWithdrawals);
    }

    function _restoreServiceStock(uint256 itemIndex) internal {
        if (itemIndex < serviceItems.length) {
            serviceItems[itemIndex].stock++;
            totalStock++;
        }
    }

    function _settle(bytes16 _orderId) internal {
        ServiceOrder storage o = orders[_orderId];
        if (o.settled) revert AlreadySettled();
        o.settled = true;
        if (o.orderStatus != OrderStatus.Resolved) {
            o.orderStatus = OrderStatus.Completed;
        }
        confirmReceiptTime[_orderId] = uint64(block.timestamp);
        unchecked { activeOrderCount--; }
        // Order completed - decrement pending count
        unchecked { pendingOrderCount--; }
        ProductLib.settle(
            ProductLib.SettleParams(seller, o.orderAmount, 2, o.paymentToken, address(settings), address(inviteRegistry), address(keywordWeight)),
            pendingWithdrawals
        );
    }

    function getServiceItemCount() external view returns (uint256) { return serviceItems.length; }
    function getOrderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function getProductInfo() external view returns (
        address seller_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_, uint256 totalStock_,
        string[] memory itemNames, uint256[] memory itemPrices, uint256[] memory itemStocks
    ) {
        seller_ = seller;
        keyword_ = keyword;
        language_ = language;
        metadataURI_ = metadataURI;
        delisted_ = delisted;
        activeOrderCount_ = activeOrderCount;
        totalStock_ = totalStock;
        uint256 len = serviceItems.length;
        itemNames = new string[](len);
        itemPrices = new uint256[](len);
        itemStocks = new uint256[](len);
        for (uint256 i; i < len;) {
            itemNames[i] = serviceItems[i].name;
            itemPrices[i] = serviceItems[i].price;
            itemStocks[i] = serviceItems[i].stock;
            unchecked { ++i; }
        }
    }

    function getProductSpecs() external view returns (
        string[] memory itemNames, uint256[] memory itemPrices, uint256[] memory itemStocks
    ) {
        uint256 len = serviceItems.length;
        itemNames = new string[](len);
        itemPrices = new uint256[](len);
        itemStocks = new uint256[](len);
        for (uint256 i; i < len;) {
            itemNames[i] = serviceItems[i].name;
            itemPrices[i] = serviceItems[i].price;
            itemStocks[i] = serviceItems[i].stock;
            unchecked { ++i; }
        }
    }

    function getActiveOrderExpiryInfos() external pure returns (
        bytes16[] memory, OrderStatus[] memory, uint64[] memory, uint256[] memory
    ) {
        return (new bytes16[](0), new OrderStatus[](0), new uint64[](0), new uint256[](0));
    }

    struct OrderInfo {
        bytes16 orderId;
        address buyer;
        uint8 serviceItemIndex;
        uint8 orderStatus;
        bool serviceStarted;
        uint64 orderTime;
        uint64 confirmTime;
        uint256 orderAmount;
        address paymentToken;
    }

    function getAllOrders() external view returns (OrderInfo[] memory results) {
        uint256 len = orderIds.length;
        results = new OrderInfo[](len);
        for (uint256 i; i < len;) {
            bytes16 oid = orderIds[i];
            ServiceOrder storage o = orders[oid];
            results[i] = OrderInfo(
                oid, o.buyer, o.serviceItemIndex, uint8(o.orderStatus),
                o.serviceStarted, o.orderTime,
                confirmReceiptTime[oid], o.orderAmount, o.paymentToken
            );
            unchecked { ++i; }
        }
    }
}


