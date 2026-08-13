// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #18: AuctionTemplate — Auction template (Dual Payment Channel)
 *
 * Dual payment channel:
 *   - Payment token is USDT, cannot switch mid-auction
 *   - bid / buyNow / refund / settlement all use paymentToken throughout
 *   - Deposit freeze/compensation uses D5 cross-token strategy (any token deposit from merchant can serve as compensation source)
 *
 * Anti-sniping: bids in last 5 minutes auto-extend by 10 minutes (stackable)
 * Fee: fixed 10%, distributed via InviteRegistry
 */

import "./interfaces/Interfaces.sol";

/// @title AuctionTemplate - Timed Auction (EIP-1167 Clone, Dual Payment Channel)
// Audit note [H-01]: AuctionTemplate intentionally does NOT integrate CooldownManager.
// Design rationale: auction settlement requires buyer to confirmReceive (or auto-receive after deadline).
// Once confirmed, arbitration is no longer supported, so there is no post-settlement dispute window
// that the seller could exploit by withdrawing deposit. The deposit unlock cooldown is only needed
// for C2C trades where the seller can be disputed after completion (buy-order scenario).
contract AuctionTemplate {

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

    // ==================== Constants ====================

    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant ANTI_SNIPE_WINDOW = 5 minutes;
    uint256 public constant ANTI_SNIPE_EXTENSION = 10 minutes;
    uint256 public constant DEPOSIT_LEVERAGE = 10;
    uint256 internal constant _MIN_AUTO_RECEIVE = 15 days; // production
    uint256 public constant SHIPPING_DEADLINE = 3 days; // production

    // ==================== State Variables ====================

    bool public initialized;
    address public seller;
    address public auctionFactory;

    /// Payment token for this auction (always USDT)
    address public paymentToken;
    address public highestBidToken;
    address public usdtAddr;

    IPlatformSettings public settings;
    IInviteRegistry public inviteRegistry;
    IDepositFactory public depositFactory;

    string public title;
    string public description;
    string public language;  // Language market isolation
    string[] public images;
    uint256 public startPrice;
    uint256 public buyNowPrice;
    uint256 public minBidIncrement;
    uint256 public startTime;
    uint256 public endTime;

    address public highestBidder;
    uint256 public highestBid;
    uint256 public highestBidTokenAmount;
    uint256 public bidCount;
    AuctionStatus public auctionStatus;
    AuctionStatus public statusBeforeArbitration;
    string public shippingAddress;
    string public trackingNumber;
    bool public settled;
    bytes16 public orderId;

    /// Dual payment channel: pendingWithdrawals uses double-layer token => to => amount (auction is single-token, but keeps consistent interface)
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;
    uint64 public confirmReceiptTime;
    uint64 public shipTime;
    uint64 public autoReceiveDeadline;
    uint64 public auctionEndedAt;
    bool public arbitrationInitiatedByBuyer;
    bool public guaranteeFromDeposit;
    uint256 public guaranteeAmount;
    address public buyerGuaranteeDepositContract;

    // ==================== Events ====================

    event AuctionCreated(bytes16 indexed orderId, address indexed seller);
    event BidPlaced(address indexed bidder, uint256 amount, uint256 newEndTime);
    event AuctionExtended(uint256 newEndTime);
    event BuyNowExecuted(address indexed buyer, uint256 amount);
    event BidRefunded(address indexed bidder, uint256 amount);
    event AuctionEnded(address indexed winner, uint256 winningBid);
    event AuctionFailed();
    event AuctionCancelled();
    event Shipped(string trackingNumber);
    event ReceiptConfirmed();
    event AutoReceiveDeadlineUpdated(uint256 newDeadline);
    event Settled(uint256 sellerAmount, uint256 fee, address token);
    event ArbitrationRequested(address indexed by);
    event ArbitrationResolved(address winner);
    event ArbitrationShortfall(address indexed buyer, uint256 shortfall);
    event NoShipRefundClaimed(address indexed buyer, uint256 refundAmount, uint256 compensation);
    event TransferPending(address indexed to, address indexed token, uint256 amount);

    modifier onlySeller() {
        if (msg.sender != seller) revert NotSeller();
        _;
    }

    modifier onlyHighestBidder() {
        if (msg.sender != highestBidder) revert NotHighestBidder();
        _;
    }

    modifier onlyAdminOrCS() {
        if (!settings.isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        _;
    }

    // ==================== Initialization ====================

    /// @notice Initialize auction (USDT only)
    function initialize(
        address _seller,
        AuctionParams calldata _params,
        address _settings,
        address _inviteRegistry,
        address _depositFactory,
        address _usdt
    ) external {
        if (initialized) revert AlreadyInit();
        if (_usdt == address(0)) revert TokenNotAccepted();
        initialized = true;
        _locked = 1;

        if (_seller == address(0)) revert ZeroAddress();
        if (_params.startTime <= block.timestamp) revert StartTimeMustBeFuture();
        if (_params.endTime <= _params.startTime) revert EndTimeBeforeStart();
        if (_params.endTime - _params.startTime > MAX_DURATION) revert AuctionDurationTooLong();
        if (_params.startPrice == 0) revert ZeroAmount();
        if (_params.buyNowPrice <= _params.startPrice) revert BidTooLow();
        if (_params.minBidIncrement == 0) revert ZeroAmount();

        if (!IPlatformSettings(_settings).isAcceptedToken(_usdt)) revert PaymentTokenRequired();
        address depositAddr = IDepositFactory(_depositFactory).getDeposit(_seller);
        if (depositAddr == address(0)) revert NoMerchantDeposit();
        IMerchantDeposit dep = IMerchantDeposit(depositAddr);
        uint256 totalAvail = dep.getAvailableBalance(_usdt);
        if (totalAvail * DEPOSIT_LEVERAGE < _params.buyNowPrice) revert InsufficientDeposit();

        seller = _seller;
        auctionFactory = msg.sender;
        usdtAddr = _usdt;
        paymentToken = _usdt;
        highestBidToken = _usdt;
        settings = IPlatformSettings(_settings);
        inviteRegistry = IInviteRegistry(_inviteRegistry);
        depositFactory = IDepositFactory(_depositFactory);

        title = _params.title;
        description = _params.description;
        language = _params.language;
        if (_params.images.length > 9) revert TooManyImages();
        for (uint256 i = 0; i < _params.images.length; ) {
            images.push(_params.images[i]);
            unchecked { i++; }
        }
        startPrice = _params.startPrice;
        buyNowPrice = _params.buyNowPrice;
        minBidIncrement = _params.minBidIncrement;
        startTime = _params.startTime;
        endTime = _params.endTime;

        auctionStatus = AuctionStatus.Created;
        orderId = bytes16(keccak256(abi.encodePacked(address(this), _seller, block.timestamp)));

        // Authorize auction contract to deduct merchant deposit; freeze USDT
        dep.authorizeProduct(address(this));
        dep.freezeDeposit(_params.buyNowPrice / DEPOSIT_LEVERAGE, _usdt);

        emit AuctionCreated(orderId, _seller);
    }

    // ==================== Bidding ====================

    function _validatePaymentToken(address _token) internal view {
        if (_token != usdtAddr) revert TokenNotAccepted();
    }

    function bid(uint256 bidPrice, uint256 tokenAmount, string calldata _shippingAddress, address _token) external noContract nonReentrant {
        if (block.timestamp < startTime) revert AuctionNotActive();
        if (block.timestamp >= endTime) revert AuctionNotActive();
        if (auctionStatus != AuctionStatus.Created && auctionStatus != AuctionStatus.Active) revert AuctionNotActive();
        if (msg.sender == seller) revert NotAuthorized();

        uint256 minBid = highestBid == 0 ? startPrice : highestBid + minBidIncrement;
        if (bidPrice < minBid) revert BidTooLow();
        if (bidPrice >= buyNowPrice) revert UseBuyNow();
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount < bidPrice) revert Insufficient();
        _validatePaymentToken(_token);
        // C-02 fix: First bid locks the payment token; subsequent bids must use the same token
        if (highestBidToken != address(0) && _token != highestBidToken) revert TokenMismatch();

        if (!IERC20(_token).transferFrom(msg.sender, address(this), tokenAmount)) revert TransferFailed();

        address prevBidder = highestBidder;
        uint256 prevBidTokenAmount = highestBidTokenAmount;
        address prevBidToken = highestBidToken;

        highestBidder = msg.sender;
        highestBid = bidPrice;
        highestBidTokenAmount = tokenAmount;
        highestBidToken = _token;
        paymentToken = _token;
        shippingAddress = _shippingAddress;
        unchecked { bidCount++; }

        if (auctionStatus == AuctionStatus.Created) {
            auctionStatus = AuctionStatus.Active;
        }

        if (endTime - block.timestamp <= ANTI_SNIPE_WINDOW) {
            endTime += ANTI_SNIPE_EXTENSION;
            emit AuctionExtended(endTime);
        }

        if (prevBidder != address(0) && prevBidTokenAmount > 0) {
            _safeTransferToUser(prevBidder, prevBidTokenAmount, prevBidToken);
            emit BidRefunded(prevBidder, prevBidTokenAmount);
        }

        IAuctionFactory(auctionFactory).bumpSeedOnActivity(address(this));
        emit BidPlaced(msg.sender, bidPrice, endTime);
    }

    function buyNow(uint256 tokenAmount, string calldata _shippingAddress, address _token) external noContract nonReentrant {
        if (block.timestamp < startTime) revert AuctionNotActive();
        if (block.timestamp >= endTime) revert AuctionNotActive();
        if (auctionStatus != AuctionStatus.Created && auctionStatus != AuctionStatus.Active) revert AuctionNotActive();
        if (msg.sender == seller) revert NotAuthorized();

        _validatePaymentToken(_token);
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount < buyNowPrice) revert Insufficient();
        if (highestBidToken != address(0) && _token != highestBidToken) revert TokenMismatch();
        if (!IERC20(_token).transferFrom(msg.sender, address(this), tokenAmount)) revert TransferFailed();

        address prevBidder = highestBidder;
        uint256 prevBidTokenAmount = highestBidTokenAmount;
        address prevBidToken = highestBidToken;

        highestBidder = msg.sender;
        highestBid = buyNowPrice;
        highestBidTokenAmount = tokenAmount;
        highestBidToken = _token;
        paymentToken = _token;
        shippingAddress = _shippingAddress;
        unchecked { bidCount++; }

        auctionStatus = AuctionStatus.Ended;
        auctionEndedAt = uint64(block.timestamp);
        IAuctionFactory(auctionFactory).auctionEnded(address(this));

        if (prevBidder != address(0) && prevBidTokenAmount > 0) {
            _safeTransferToUser(prevBidder, prevBidTokenAmount, prevBidToken);
            emit BidRefunded(prevBidder, prevBidTokenAmount);
        }

        IAuctionFactory(auctionFactory).bumpSeedOnActivity(address(this));
        emit BuyNowExecuted(msg.sender, buyNowPrice);
        emit AuctionEnded(msg.sender, buyNowPrice);
    }

    // ==================== Finalization ====================

    function finalizeAuction() external {
        // [M-07 fix]: Only allow seller, highest bidder, or admin to finalize
        if (msg.sender != seller && msg.sender != highestBidder && !settings.isAdminOrCS(msg.sender)) {
            revert NotAuthorized();
        }
        if (block.timestamp < endTime) revert AuctionNotActive();
        if (auctionStatus != AuctionStatus.Created && auctionStatus != AuctionStatus.Active) revert AuctionNotActive();

        if (highestBidder != address(0) && highestBid > 0) {
            auctionStatus = AuctionStatus.Ended;
            auctionEndedAt = uint64(block.timestamp);
            IAuctionFactory(auctionFactory).auctionEnded(address(this));
            emit AuctionEnded(highestBidder, highestBid);
        } else {
            auctionStatus = AuctionStatus.Failed;
            _unfreezeDeposit();
            IAuctionFactory(auctionFactory).auctionEnded(address(this));
            emit AuctionFailed();
        }
    }

    function cancelAuction() external onlySeller noContract {
        if (auctionStatus != AuctionStatus.Created && auctionStatus != AuctionStatus.Active) revert AuctionNotActive();
        if (highestBidder != address(0)) revert AuctionHasBids();

        auctionStatus = AuctionStatus.Cancelled;
        _unfreezeDeposit();
        IAuctionFactory(auctionFactory).auctionEnded(address(this));
        emit AuctionCancelled();
    }

    /**
     * @notice Admin force-cancels the auction (for content moderation)
     * @dev Only admin can call, can cancel even with bids
     *      Highest bid is returned to bidder
     *      Seller deposit is unfrozen (to prevent permanent lock)
     */
    function adminCancelAuction() external noContract {
        if (!IPlatformSettings(settings).isAdmin(msg.sender)) revert NotAdmin();
        if (auctionStatus == AuctionStatus.Cancelled || auctionStatus == AuctionStatus.Completed) revert AuctionNotActive();

        auctionStatus = AuctionStatus.Cancelled;

        // Return highest bid to bidder (not their fault)
        if (highestBidder != address(0) && highestBid > 0) {
            _safeTransferToUser(highestBidder, highestBid, paymentToken);
        }

        // Unfreeze seller deposit (to prevent permanent lock on chain)
        _unfreezeDeposit();

        IAuctionFactory(auctionFactory).auctionEnded(address(this));
        emit AuctionCancelled();
    }

    // ==================== Shipping & Receipt ====================

    function ship(string calldata _trackingNumber) external onlySeller noContract {
        if (auctionStatus != AuctionStatus.Ended) revert AuctionNotEnded();
        trackingNumber = _trackingNumber;
        shipTime = uint64(block.timestamp);
        autoReceiveDeadline = uint64(block.timestamp + _MIN_AUTO_RECEIVE);
        auctionStatus = AuctionStatus.Shipped;
        IAuctionFactory(auctionFactory).auctionShipped(seller);
        IAuctionFactory(auctionFactory).bumpSeedOnActivity(address(this));
        emit Shipped(_trackingNumber);
    }

    function confirmReceipt() external onlyHighestBidder noContract nonReentrant {
        if (auctionStatus != AuctionStatus.Shipped) revert AuctionNotShipped();
        confirmReceiptTime = uint64(block.timestamp);
        IAuctionFactory(auctionFactory).bumpSeedOnActivity(address(this));
        _settle();
        emit ReceiptConfirmed();
    }

    // Audit note [M-09]: No upper bound on deadline extension is intentional.
    // Only the seller (onlySeller) can call this on their own auction. The buyer's recourse
    // is confirmReceipt() or community arbitration if the seller extends unreasonably.
    function updateAutoReceiveDeadline(uint256 _newDeadline) external onlySeller noContract {
        if (auctionStatus != AuctionStatus.Shipped) revert AuctionNotShipped();
        if (_newDeadline <= autoReceiveDeadline) revert MustBeLater();
        autoReceiveDeadline = uint64(_newDeadline);
        emit AutoReceiveDeadlineUpdated(_newDeadline);
    }

    function triggerAutoReceive() external nonReentrant {
        if (auctionStatus != AuctionStatus.Shipped) revert AuctionNotShipped();
        if (block.timestamp <= autoReceiveDeadline) revert NotExpired();
        confirmReceiptTime = uint64(block.timestamp);
        _settle();
        emit ReceiptConfirmed();
    }

    function getAuctionShippingDeadline() external view returns (uint64 shipTime_, uint64 autoReceiveDeadline_) {
        return (shipTime, autoReceiveDeadline);
    }

    // ==================== No-Ship Refund ====================

    // Audit note [C-01]: claimNoShipRefund intentionally does NOT exist as a self-service refund.
    // Design: seller no-ship → buyer MUST go through community arbitration (requestCommunityArbitration).
    // Rationale: forces malicious auction initiators to pay compensation from their deposit via arbitration ruling.
    // The buyer cannot unilaterally claim a refund; arbitration ensures the seller's deposit is penalized.
    function claimNoShipRefund() external onlyHighestBidder noContract nonReentrant {
        if (auctionStatus != AuctionStatus.Ended) revert AuctionNotEnded();
        if (block.timestamp < uint256(auctionEndedAt) + SHIPPING_DEADLINE) revert TooEarly();

        auctionStatus = AuctionStatus.Resolved;

        address _bidder = highestBidder;
        uint256 _amount = highestBidTokenAmount;
        address _token = highestBidToken;

        _safeTransferToUser(_bidder, _amount, _token);

        uint256 compensation = _amount * 1000 / 10000;
        address depositAddr = depositFactory.getDeposit(seller);
        if (depositAddr != address(0) && compensation > 0) {
            IMerchantDeposit dep = IMerchantDeposit(depositAddr);
            uint256 frozen = dep.callerFrozenAmounts(address(this), _token);
            uint256 actualComp = compensation > frozen ? frozen : compensation;
            if (actualComp > 0) {
                dep.deductFromFrozen(actualComp, _bidder, _token);
            }
            dep.unfreezeAll();
        }

        settings.recordArbitration(seller);
        emit NoShipRefundClaimed(_bidder, _amount, compensation);
    }

    // ==================== Community Arbitration ====================

    function requestCommunityArbitration(string calldata evidence, string[] calldata _images) external noContract nonReentrant {
        if (msg.sender != highestBidder && msg.sender != seller) revert NotAuthorized();
        if (_images.length > 9) revert TooManyImages();
        if (auctionStatus != AuctionStatus.Shipped) revert AuctionNotShipped();

        address _bidder = highestBidder;
        uint256 _amount = highestBidTokenAmount;
        address _token = highestBidToken;
        IPlatformSettings _settings = settings;

        address arbFactory = _settings.getCommunityArbitrationFactory();

        // [H-14 fix]: Cache status before external calls (CEI pattern compliance)
        AuctionStatus cachedStatus = auctionStatus;
        bool isBuyerInitiated = (msg.sender == _bidder);

        CaseInitParams memory params = CaseInitParams({
            initiator: msg.sender,
            respondent: msg.sender == _bidder ? seller : _bidder,
            initiatorIsBuyer: msg.sender == _bidder,
            businessContract: address(this),
            orderId: orderId,
            businessType: BusinessType.Auction,
            disputeAmount: _amount,
            evidence: evidence,
            evidenceImages: _images
        });

        ICommunityArbitrationFactory(arbFactory).createCase(params, _token);

        if (msg.sender == _bidder) {
            uint256 buyerGuarantee = _amount * 1000 / 10000;
            if (buyerGuarantee > 0) {
                address df = _settings.getDepositFactory();
                address buyerDepAddr = IDepositFactory(df).getDeposit(_bidder);
                if (buyerDepAddr != address(0)) {
                    uint256 available = IMerchantDeposit(buyerDepAddr).getAvailableBalance(_token);
                    if (available >= buyerGuarantee) {
                        IMerchantDeposit(buyerDepAddr).authorizeProduct(address(this));
                        IMerchantDeposit(buyerDepAddr).freezeDeposit(buyerGuarantee, _token);
                        guaranteeFromDeposit = true;
                        guaranteeAmount = buyerGuarantee;
                        buyerGuaranteeDepositContract = buyerDepAddr;
                    } else {
                        if (!IERC20(_token).transferFrom(_bidder, address(this), buyerGuarantee)) revert TransferFailed();
                        guaranteeAmount = buyerGuarantee;
                    }
                } else {
                    if (!IERC20(_token).transferFrom(_bidder, address(this), buyerGuarantee)) revert TransferFailed();
                    guaranteeAmount = buyerGuarantee;
                }
            }
        }

        // [H-14 fix]: Update state after all external interactions (CEI pattern)
        statusBeforeArbitration = cachedStatus;
        auctionStatus = AuctionStatus.Arbitrating;
        arbitrationInitiatedByBuyer = isBuyerInitiated;

        IAuctionFactory(auctionFactory).disputeCreated(address(this));
        emit ArbitrationRequested(msg.sender);
    }

    function communityResolveAuction(bool buyerWins, uint256 arbFee) external nonReentrant {
        IPlatformSettings _settings = settings;
        address arbFactory = _settings.getCommunityArbitrationFactory();
        if (!ICommunityArbitrationFactory(arbFactory).isFactoryCase(msg.sender)) revert NotFactoryCase();
        if (auctionStatus != AuctionStatus.Arbitrating) revert AuctionNotArbitrating();
        if (ICommunityArbitrationFactory(arbFactory).getCaseForBusiness(address(this), orderId) != msg.sender) revert NotFactoryCase();

        auctionStatus = AuctionStatus.Resolved;
        _settings.recordArbitration(seller);

        address _bidder = highestBidder;
        uint256 _amount = highestBidTokenAmount;
        address _token = highestBidToken;
        address depAddr = depositFactory.getDeposit(seller);

        if (buyerWins) {
            _safeTransferToUser(_bidder, _amount, _token);
            if (depAddr != address(0)) {
                IMerchantDeposit dep = IMerchantDeposit(depAddr);
                if (arbFee > 0) {
                    // Cap to the seller's actually-frozen amount. arbFee is derived from
                    // the (unbounded) winning bid; an over-bid could make it exceed the
                    // frozen deposit (sized to buyNowPrice/leverage) and revert the whole
                    // resolution, bricking the case. Deduct at most what is frozen.
                    // Freeze was done by this auction (address(this)); msg.sender is the case (recipient).
                    uint256 frozen = dep.callerFrozenAmounts(address(this), _token);
                    uint256 actualFee = arbFee > frozen ? frozen : arbFee;
                    if (actualFee > 0) {
                        dep.deductFromFrozen(actualFee, msg.sender, _token);
                    }
                }
                dep.unfreezeAll();
            }
            if (guaranteeFromDeposit && guaranteeAmount > 0) {
                if (buyerGuaranteeDepositContract != address(0)) {
                    IMerchantDeposit(buyerGuaranteeDepositContract).unfreezeDepositAmount(guaranteeAmount, _token);
                }
            } else if (guaranteeAmount > 0) {
                _safeTransferToUser(_bidder, guaranteeAmount, _token);
            }
            _settings.recordArbitrationPayout(seller, _token, arbFee);
        } else {
            // Seller wins: normal settlement + buyer's guarantee → case (loser pays)
            if (!settled) _settle();
            // Buyer is loser: forfeit guarantee to case regardless of who initiated
            if (guaranteeFromDeposit && guaranteeAmount > 0) {
                if (buyerGuaranteeDepositContract != address(0)) {
                    IMerchantDeposit(buyerGuaranteeDepositContract).deductFromFrozen(guaranteeAmount, msg.sender, _token);
                }
            } else if (guaranteeAmount > 0) {
                _safeTransferToUser(msg.sender, guaranteeAmount, _token);
            }
            _settings.recordArbitrationPayout(_bidder, _token, guaranteeAmount);
            if (depAddr != address(0)) {
                IMerchantDeposit(depAddr).unfreezeAll();
            }
        }

        IAuctionFactory(auctionFactory).disputeResolved(address(this));
    }

    /// @dev Internal settlement: deduct 10% fee, remainder to seller, fee distributed via invite referral
    function _settle() internal {
        _settleWithArbitrationFee(address(0), 0);
    }

    function _settleWithArbitrationFee(address caseAddr, uint256 arbFee) internal {
        if (settled) revert AlreadySettled();
        settled = true;
        _unfreezeDeposit();

        if (auctionStatus != AuctionStatus.Resolved) {
            auctionStatus = AuctionStatus.Completed;
        }

        uint256 _amount = highestBidTokenAmount;
        address _token = highestBidToken;
        IPlatformSettings _settings = settings;

        uint256 feeRate = _settings.getFeeRate(4);
        uint256 fee = _amount * feeRate / 10000;
        if (fee == 0 && feeRate > 0 && _amount > 0) fee = 1;
        uint256 sellerAmount = _amount - fee;
        uint256 caseFee = caseAddr == address(0) || arbFee == 0 ? 0 : (arbFee > fee ? fee : arbFee);
        uint256 inviteFee = fee - caseFee;

        _safeTransferToUser(seller, sellerAmount, _token);

        if (caseFee > 0) {
            if (!IERC20(_token).transfer(caseAddr, caseFee)) revert TransferFailed();
        }

        if (inviteFee > 0) {
            if (!IERC20(_token).transfer(address(inviteRegistry), inviteFee)) revert TransferFailed();
            inviteRegistry.distributeFee(seller, inviteFee, IERC20(_token));
            _settings.recordFee(inviteFee, _token);
        }

        _settings.recordOrder(seller);
        _settings.recordSettlement(seller, _token, sellerAmount, _amount);
        emit Settled(sellerAmount, fee, _token);
    }

    function _unfreezeDeposit() internal {
        address depositAddr = depositFactory.getDeposit(seller);
        if (depositAddr != address(0)) {
            IMerchantDeposit(depositAddr).unfreezeAll();
        }
    }

    // ==================== Query Functions ====================

    function getAuctionInfo() external view returns (
        address seller_,
        string memory title_,
        string memory description_,
        string[] memory images_,
        uint256 startPrice_,
        uint256 buyNowPrice_,
        uint256 minBidIncrement_
    ) {
        seller_ = seller;
        title_ = title;
        description_ = description;
        images_ = images;
        startPrice_ = startPrice;
        buyNowPrice_ = buyNowPrice;
        minBidIncrement_ = minBidIncrement;
    }

    function getAuctionBidInfo() external view returns (
        uint256 startTime_,
        uint256 endTime_,
        AuctionStatus status_,
        address highestBidder_,
        uint256 highestBid_,
        uint256 bidCount_,
        bytes16 orderId_
    ) {
        startTime_ = startTime;
        endTime_ = endTime;
        status_ = auctionStatus;
        highestBidder_ = highestBidder;
        highestBid_ = highestBid;
        bidCount_ = bidCount;
        orderId_ = orderId;
    }

    function getMinNextBid() external view returns (uint256) {
        if (highestBid == 0) return startPrice;
        return highestBid + minBidIncrement;
    }

    function getShippingInfo() external view returns (string memory _trackingNumber, string memory _shippingAddress) {
        _trackingNumber = trackingNumber;
        _shippingAddress = shippingAddress;
    }

    /// @notice Get auction payment token (used for frontend badge display)
    function getPaymentToken() external view returns (address) {
        return paymentToken;
    }

    // ==================== Safe Transfer ====================

    function _safeTransferToUser(address to, uint256 amount, address token) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            pendingWithdrawals[token][to] += amount;
            emit TransferPending(to, token, amount);
        }
    }

    function claimPending(address token) external nonReentrant {
        uint256 amount = pendingWithdrawals[token][msg.sender];
        if (amount == 0) revert NoBalance();
        pendingWithdrawals[token][msg.sender] = 0;
        if (!IERC20(token).transfer(msg.sender, amount)) revert TransferFailed();
    }
}
