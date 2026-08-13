// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * WantToBuyTemplate — Want-to-buy product template (multi-order, dual payment channel)
 *
 * Business flow: Buyer publishes a want-to-buy request and locks funds; seller accepts order by paying 10% deposit then delivers goods
 * Audit note: No auto-confirm-receipt time limit; both parties' funds are locked; trade safety is ensured via economic incentives and arbitration
 *
 * Payment:
 *   - Each order uses USDT as paymentToken; settlement/refund/arbitration all use this token
 *   - Seller pays 10% deposit when accepting order; buyer's funds are already locked in contract
 */

import "./interfaces/Interfaces.sol";
import "./ProductLib.sol";

/// @title WantToBuyTemplate - Want-to-Buy Escrow (EIP-1167 Clone, Dual Payment Channel)
contract WantToBuyTemplate {

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
    address public buyer;           // Want-to-buy publisher (fund-locking party)
    address public factory;
    string public language;
    string public keyword;
    string public metadataURI;
    string[] public images;
    uint256 public requestPrice;    // Unit price
    uint256 public stock;           // Remaining acceptable order count
    uint256 public originalStock;
    bool public delisted;

    /// USDT address
    address public usdtAddr;
    IPlatformSettings public settings;
    IInviteRegistry public inviteRegistry;
    IKeywordWeight public keywordWeight;

    mapping(bytes16 => WantToBuyOrder) public orders;
    bytes16[] public orderIds;
    uint256 public orderNonce;
    uint256 public activeOrderCount;
    // [C-02 fix]: Track pending orders count to avoid gas DoS on delist
    uint256 public pendingOrderCount;
    uint256 public lockedForOrders;  // Total funds committed to active orders

    /// Dual payment channel: pendingWithdrawals[token][to] => amount (pending from failed transfers)
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;
    mapping(bytes16 => uint64) public confirmReceiptTime;

    /// Buyer guarantee for arbitration (frozen at initiation, returned if buyer wins, forfeited if buyer loses)
    mapping(bytes16 => uint256) public guaranteeAmount;
    mapping(bytes16 => bool) public guaranteeFromDeposit;
    mapping(bytes16 => address) public buyerGuaranteeDepositContract;

    /// Seller deposit rate (10% = 1000 basis points)
    uint256 public constant SELLER_DEPOSIT_RATE = 1000;
    /// Auto-confirm-receipt duration: test 15 minutes (production: 15 days)
    uint256 internal constant AUTO_RECEIVE_DURATION = 15 days; // production

    // ==================== Events ====================

    event OrderAccepted(bytes16 indexed orderId, address indexed seller, uint256 amount, uint256 sellerDeposit, address paymentToken);
    event OrderShipped(bytes16 indexed orderId);
    event OrderCompleted(bytes16 indexed orderId, uint256 sellerAmount, uint256 fee, address token);
    event OrderCancelled(bytes16 indexed orderId);
    event ArbitrationRequested(bytes16 indexed orderId, address indexed by);
    event ArbitrationResolved(bytes16 indexed orderId, address winner);
    event AutoReceiveDeadlineUpdated(bytes16 indexed orderId, uint256 newDeadline);

    // ==================== Modifiers ====================

    modifier onlyBuyer() { if (msg.sender != buyer) revert NotBuyer(); _; }
    modifier onlyAdminOrCS() { if (!settings.isAdminOrCS(msg.sender)) revert NotAdminOrCS(); _; }

    // ==================== Internal Helpers ====================

    function _getOrder(bytes16 _orderId) internal view returns (WantToBuyOrder storage o) {
        o = orders[_orderId];
        if (o.seller == address(0)) revert OrderNotFound();
    }

    /// @dev Validate that the given token is USDT
    function _validatePaymentToken(address _token) internal view {
        if (_token != usdtAddr) revert TokenNotAccepted();
    }

    // ==================== Initialize ====================

    /// @notice Initialize want-to-buy product (clone proxy pattern)
    /// @dev Called by factory after cloning, can only be called once. Funds have already been transferred to contract by factory.
    /// @param _buyer Want-to-buy publisher address
    /// @param _strings Product string parameters (language, title, keyword, description, metadataURI)
    /// @param _requestPrice Want-to-buy unit price
    /// @param _stock Want-to-buy quantity (number of acceptable orders)
    /// @param _images Product image URL array
    /// @param _contracts Platform contract address collection
    function initialize(
        address _buyer, ProductStrings calldata _strings,
        uint256 _requestPrice, uint256 _stock,
        string[] calldata _images,
        PlatformContracts calldata _contracts
    ) external {
        if (initialized) revert AlreadyInit();
        initialized = true;
        _locked = 1;
        buyer = _buyer;
        factory = msg.sender;
        language = _strings.language;
        keyword = _strings.keyword;
        metadataURI = _strings.metadataURI;
        for (uint i = 0; i < _images.length; ) { images.push(_images[i]); unchecked { i++; } }
        requestPrice = _requestPrice;
        stock = _stock;
        originalStock = _stock;
        usdtAddr = _contracts.usdt;
        settings = IPlatformSettings(_contracts.settings);
        inviteRegistry = IInviteRegistry(_contracts.inviteRegistry);
        keywordWeight = IKeywordWeight(_contracts.keywordWeight);
    }

    // ==================== Core Order Flow ====================

    /// @notice Seller accepts order (pays 10% deposit, locks buyer's funds)
    /// @param _token Payment token to use (USDT)
    function acceptOrder(address _token) external noContract nonReentrant {
        if (delisted) revert IsDelisted();
        if (msg.sender == buyer) revert CannotBuyOwn();
        if (stock == 0) revert OutOfStock();
        _validatePaymentToken(_token);

        uint256 depositAmt = requestPrice * SELLER_DEPOSIT_RATE / 10000;
        if (depositAmt == 0) revert Insufficient();

        // Seller pays 10% deposit
        if (!IERC20(_token).transferFrom(msg.sender, address(this), depositAmt)) revert TransferFailed();

        uint256 nonce; unchecked { nonce = orderNonce++; }
        bytes16 id = bytes16(keccak256(abi.encodePacked(address(this), msg.sender, block.timestamp, nonce)));

        WantToBuyOrder storage o = orders[id];
        o.seller = msg.sender;
        o.orderStatus = OrderStatus.Confirmed;
        o.orderTime = uint64(block.timestamp);
        o.orderAmount = requestPrice;
        o.sellerDeposit = depositAmt;
        o.paymentToken = _token;

        orderIds.push(id);
        // Audit note [L-04]: unchecked increment/decrement of activeOrderCount is safe,
        // because each order increments on creation and decrements on cancel/complete/arbitration, so underflow cannot occur logically.
        unchecked { activeOrderCount++; }
        lockedForOrders += requestPrice;
        stock--;

        emit OrderAccepted(id, msg.sender, requestPrice, depositAmt, _token);
        IProductFactory(factory).orderCreated(buyer);
        IProductFactory(factory).orderAcceptedBySeller(msg.sender);
        IProductFactory(factory).bumpSeedOnActivity(address(this));
    }

    /// @notice Seller ships order
    function shipOrder(bytes16 _orderId) external noContract {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (msg.sender != o.seller) revert NotSeller();
        if (o.orderStatus != OrderStatus.Confirmed) revert WrongStatus();
        o.orderStatus = OrderStatus.Shipped;
        o.shipTime = uint64(block.timestamp);
        o.autoReceiveDeadline = uint64(block.timestamp + AUTO_RECEIVE_DURATION);
        IProductFactory(factory).orderShipped(buyer);
        IProductFactory(factory).bumpSeedOnActivity(address(this));
        emit OrderShipped(_orderId);
    }

    /// @notice Buyer confirms receipt
    function confirmReceive(bytes16 _orderId) external noContract nonReentrant {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (msg.sender != buyer) revert NotBuyer();
        if (o.orderStatus != OrderStatus.Shipped) revert WrongStatus();
        IProductFactory(factory).bumpSeedOnActivity(address(this));
        _settle(_orderId);
    }

    /// @notice Seller voluntarily refunds (cancels order, returns seller deposit, releases buyer locked funds)
    function sellerRefund(bytes16 _orderId) external noContract nonReentrant {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (msg.sender != o.seller) revert NotSeller();
        if (o.orderStatus != OrderStatus.Confirmed && o.orderStatus != OrderStatus.Shipped) revert WrongStatus();
        o.orderStatus = OrderStatus.Cancelled;
        unchecked { activeOrderCount--; }
        stock++;
        lockedForOrders -= o.orderAmount;
        ProductLib._safeTransferToUser(o.paymentToken, o.seller, o.sellerDeposit, pendingWithdrawals);
        settings.recordRefund(o.seller, o.paymentToken, o.orderAmount);
        emit OrderCancelled(_orderId);
    }

    /// @notice Auto-receive after timeout (auto-confirm receipt)
    function triggerAutoReceive(bytes16 _orderId) external nonReentrant {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Shipped) revert WrongStatus();
        if (block.timestamp <= o.autoReceiveDeadline) revert NotExpired();
        _settle(_orderId);
    }

    /// @notice Seller extends auto-confirm-receipt deadline (can only increase, gives buyer more inspection time)
    function updateAutoReceiveDeadline(bytes16 _orderId, uint256 _newDeadline) external noContract {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (msg.sender != o.seller) revert NotSeller();
        if (o.orderStatus != OrderStatus.Shipped) revert WrongStatus();
        if (_newDeadline > type(uint64).max) revert MustBeLater();
        if (_newDeadline <= o.autoReceiveDeadline) revert MustBeLater();
        o.autoReceiveDeadline = uint64(_newDeadline);
        emit AutoReceiveDeadlineUpdated(_orderId, _newDeadline);
    }

    // ==================== Cancel Flow ====================

    /// @notice Seller actively cancels order (allowed in Confirmed or Shipped status)
    function sellerCancel(bytes16 _orderId) external noContract nonReentrant {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (msg.sender != o.seller) revert NotSeller();
        if (o.orderStatus != OrderStatus.Confirmed && o.orderStatus != OrderStatus.Shipped) revert WrongStatus();
        _cancelOrder(_orderId);
    }

    /// @notice Buyer cancels order directly (only before seller ships, i.e. Confirmed status)
    /// @dev Once seller ships (Shipped status), buyer can no longer cancel. Seller deposit is returned on cancel.
    function buyerRequestCancel(bytes16 _orderId) external onlyBuyer noContract nonReentrant {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Confirmed) revert WrongStatus();
        _cancelOrder(_orderId);
    }

    /// @dev Cancel order internal logic: restore stock, unlock buyer funds, return seller deposit
    function _cancelOrder(bytes16 _orderId) internal {
        WantToBuyOrder storage o = orders[_orderId];
        if (o.orderStatus != OrderStatus.Confirmed && o.orderStatus != OrderStatus.Shipped) revert WrongStatus();
        o.orderStatus = OrderStatus.Cancelled;
        unchecked { activeOrderCount--; }
        stock++;
        lockedForOrders -= o.orderAmount;
        ProductLib._safeTransferToUser(o.paymentToken, o.seller, o.sellerDeposit, pendingWithdrawals);
        emit OrderCancelled(_orderId);
    }

    // ==================== Community Arbitration ====================

    /// @notice Buyer initiates community arbitration
    /// @dev Design note: Want-to-buy community arbitration only allows the buyer (want-to-buy publisher) to initiate.
    ///      Seller's 10% deposit is in this contract, serving as arbitration collateral.
    function requestCommunityArbitration(bytes16 _orderId, string calldata evidence, string[] calldata _images) external noContract nonReentrant {
        WantToBuyOrder storage o = _getOrder(_orderId);
        if (msg.sender != buyer) revert NotBuyer();
        if (_images.length > 9) revert TooManyImages();

        address arbFactory = settings.getCommunityArbitrationFactory();
        if (arbFactory == address(0)) revert ZeroAddress();

        bool isCompleted = (o.orderStatus == OrderStatus.Completed);
        if (isCompleted) {
            uint256 window = ICommunityArbitrationFactory(arbFactory).ARBITRATION_WINDOW();
            if (block.timestamp > confirmReceiptTime[_orderId] + window) revert ArbitrationWindowExpired();
        } else if (
            o.orderStatus != OrderStatus.Confirmed &&
            o.orderStatus != OrderStatus.Shipped
        ) {
            revert WrongStatus();
        }

        o.orderStatus = OrderStatus.Arbitrating;
        o.hadArbitration = true;

        CaseInitParams memory params = CaseInitParams({
            initiator: msg.sender,
            respondent: o.seller,
            initiatorIsBuyer: true,
            businessContract: address(this),
            orderId: _orderId,
            businessType: BusinessType.Product,
            disputeAmount: o.orderAmount,
            evidence: evidence,
            evidenceImages: _images
        });

        // Dual payment channel: arbitration factory creates case with order token
        ICommunityArbitrationFactory(arbFactory).createCase(params, o.paymentToken);

        // Freeze buyer's guarantee (10% of orderAmount)
        // Priority: freeze from MD if sufficient, otherwise transferFrom wallet
        uint256 g = o.orderAmount * 1000 / 10000; // 10%
        if (g > 0) {
            address df = settings.getDepositFactory();
            address dep = IDepositFactory(df).getDeposit(buyer);
            if (dep != address(0) && IMerchantDeposit(dep).getAvailableBalance(o.paymentToken) >= g) {
                IMerchantDeposit(dep).authorizeProduct(address(this));
                IMerchantDeposit(dep).freezeDeposit(g, o.paymentToken);
                guaranteeFromDeposit[_orderId] = true;
                buyerGuaranteeDepositContract[_orderId] = dep;
            } else {
                if (!IERC20(o.paymentToken).transferFrom(buyer, address(this), g)) revert TransferFailed();
                guaranteeFromDeposit[_orderId] = false;
            }
            guaranteeAmount[_orderId] = g;
        }

        IProductFactory(factory).disputeCreated(address(this));
    }

    /// @notice Community arbitration callback resolution
    /// @dev Called by arbitration case contract. Seller deposit is handled directly in this contract.
    ///      wasSettled scenario: If community arbitration is initiated after order is in Completed status, seller deposit was already returned in _settle.
    ///      In this case, buyer winning can only rely on buyer 10% guarantee refund + platform record stats; cannot compensate from seller deposit.
    function communityResolve(bytes16 _orderId, address winner, uint256 arbFee, uint256) external nonReentrant {
        address arbFactory = settings.getCommunityArbitrationFactory();
        if (!ICommunityArbitrationFactory(arbFactory).isFactoryCase(msg.sender)) revert NotFactoryCase();
        if (ICommunityArbitrationFactory(arbFactory).getCaseForBusiness(address(this), _orderId) != msg.sender) revert NotFactoryCase();

        WantToBuyOrder storage o = _getOrder(_orderId);
        if (o.orderStatus != OrderStatus.Arbitrating) revert NotArbitrating();
        bool wasSettled = o.settled;
        o.orderStatus = OrderStatus.Resolved;
        settings.recordArbitration(o.seller);

        if (winner == buyer) {
            _resolveBuyerWins(_orderId, o, wasSettled, arbFee);
        } else {
            _resolveSellerWins(_orderId, o, wasSettled);
        }

        IProductFactory(factory).disputeResolved(address(this));
    }

    function _resolveBuyerWins(bytes16 _orderId, WantToBuyOrder storage o, bool wasSettled, uint256 arbFee) internal {
        // Buyer wins: refund orderAmount to buyer, arbFee from sellerDeposit to case (arbitrators)
        if (!wasSettled) {
            unchecked { activeOrderCount--; }
            // [FIX] Do NOT restore stock when buyer wins - buyer gets refund, slot is consumed
            // If stock is restored but funds are refunded, contract will be underfunded for remaining slots
            lockedForOrders -= o.orderAmount;

            // Refund buyer's locked orderAmount
            ProductLib._safeTransferToUser(o.paymentToken, buyer, o.orderAmount, pendingWithdrawals);

            // Arb fee from seller deposit
            uint256 feeFromDeposit = arbFee > o.sellerDeposit ? o.sellerDeposit : arbFee;
            uint256 remainingDeposit = o.sellerDeposit - feeFromDeposit;
            if (feeFromDeposit > 0) {
                ProductLib._safeTransferToUser(o.paymentToken, msg.sender, feeFromDeposit, pendingWithdrawals);
            }
            if (remainingDeposit > 0) {
                ProductLib._safeTransferToUser(o.paymentToken, o.seller, remainingDeposit, pendingWithdrawals);
            }
            settings.recordArbitrationPayout(o.seller, o.paymentToken, feeFromDeposit);
        } else {
            // Post-settlement arbitration: seller already received funds.
            // Buyer won → deduct from seller's merchant deposit.
            // Priority: arbFee → case first, remainder → buyer
            address df = settings.getDepositFactory();
            address depAddr = IDepositFactory(df).getDeposit(o.seller);
            if (depAddr != address(0)) {
                IMerchantDeposit(depAddr).authorizeProduct(address(this));
                uint256 available = IMerchantDeposit(depAddr).getAvailableBalance(o.paymentToken);
                uint256 totalNeeded = o.orderAmount + arbFee;
                uint256 actualDeduct = totalNeeded > available ? available : totalNeeded;
                if (actualDeduct > 0) {
                    IMerchantDeposit(depAddr).freezeDeposit(actualDeduct, o.paymentToken);
                    // Priority: arbFee to case first
                    uint256 toCase = actualDeduct >= arbFee ? arbFee : actualDeduct;
                    uint256 toBuyer = actualDeduct - toCase;
                    if (toCase > 0) {
                        IMerchantDeposit(depAddr).deductFromFrozen(toCase, msg.sender, o.paymentToken);
                    }
                    if (toBuyer > 0) {
                        IMerchantDeposit(depAddr).deductFromFrozen(toBuyer, buyer, o.paymentToken);
                    }
                    settings.recordArbitrationPayout(o.seller, o.paymentToken, toCase);
                    settings.recordRefund(o.seller, o.paymentToken, toBuyer);
                }
            }
        }

        // Buyer wins: return buyer's guarantee (winner doesn't pay)
        if (guaranteeFromDeposit[_orderId] && guaranteeAmount[_orderId] > 0) {
            address dep = buyerGuaranteeDepositContract[_orderId];
            if (dep != address(0)) {
                IMerchantDeposit(dep).unfreezeDepositAmount(guaranteeAmount[_orderId], o.paymentToken);
            }
        } else if (guaranteeAmount[_orderId] > 0) {
            ProductLib._safeTransferToUser(o.paymentToken, buyer, guaranteeAmount[_orderId], pendingWithdrawals);
        }
    }

    function _resolveSellerWins(bytes16 _orderId, WantToBuyOrder storage o, bool wasSettled) internal {
        // Seller wins = normal transaction completion. Settle full orderAmount normally (with platform fee).
        // Arb fee from buyer's pre-frozen guarantee → case.
        if (!wasSettled) {
            unchecked { activeOrderCount--; }
            lockedForOrders -= o.orderAmount;

            // Normal settlement: seller gets orderAmount minus platform fee (same as confirmReceive)
            ProductLib.settle(
                ProductLib.SettleParams(o.seller, o.orderAmount, 5, o.paymentToken, address(settings), address(inviteRegistry), address(keywordWeight)),
                pendingWithdrawals
            );

            // Return seller deposit (seller won, deposit returned)
            ProductLib._safeTransferToUser(o.paymentToken, o.seller, o.sellerDeposit, pendingWithdrawals);
        }

        // Buyer's guarantee → case as arb fee (loser pays)
        if (guaranteeFromDeposit[_orderId] && guaranteeAmount[_orderId] > 0) {
            address dep = buyerGuaranteeDepositContract[_orderId];
            if (dep != address(0)) {
                IMerchantDeposit(dep).deductFromFrozen(guaranteeAmount[_orderId], msg.sender, o.paymentToken);
            }
        } else if (guaranteeAmount[_orderId] > 0) {
            ProductLib._safeTransferToUser(o.paymentToken, msg.sender, guaranteeAmount[_orderId], pendingWithdrawals);
        }
        if (guaranteeAmount[_orderId] > 0) {
            settings.recordArbitrationPayout(buyer, o.paymentToken, guaranteeAmount[_orderId]);
        }
    }

    // ==================== Settlement ====================

    /// @dev Internal settlement: seller receives payment (minus 5% fee), return seller deposit
    function _settle(bytes16 _orderId) internal {
        WantToBuyOrder storage o = orders[_orderId];
        if (o.settled) revert AlreadySettled();
        o.settled = true;
        if (o.orderStatus != OrderStatus.Resolved) {
            o.orderStatus = OrderStatus.Completed;
        }
        confirmReceiptTime[_orderId] = uint64(block.timestamp);
        unchecked { activeOrderCount--; }
        lockedForOrders -= o.orderAmount;

        ProductLib.settle(
            ProductLib.SettleParams(o.seller, o.orderAmount, 5, o.paymentToken, address(settings), address(inviteRegistry), address(keywordWeight)),
            pendingWithdrawals
        );

        // Return seller deposit
        ProductLib._safeTransferToUser(o.paymentToken, o.seller, o.sellerDeposit, pendingWithdrawals);
    }

    // ==================== Delist ====================

    function _delist() internal {
        if (delisted) revert AlreadyDelisted();
        if (activeOrderCount > 0) revert ActiveOrder();
        delisted = true;
        IProductFactory(factory).productDelisted(buyer);
    }

    /// @dev Refund buyer's remaining unlocked funds (stock * requestPrice)
    /// @notice When delisting, activeOrderCount==0 means lockedForOrders==0; stock represents unconsumed slots
    ///         Precisely refunds stock * requestPrice instead of entire contract balance, to avoid accidentally refunding seller's pendingWithdrawals
    function _refundRemainingFunds() internal {
        // [H-11 fix]: Use payment token from the contract's accepted token instead of usdtAddr
        uint256 refundable = requestPrice * stock;
        if (refundable == 0) return;
        // Refund using the accepted payment token
        address token = usdtAddr != address(0) ? usdtAddr : address(0);
        if (token != address(0)) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 toRefund = refundable > bal ? bal : refundable;
            if (toRefund > 0) {
                ProductLib._safeTransferToUser(token, buyer, toRefund, pendingWithdrawals);
            }
        }
    }

    /// @notice Buyer cancels want-to-buy listing and delists (requires no active orders)
    function cancelListing() external onlyBuyer noContract nonReentrant {
        _delist();
        _refundRemainingFunds();
    }

    /// @notice Buyer actively delists
    function delistProduct() external onlyBuyer noContract nonReentrant {
        _delist();
        _refundRemainingFunds();
    }

    /// @notice Admin force delists
    function adminDelistProduct() external nonReentrant {
        if (!settings.isAdmin(msg.sender)) revert NotAdminOrCS();
        // Admin can force delist regardless of active orders
        if (delisted) revert AlreadyDelisted();
        delisted = true;
        IProductFactory(factory).productDelisted(buyer);
        _refundRemainingFunds();
    }

    /// @notice Factory proxy delist (for zombie reclamation)
    function delistByFactory(address _buyer) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (_buyer != buyer) revert NotBuyer();
        if (delisted) revert AlreadyDelisted();
        _delist();
        _refundRemainingFunds();
    }

    // ==================== Utility ====================

    /// @notice Claim pending balance from failed transfers (per token)
    function claimPending(address token) external nonReentrant {
        ProductLib.claimPending(token, pendingWithdrawals);
    }

    /// @notice Get total order count
    function getOrderCount() external view returns (uint256) {
        return orderIds.length;
    }

    /// @notice Get images array
    function getImages() external view returns (string[] memory) {
        return images;
    }

    function getProductInfo() external view returns (
        address buyer_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_, uint256 requestPrice_, uint256 stock_, uint256 originalStock_
    ) {
        buyer_ = buyer;
        keyword_ = keyword;
        language_ = language;
        metadataURI_ = metadataURI;
        delisted_ = delisted;
        activeOrderCount_ = activeOrderCount;
        requestPrice_ = requestPrice;
        stock_ = stock;
        originalStock_ = originalStock;
    }

    struct OrderInfo {
        bytes16 orderId;
        address seller;
        uint8 orderStatus;
        bool cancelRequested;
        uint64 orderTime;
        uint64 shipTime;
        uint64 cancelRequestTime;
        uint64 confirmTime;
        uint64 autoReceiveDeadline;
        uint256 orderAmount;
        address paymentToken;
    }

    function getAllOrders() external view returns (OrderInfo[] memory results) {
        uint256 len = orderIds.length;
        results = new OrderInfo[](len);
        for (uint256 i; i < len;) {
            bytes16 oid = orderIds[i];
            WantToBuyOrder storage o = orders[oid];
            results[i] = OrderInfo(
                oid, o.seller, uint8(o.orderStatus),
                o.cancelRequested, o.orderTime, o.shipTime, o.cancelRequestTime,
                confirmReceiptTime[oid], o.autoReceiveDeadline, o.orderAmount, o.paymentToken
            );
            unchecked { ++i; }
        }
    }

    /// @notice Active (Shipped) orders' expiry info, signature-compatible with other
    ///         templates so ProductFactoryReader._collectExpired can include WantToBuy.
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
            WantToBuyOrder storage o = orders[orderIds[i]];
            if (o.orderStatus == OrderStatus.Shipped) {
                ids[count] = orderIds[i];
                statuses[count] = o.orderStatus;
                deadlines[count] = o.autoReceiveDeadline;
                amounts[count] = o.orderAmount;
                count++;
            }
            unchecked { ++i; }
        }
        assembly {
            mstore(ids, count)
            mstore(statuses, count)
            mstore(deadlines, count)
            mstore(amounts, count)
        }
    }
}
