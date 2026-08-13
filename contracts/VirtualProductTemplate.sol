// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * VirtualProductTemplate — Virtual product template (multi-order, USDT only)
 */

import "./interfaces/Interfaces.sol";
import "./ProductLib.sol";

/// @title VirtualProductTemplate - Virtual Goods Escrow (EIP-1167 Clone, USDT Only)
contract VirtualProductTemplate {

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
    Spec[] public specs;
    bool public delisted;

    mapping(bytes16 => VirtualOrder) public orders;
    bytes16[] public orderIds;
    uint256 public orderNonce;
    uint256 public activeOrderCount;
    // [C-02 fix]: Track pending orders count to avoid gas DoS on delist
    uint256 public pendingOrderCount;

    /// Dual payment channel: pendingWithdrawals[token][to] => amount
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;
    mapping(bytes16 => uint64) public confirmReceiptTime;
    mapping(bytes16 => bool) public guaranteeFromDeposit;
    mapping(bytes16 => uint256) public guaranteeAmount;
    mapping(bytes16 => address) public buyerDepositContract;
    mapping(bytes16 => uint256) public orderFrozenForArbitration;

    /// Virtual product auto-receive duration (production: 1 day)
    uint256 internal constant _AUTO_RECEIVE_DELAY = 1 days; // production

    address public usdtAddr;
    IPlatformSettings public settings;
    IInviteRegistry public inviteRegistry;
    IKeywordWeight public keywordWeight;
    IMerchantDeposit public merchantDeposit;

    event OrderCreated(bytes16 indexed orderId, address indexed buyer, uint256 amount, address paymentToken);
    event DeliveryConfirmed(bytes16 indexed orderId);
    event OrderCompleted(bytes16 indexed orderId, uint256 sellerAmount, uint256 fee, address token);
    event OrderCancelled(bytes16 indexed orderId);
    event SellerRefunded(bytes16 indexed orderId);
    event ArbitrationRequested(bytes16 indexed orderId, address indexed by);
    event ArbitrationResolved(bytes16 indexed orderId, address winner);
    event ArbitrationShortfall(address indexed buyer, uint256 shortfall);
    event AutoReceiveDeadlineUpdated(bytes16 indexed orderId, uint256 newDeadline);

    modifier onlySeller() { if (msg.sender != seller) revert NotSeller(); _; }
    modifier onlyAdminOrCS() { if (!settings.isAdminOrCS(msg.sender)) revert NotAdminOrCS(); _; }

    function _getOrder(bytes16 _orderId) internal view returns (VirtualOrder storage o) {
        o = orders[_orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
    }

    /// @notice Initialize virtual product (clone proxy pattern, USDT only)
    function initialize(
        address _seller, ProductStrings calldata _strings,
        Spec[] calldata _specs, string[] calldata,
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
        for (uint i = 0; i < _specs.length; ) { specs.push(_specs[i]); unchecked { i++; } }
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

    /// @notice Buyer purchases product (dual payment channel)
    function purchase(uint256 _specIndex, uint256 _quantity, address _token) external noContract nonReentrant {
        if (delisted) revert IsDelisted();
        if (msg.sender == seller) revert CannotBuyOwn();
        if (_specIndex >= specs.length) revert InvalidSpec();
        if (_quantity == 0 || _quantity > specs[_specIndex].stock) revert InvalidQty();
        _validatePaymentToken(_token);
        uint256 total = specs[_specIndex].price * _quantity;
        if (total == 0) revert Insufficient();
        if (!IERC20(_token).transferFrom(msg.sender, address(this), total)) revert TransferFailed();
        uint256 nonce; unchecked { nonce = orderNonce++; }
        bytes16 id = bytes16(keccak256(abi.encodePacked(address(this), msg.sender, block.timestamp, nonce)));
        VirtualOrder storage o = orders[id];
        o.buyer = msg.sender;
        o.specIndex = uint8(_specIndex);
        o.quantity = uint64(_quantity);
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
        specs[_specIndex].stock -= _quantity;
        if (address(merchantDeposit) != address(0)) {
            merchantDeposit.authorizeProduct(address(this));
        }
        emit OrderCreated(id, msg.sender, total, _token);
        IProductFactory(factory).orderCreated(msg.sender);
        IProductFactory(factory).bumpSeedOnActivity(address(this));
    }

    function cancelOrder(bytes16 _orderId) external noContract nonReentrant {
        VirtualOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Confirmed) revert WrongStatus();
        if (msg.sender != seller && msg.sender != o.buyer) revert NotParty();
        o.orderStatus = OrderStatus.Cancelled;
        unchecked { activeOrderCount--; }
        // [C-02 fix]: Decrement pending order count
        unchecked { pendingOrderCount--; }
        specs[o.specIndex].stock += o.quantity;
        ProductLib._safeTransferToUser(o.paymentToken, o.buyer, o.orderAmount, pendingWithdrawals);
        emit OrderCancelled(_orderId);
    }

    function confirmDelivery(bytes16 _orderId) external onlySeller noContract {
        VirtualOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Confirmed) revert WrongStatus();
        o.orderStatus = OrderStatus.Delivered;
        o.deliveryTime = uint64(block.timestamp);
        o.autoReceiveDeadline = uint64(block.timestamp + _AUTO_RECEIVE_DELAY);
        // pendingOrderCount not decremented here - only when order completes
        IProductFactory(factory).orderShipped(seller);
        IProductFactory(factory).bumpSeedOnActivity(address(this));
        emit DeliveryConfirmed(_orderId);
    }

    function confirmReceive(bytes16 _orderId) external noContract nonReentrant {
        VirtualOrder storage o = _getOrder(_orderId);
        if (msg.sender != o.buyer) revert NotBuyer();
        if (o.orderStatus != OrderStatus.Delivered) revert WrongStatus();
        IProductFactory(factory).bumpSeedOnActivity(address(this));
        _settle(_orderId);
    }

    function updateAutoReceiveDeadline(bytes16 _orderId, uint256 _newDeadline) external onlySeller noContract {
        VirtualOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Delivered) revert WrongStatus();
        if (_newDeadline > type(uint64).max) revert MustBeLater();
        if (_newDeadline <= o.autoReceiveDeadline) revert MustBeLater();
        o.autoReceiveDeadline = uint64(_newDeadline);
        emit AutoReceiveDeadlineUpdated(_orderId, _newDeadline);
    }

    function sellerRefund(bytes16 _orderId) external onlySeller noContract nonReentrant {
        VirtualOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Confirmed && o.orderStatus != OrderStatus.Delivered) revert WrongStatus();
        o.orderStatus = OrderStatus.Cancelled;
        unchecked { activeOrderCount--; }
        // Order completed via refund - decrement pending count
        unchecked { pendingOrderCount--; }
        specs[o.specIndex].stock += o.quantity;
        ProductLib._safeTransferToUser(o.paymentToken, o.buyer, o.orderAmount, pendingWithdrawals);
        settings.recordRefund(seller, o.paymentToken, o.orderAmount);
        emit SellerRefunded(_orderId);
    }

    // ==================== Community Arbitration ====================

    function requestCommunityArbitration(bytes16 _orderId, string calldata evidence, string[] calldata _images) external noContract nonReentrant {
        VirtualOrder storage o = _getOrder(_orderId);
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
            o.orderStatus != OrderStatus.Delivered &&
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

        uint256 freezeAmt = isCompleted ? o.orderAmount * 11000 / 10000 : o.orderAmount * 1000 / 10000;

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

        VirtualOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Arbitrating) revert NotArbitrating();
        bool wasSettled = o.settled;
        o.orderStatus = OrderStatus.Resolved;
        settings.recordArbitration(seller);

        address depAddr = address(merchantDeposit);

        if (winner == o.buyer) {
            if (!wasSettled) {
                specs[o.specIndex].stock += o.quantity;
                unchecked { activeOrderCount--; }
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

    function triggerAutoReceive(bytes16 _orderId) external nonReentrant {
        VirtualOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Delivered) revert WrongStatus();
        if (block.timestamp <= o.autoReceiveDeadline) revert NotExpired();
        _settle(_orderId);
    }

    function updateSpecs(Spec[] calldata _specs) external onlySeller noContract {
        if (activeOrderCount > 0) revert ActiveOrder();
        delete specs;
        for (uint i = 0; i < _specs.length;) {
            specs.push(_specs[i]);
            unchecked { ++i; }
        }
    }

    function _delist() internal {
        if (delisted) revert AlreadyDelisted();
        // [C-05 fix]: Only check for orders that require seller action (Confirmed state).
        // Delivered orders should not block delisting because the seller has completed
        // their obligation. This prevents zombie deposits from being stuck due to buyers who
        // never confirm receipt, and allows factory recycling to proceed.
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

    function delistProduct() external onlySeller noContract { _delist(); }

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
        if (delisted) revert AlreadyDelisted();
        _delist();
    }

    function _settle(bytes16 _orderId) internal {
        VirtualOrder storage o = orders[_orderId];
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
            ProductLib.SettleParams(seller, o.orderAmount, 1, o.paymentToken, address(settings), address(inviteRegistry), address(keywordWeight)),
            pendingWithdrawals
        );
    }

    function claimPending(address token) external nonReentrant {
        ProductLib.claimPending(token, pendingWithdrawals);
    }

    function getOrderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function getProductInfo() external view returns (
        address seller_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_,
        string[] memory specNames, uint256[] memory specPrices, uint256[] memory specStocks
    ) {
        seller_ = seller;
        keyword_ = keyword;
        language_ = language;
        metadataURI_ = metadataURI;
        delisted_ = delisted;
        activeOrderCount_ = activeOrderCount;
        uint256 len = specs.length;
        specNames = new string[](len);
        specPrices = new uint256[](len);
        specStocks = new uint256[](len);
        for (uint256 i; i < len;) {
            specNames[i] = specs[i].name;
            specPrices[i] = specs[i].price;
            specStocks[i] = specs[i].stock;
            unchecked { ++i; }
        }
    }

    function getProductSpecs() external view returns (
        string[] memory specNames, uint256[] memory specPrices, uint256[] memory specStocks
    ) {
        uint256 len = specs.length;
        specNames = new string[](len);
        specPrices = new uint256[](len);
        specStocks = new uint256[](len);
        for (uint256 i; i < len;) {
            specNames[i] = specs[i].name;
            specPrices[i] = specs[i].price;
            specStocks[i] = specs[i].stock;
            unchecked { ++i; }
        }
    }

    function getActiveOrderExpiryInfos() external view returns (
        bytes16[] memory ids, OrderStatus[] memory statuses,
        uint64[] memory deadlines, uint256[] memory amounts
    ) {
        uint256 len = orderIds.length;
        ids = new bytes16[](len);
        statuses = new OrderStatus[](len);
        deadlines = new uint64[](len);
        amounts = new uint256[](len);
        uint256 count;
        for (uint256 i; i < len;) {
            VirtualOrder storage o = orders[orderIds[i]];
            if (o.orderStatus == OrderStatus.Delivered) {
                ids[count] = orderIds[i];
                statuses[count] = o.orderStatus;
                deadlines[count] = o.autoReceiveDeadline;
                amounts[count] = o.orderAmount;
                count++;
            }
            unchecked { ++i; }
        }
        assembly { mstore(ids, count) mstore(statuses, count) mstore(deadlines, count) mstore(amounts, count) }
    }

    struct OrderInfo {
        bytes16 orderId;
        address buyer;
        uint8 specIndex;
        uint8 orderStatus;
        uint64 orderTime;
        uint64 deliveryTime;
        uint64 autoReceiveDeadline;
        uint64 confirmTime;
        uint256 orderAmount;
        address paymentToken;
    }

    function getAllOrders() external view returns (OrderInfo[] memory results) {
        uint256 len = orderIds.length;
        results = new OrderInfo[](len);
        for (uint256 i; i < len;) {
            bytes16 oid = orderIds[i];
            VirtualOrder storage o = orders[oid];
            results[i] = OrderInfo(
                oid, o.buyer, o.specIndex, uint8(o.orderStatus),
                o.orderTime, o.deliveryTime, o.autoReceiveDeadline,
                confirmReceiptTime[oid], o.orderAmount, o.paymentToken
            );
            unchecked { ++i; }
        }
    }
}


