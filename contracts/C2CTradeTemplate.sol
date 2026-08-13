// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #7: C2CTradeTemplate — C2C Trade Template Contract
 * Responsibility: Manage a single C2C trade (dual deposit, fiat confirmation, Dispute Resolution)
 * Fee: 0.2% (deducted from trade amount, fee rate configured by platform settings contract)
 * Deployment: Used as a template, cloned by C2CFactory via EIP-1167 minimal proxy
 *
 * Trade flow:
 *   1. C2CFactory.createTrade() clones this contract and initializes it
 *   2. If seller requires buyer deposit -> status is Created, buyer must deposit first
 *   3. After buyer deposits (or no deposit required) -> status is AwaitingPayment
 *   4. After buyer pays fiat offline, calls confirmPayment -> status is PaymentConfirmed
 *   5. Seller confirms receipt by calling confirmReceived -> trade completes, USDT released to buyer
 *   6. If seller fails to confirm within timeout, buyer can force-claim (buyerClaimTimeout)
 *   7. Only seller can initiate community arbitration (with 10% deposit)
 */

import "./interfaces/Interfaces.sol";
import "./C2CSellOrderTemplate.sol";

/// @title C2CTradeTemplate - C2C Trade Escrow (EIP-1167 Clone)
/// @author WEB3GUARANTEE
/// @notice Manages a single C2C trade lifecycle: deposit, fiat payment confirmation, dispute resolution
contract C2CTradeTemplate {

    // ==================== Anti-Contract Call ====================

    /// @dev Reject unauthorized contract calls; only EOA or whitelisted contract wallets allowed
    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // Audit note [I-03]: Using uint256(1->2->1) instead of bool is best practice for EIP-1167 clones.
    // Clone contract storage defaults to 0; bool default false cannot distinguish "uninitialized" from "unlocked",
    // whereas uint256 is set from 0->1 in initialize(), ensuring nonReentrant works correctly in clones.
    // Audit note [M-01]: _locked initial value is 0, initialize() sets it to 1.
    // Even if a clone does not call initialize(), all business functions will fail due to buyer==address(0) checks,
    // and the factory calls initialize() in the same transaction immediately after create, so there is no uninitialized window.
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

    /// Buyer address
    address public buyer;

    /// Seller address
    address public seller;

    /// Associated sell order contract instance (for locking/unlocking/releasing token)
    C2CSellOrderTemplate public sellOrderContract;

    /// Associated buy order contract address (for buy-order trades)
    address public buyOrderContract;

    /// Whether this trade is a buy-order trade (seller deposits USDT into trade contract directly)
    bool public isBuyOrderTrade;

    /// Whether this trade's community dispute triggered a freeze of the buyer's active buy orders
    /// (only set for post-completion buy-order disputes). Ensures the buyer's arbitration counter is
    /// decremented exactly once, and only for trades that actually incremented it.
    bool public buyerBuyOrdersFrozen;

    /// Dual payment channel: payment token used for this trade (inherited from sellOrder.paymentToken)
    address public paymentToken;

    /// Trade amount (USDT smallest precision)
    uint256 public tokenAmount;

    /// Dual payment channel: whether this trade went through arbitration/dispute (for recordC2CTrade hadDispute field)
    bool public hadDispute;

    /// Fiat unit price (precision 1e6), inherited from sell order
    uint256 public price;

    /// Whether buyer deposit is required
    bool public requireBuyerDeposit;

    /// Buyer deposit rate (basis points, 10000=100%), e.g. 1000 means 10% of trade amount
    uint256 public buyerDepositRate;

    /// Buyer payment deadline (Unix timestamp), seller can cancel trade after timeout
    uint256 public paymentDeadline;

    /// Current trade status (Created/AwaitingPayment/PaymentConfirmed/Completed/Cancelled/Disputed/Resolved)
    C2CTradeStatus public status;

    /// Whether buyer has paid the deposit
    bool public buyerDepositPaid;

    /// Platform settings contract interface (for fee rates, platform wallet, admin verification, etc.)
    IPlatformSettings public settings;

    /// Cooldown manager contract address (for deposit escrow and cooldown period control)
    address public cooldownManager;

    /// C2C factory contract address (for dispute callbacks)
    address public c2cFactory;

    /// Invite registry contract interface (fee distribution along referral chain)
    IInviteRegistry public inviteRegistry;

    /// Unique identifier for this trade (generated during initialization)
    bytes16 public orderId;

    /// Pending withdrawal balance stored when transfer fails
    mapping(address => uint256) public pendingWithdrawals;

    /// Timestamp when trade completed (for arbitration window)
    uint64 public confirmReceiveTime;

    /// Whether the current community dispute was opened after the trade had already completed
    bool public communityDisputeAfterCompleted;

    /// Active community arbitration case for this trade
    address public communityCase;

    /// Seller arbitration deposit source: true=frozen from merchant deposit contract, false=transferFrom wallet to case
    bool public sellerDepositFromMerchant;

    /// Seller arbitration deposit amount
    uint256 public sellerArbitrationDeposit;

    /// Seller's MerchantDeposit contract address (saved at dispute time to avoid factory mismatch on resolve)
    address public sellerDepositContract;

    /// Buyer guarantee amount (10% of tokenAmount, frozen from buyer's MD at arbitration initiation)
    uint256 public buyerGuaranteeAmount;

    /// Whether buyer guarantee was frozen from merchant deposit
    bool public buyerGuaranteeFromDeposit;

    /// Buyer's MerchantDeposit contract address for guarantee
    address public buyerGuaranteeDepositContract;

    /// Force-claim countdown after payment confirmed: test 30 minutes (production: 24 hours)
    uint256 public constant CONFIRM_RECEIVE_TIMEOUT = 24 hours; // production

    // ==================== Events ====================

    /// Emitted when trade is created
    event TradeCreated(bytes16 indexed orderId, address buyer, address seller, uint256 amount);

    /// Emitted when buyer pays the deposit
    event BuyerDepositPaid(uint256 amount);

    /// Emitted when buyer confirms fiat payment
    event PaymentConfirmed();

    /// Emitted when trade completes, records buyer's actual USDT received and platform fee
    event TradeCompleted(uint256 buyerReceived, uint256 fee);

    /// Emitted when trade is cancelled, records cancellation reason
    event TradeCancelled(string reason);

    /// Emitted when dispute is raised, records initiator and evidence
    event DisputeRaised(address by, string evidence);

    /// Emitted when dispute is resolved, records the winner
    event DisputeResolved(address winner);
    event TransferPending(address indexed to, uint256 amount);

    // ==================== Modifiers ====================

    /// Only buyer can call
    modifier onlyBuyer() { if (msg.sender != buyer) revert NotBuyer(); _; }

    /// Only seller can call
    modifier onlySeller() { if (msg.sender != seller) revert NotSeller(); _; }

    // ==================== Initialization ====================

    /**
     * @notice Initialize trade contract (replaces Constructor, used in clone proxy pattern)
     * @dev Can only be called once, called by C2CFactory.createTrade() immediately after cloning
     *      Initial status depends on whether buyer deposit is required:
     *      - Deposit required: Created (waiting for buyer to deposit)
     *      - No deposit required: AwaitingPayment (directly waiting for buyer payment)
     * @param p Trade initialization parameter struct
     */
    function initialize(TradeInitParams calldata p) external {
        if (initialized) revert AlreadyInit();
        if (p.paymentToken == address(0)) revert PaymentTokenRequired();
        initialized = true;
        _locked = 1;
        buyer = p.buyer;
        seller = p.seller;
        if (p.buyOrder != address(0)) {
            isBuyOrderTrade = true;
            buyOrderContract = p.buyOrder;
        } else {
            sellOrderContract = C2CSellOrderTemplate(p.sellOrder);
        }
        paymentToken = p.paymentToken;
        tokenAmount = p.tokenAmount;
        price = p.price;
        requireBuyerDeposit = p.requireBuyerDeposit;
        buyerDepositRate = p.buyerDepositRate;
        paymentDeadline = p.paymentDeadline;
        settings = IPlatformSettings(p.settings);
        cooldownManager = p.cooldownManager;
        inviteRegistry = IInviteRegistry(p.inviteRegistry);
        c2cFactory = msg.sender;

        if (p.requireBuyerDeposit) {
            status = C2CTradeStatus.Created;
        } else {
            status = C2CTradeStatus.AwaitingPayment;
        }
        orderId = bytes16(keccak256(abi.encodePacked(address(this), p.buyer, block.timestamp)));
        emit TradeCreated(orderId, p.buyer, p.seller, p.tokenAmount);
    }

    // ==================== Buyer Operations ====================

    /**
     * @notice Factory sets buyer deposit as paid (called atomically during createTrade)
     * @dev Only the factory can call this; transitions status from Created to AwaitingPayment
     */
    function factorySetDepositPaid() external {
        if (msg.sender != c2cFactory) revert NotFactory();
        if (status != C2CTradeStatus.Created) revert WrongStatus();
        buyerDepositPaid = true;
        status = C2CTradeStatus.AwaitingPayment;
        emit BuyerDepositPaid(tokenAmount * buyerDepositRate / 10000);
    }

    /**
     * @notice Buyer pays the deposit
     * @dev Only buyer can call; only available in Created status (awaiting deposit)
     *      Buyer must approve this contract address for sufficient USDT allowance beforehand
     *      Deposit is transferred from buyer's wallet into this trade contract for escrow
     *      After deposit, status changes to AwaitingPayment (awaiting fiat payment)
     */
    function depositBuyerCollateral() external onlyBuyer noContract nonReentrant {
        if (status != C2CTradeStatus.Created) revert WrongStatus();
        if (block.timestamp > paymentDeadline) revert PaymentDeadlineExceeded();
        if (!requireBuyerDeposit) revert NoDepositRequired();
        uint256 depositAmt = tokenAmount * buyerDepositRate / 10000;
        // Dual payment channel: buyer deposit token matches the order's paymentToken
        ICooldownManager(cooldownManager).receiveDeposit(msg.sender, depositAmt, paymentToken);
        buyerDepositPaid = true;
        status = C2CTradeStatus.AwaitingPayment;
        emit BuyerDepositPaid(depositAmt);
    }

    /**
     * @notice Buyer confirms fiat payment has been made
     * @dev Only buyer can call; only available in AwaitingPayment status
     *      This is an on-chain declaration that the buyer has paid the seller via offline channels
     *      After confirmation, status changes to PaymentConfirmed, awaiting seller to confirm receipt
     */
    function confirmPayment() external onlyBuyer noContract {
        if (status != C2CTradeStatus.AwaitingPayment) revert WrongStatus();
        if (block.timestamp > paymentDeadline) revert PaymentDeadlineExceeded();
        status = C2CTradeStatus.PaymentConfirmed;
        paymentDeadline = block.timestamp + CONFIRM_RECEIVE_TIMEOUT;
        IC2CFactory(c2cFactory).tradeActivityRefresh(seller);
        emit PaymentConfirmed();
    }

    // ==================== Seller Operations ====================

    /**
     * @notice Seller confirms fiat payment received, completing the trade
     * @dev Only seller can call; only available in PaymentConfirmed status
     *      After confirmation, triggers _completeTrade() internal function for USDT release and fee deduction
     *      Audit note: _completeTrade is an internal function, covered by this function's nonReentrant protection
     */
    function confirmReceived() external onlySeller noContract nonReentrant {
        if (status != C2CTradeStatus.PaymentConfirmed) revert WrongStatus();
        IC2CFactory(c2cFactory).tradeActivityRefresh(seller);
        _completeTrade();
    }

    /**
     * @notice Buyer cancels the trade
     * @dev Only buyer can call; available in AwaitingPayment or PaymentConfirmed status
     *      After cancellation: locked USDT in sell order is unlocked back to available balance
     *      If buyer has paid deposit, deposit is refunded to buyer
     */
    function buyerCancel() external onlyBuyer noContract nonReentrant {
        if (status != C2CTradeStatus.AwaitingPayment && status != C2CTradeStatus.PaymentConfirmed) revert WrongStatus();
        status = C2CTradeStatus.Cancelled;
        _returnToSeller();
        address _cm = cooldownManager;
        if (buyerDepositPaid) {
            ICooldownManager(_cm).releaseDeposit(buyer, tokenAmount * buyerDepositRate / 10000, paymentToken);
        }
        ICooldownManager(_cm).tradeEnded(buyer);
        ICooldownManager(_cm).tradeEnded(seller);
        IC2CFactory(c2cFactory).tradeActivityRefresh(seller);
        emit TradeCancelled("Cancelled by buyer");
    }

    function cancelCreatedTrade() external onlyBuyer noContract nonReentrant {
        if (status != C2CTradeStatus.Created) revert WrongStatus();
        status = C2CTradeStatus.Cancelled;
        _returnToSeller();
        address _cm2 = cooldownManager;
        ICooldownManager(_cm2).tradeEnded(buyer);
        ICooldownManager(_cm2).tradeEnded(seller);
        emit TradeCancelled("Created cancelled by buyer");
    }

    /**
     * @notice Buyer claims USDT after seller fails to confirm within CONFIRM_RECEIVE_TIMEOUT
     * @dev Only buyer can call; only available in PaymentConfirmed status after deadline expires
     *      Same effect as confirmReceived — trade completes, USDT released to buyer
     */
    function buyerClaimTimeout() external onlyBuyer noContract nonReentrant {
        if (status != C2CTradeStatus.PaymentConfirmed) revert WrongStatus();
        if (block.timestamp <= paymentDeadline) revert TooEarly();
        IC2CFactory(c2cFactory).tradeActivityRefresh(seller);
        _completeTrade();
    }

    function sellerTimeoutCancel() external onlySeller noContract nonReentrant {
        if (status != C2CTradeStatus.Created && status != C2CTradeStatus.AwaitingPayment) revert WrongStatus();
        if (block.timestamp <= paymentDeadline) revert TooEarly();
        status = C2CTradeStatus.Cancelled;
        _returnToSeller();
        address _cm = cooldownManager;
        if (buyerDepositPaid) {
            ICooldownManager(_cm).releaseDeposit(buyer, tokenAmount * buyerDepositRate / 10000, paymentToken);
        }
        ICooldownManager(_cm).tradeEnded(buyer);
        ICooldownManager(_cm).tradeEnded(seller);
        IC2CFactory(c2cFactory).tradeActivityRefresh(seller);
        emit TradeCancelled("Seller timeout cancel");
    }

    // [REMOVED] Admin trade-level force-cancel.
    // An admin must NOT be able to force-cancel an in-progress trade at the contract level.
    // The previous adminCancel() blindly did IERC20.transfer(destination, tokenAmount) from this
    // trade contract regardless of trade type: for sell-order trades the USDT is escrowed in the
    // sell-order contract (not here) so it always reverted, and for buy-order trades it never
    // called buyOrderTradeUnlock() so the buy order's lockedAmount was stranded (capacity shrank,
    // the buy order could never be cancelled, and its deposit was locked forever).
    // In-progress trades resolve only through their legitimate paths: buyer/seller cancel, timeout
    // cancel/claim, confirmReceived, or community-dispute arbitration. Content moderation happens at
    // the ORDER level (adminCancel on the sell/buy order, which is gated on lockedAmount == 0 and
    // therefore never disturbs an in-flight trade).

    // ==================== Seller Community Arbitration ====================

    function requestCommunityDispute(string calldata evidence, string[] calldata _images) external onlySeller noContract nonReentrant {
        if (_images.length > 9) revert TooManyImages();
        address arbFactory = settings.getCommunityArbitrationFactory();
        if (arbFactory == address(0)) revert ZeroAddress();

        // Both sell-order and buy-order trades: PaymentConfirmed or Completed can initiate arbitration
        // (seller may need to arbitrate post-completion if bank account frozen)
        if (status != C2CTradeStatus.PaymentConfirmed && status != C2CTradeStatus.Completed) revert WrongStatus();

        bool wasCompleted = (status == C2CTradeStatus.Completed);
        communityDisputeAfterCompleted = wasCompleted;
        status = C2CTradeStatus.Disputed;
        hadDispute = true;

        CaseInitParams memory params = CaseInitParams({
            initiator: seller,
            respondent: buyer,
            initiatorIsBuyer: false,
            businessContract: address(this),
            orderId: orderId,
            businessType: BusinessType.C2C,
            disputeAmount: tokenAmount,
            evidence: evidence,
            evidenceImages: _images
        });

        address caseAddr = ICommunityArbitrationFactory(arbFactory).createCase(params, paymentToken);
        communityCase = caseAddr;

        // Seller pays 10% deposit: MD if sufficient, otherwise transferFrom wallet
        uint256 sellerGuarantee = tokenAmount * 1000 / 10000;
        if (sellerGuarantee > 0) {
            address df = settings.getDepositFactory();
            address depAddr = IDepositFactory(df).getDeposit(seller);
            if (depAddr != address(0) && IMerchantDeposit(depAddr).getAvailableBalance(paymentToken) >= sellerGuarantee) {
                IMerchantDeposit(depAddr).authorizeProduct(address(this));
                IMerchantDeposit(depAddr).freezeDeposit(sellerGuarantee, paymentToken);
                sellerDepositFromMerchant = true;
                sellerArbitrationDeposit = sellerGuarantee;
                sellerDepositContract = depAddr;
            } else {
                if (!IERC20(paymentToken).transferFrom(seller, address(this), sellerGuarantee)) revert TransferFailed();
                sellerDepositFromMerchant = false;
                sellerArbitrationDeposit = sellerGuarantee;
            }
        }

        // Post-completion buy-order dispute: freeze down the buyer's active buy orders' available
        // capacity FIRST. This releases their available-slice deposit back to MD available balance,
        // making the buyerGuarantee freeze below more likely to succeed from MD directly (and the
        // seizeForArbitration fallback a no-op via its locked floor). In-flight trades are untouched.
        if (wasCompleted && isBuyOrderTrade) {
            IC2CFactory(c2cFactory).freezeBuyerActiveBuyOrders(buyer);
            buyerBuyOrdersFrozen = true;
        }

        // Freeze buyer's guarantee from MD (buyer is respondent, freeze what's available)
        // Pre-completion: only 10% arb fee (dispute funds still locked in sell order)
        // Post-completion: tokenAmount + 10% arb fee (buyer already received the USDT)
        uint256 arbFeeG = tokenAmount * 1000 / 10000; // 10%
        uint256 buyerG = wasCompleted ? (tokenAmount + arbFeeG) : arbFeeG;
        if (buyerG > 0) {
            address df = settings.getDepositFactory();
            address buyerDep = IDepositFactory(df).getDeposit(buyer);
            if (buyerDep != address(0)) {
                uint256 avail = IMerchantDeposit(buyerDep).getAvailableBalance(paymentToken);
                uint256 actualG = avail >= buyerG ? buyerG : avail;
                if (actualG > 0) {
                    IMerchantDeposit(buyerDep).authorizeProduct(address(this));
                    IMerchantDeposit(buyerDep).freezeDeposit(actualG, paymentToken);
                    buyerGuaranteeFromDeposit = true;
                    buyerGuaranteeDepositContract = buyerDep;
                    buyerGuaranteeAmount = actualG;
                }
                // Post-completion buy-order trade: if available was insufficient, seize from BuyOrder's frozen allocation
                if (wasCompleted && isBuyOrderTrade && actualG < buyerG && buyOrderContract != address(0)) {
                    uint256 shortfall = buyerG - actualG;
                    uint256 seized = IC2CBuyOrder(buyOrderContract).seizeForArbitration(shortfall, paymentToken);
                    if (seized > 0) {
                        if (!buyerGuaranteeFromDeposit) {
                            IMerchantDeposit(buyerDep).authorizeProduct(address(this));
                            buyerGuaranteeFromDeposit = true;
                            buyerGuaranteeDepositContract = buyerDep;
                        }
                        buyerGuaranteeAmount += seized;
                    }
                }
            }
        }

        if (!wasCompleted) {
            address _cm = cooldownManager;
            ICooldownManager(_cm).disputeRaised(buyer);
            ICooldownManager(_cm).disputeRaised(seller);
        }
        IC2CFactory(c2cFactory).disputeCreated(address(this));
        emit DisputeRaised(seller, evidence);
    }

    function _collectSellerDepositFromWallet(uint256 amount, address) internal {
        sellerDepositFromMerchant = false;
        sellerArbitrationDeposit = amount;
        if (!IERC20(paymentToken).transferFrom(seller, address(this), amount)) revert TransferFailed();
    }

    function communityResolveDispute(address winner, uint256 arbFee) external nonReentrant {
        IPlatformSettings _settings = settings;
        address arbFactory = _settings.getCommunityArbitrationFactory();
        if (!ICommunityArbitrationFactory(arbFactory).isFactoryCase(msg.sender)) revert NotFactoryCase();
        if (ICommunityArbitrationFactory(arbFactory).getCaseForBusiness(address(this), orderId) != msg.sender) revert NotFactoryCase();
        if (status != C2CTradeStatus.Disputed) revert NotDisputed();

        bool wasCompleted = communityDisputeAfterCompleted;
        status = C2CTradeStatus.Resolved;
        communityDisputeAfterCompleted = false;
        communityCase = address(0);

        address depAddr = sellerDepositContract;
        address _cm = cooldownManager;

        if (winner != buyer && winner != seller) revert NotParty();
        if (winner == buyer) {
            if (!wasCompleted) {
                _releaseToTrade();
                uint256 feeRate = _settings.getFeeRate(3);
                uint256 fee = tokenAmount * feeRate / 10000;
                if (fee == 0 && feeRate > 0 && tokenAmount > 0) fee = 1;
                uint256 buyerReceived = tokenAmount - fee;
                _safeTransferToUser(buyer, buyerReceived);
                if (fee > 0) {
                    if (!IERC20(paymentToken).transfer(address(inviteRegistry), fee)) revert TransferFailed();
                    inviteRegistry.distributeFee(seller, fee, IERC20(paymentToken));
                    _settings.recordFee(fee, paymentToken);
                }
                _settings.recordOrder(seller);
                IC2CFactory(c2cFactory).recordC2CTrade(seller, buyer, paymentToken, tokenAmount, true);
            }
            if (sellerDepositFromMerchant && depAddr != address(0) && sellerArbitrationDeposit > 0) {
                IMerchantDeposit(depAddr).deductFromFrozen(sellerArbitrationDeposit, msg.sender, paymentToken);
            } else if (!sellerDepositFromMerchant && sellerArbitrationDeposit > 0) {
                _safeTransferToUser(msg.sender, sellerArbitrationDeposit);
            }
            if (buyerDepositPaid) {
                uint256 depAmt = tokenAmount * buyerDepositRate / 10000;
                if (depAmt > 0) {
                    ICooldownManager(_cm).releaseDeposit(buyer, depAmt, paymentToken);
                }
            }
            // Buyer wins: return buyer's frozen guarantee (winner doesn't pay)
            if (buyerGuaranteeFromDeposit && buyerGuaranteeAmount > 0) {
                IMerchantDeposit(buyerGuaranteeDepositContract).unfreezeDepositAmount(buyerGuaranteeAmount, paymentToken);
            }
            _settings.recordArbitrationPayout(seller, paymentToken, sellerArbitrationDeposit);
        } else {
            if (!wasCompleted) {
                _returnToSeller();
            }
            // Seller wins: return seller's arb deposit
            if (sellerDepositFromMerchant && depAddr != address(0) && sellerArbitrationDeposit > 0) {
                IMerchantDeposit(depAddr).unfreezeDepositAmount(sellerArbitrationDeposit, paymentToken);
            } else if (!sellerDepositFromMerchant && sellerArbitrationDeposit > 0) {
                _safeTransferToUser(seller, sellerArbitrationDeposit);
            }

            // Buyer loses: distribute buyer's frozen guarantee
            // Priority: arb fee → case first, remainder → seller
            if (buyerGuaranteeFromDeposit && buyerGuaranteeAmount > 0) {
                // NOTE: this is a locally-recomputed rate, NOT the `arbFee` parameter passed in by the
                // arbitration case. The guarantee-distribution branch ignores `arbFee` entirely and always
                // splits the frozen guarantee by this 10% rate, including on a tie (arbFee==0). Only the
                // buy-order branch below actually consumes the `arbFee` argument (as a tie flag).
                uint256 arbFeeFromGuarantee = tokenAmount * 1000 / 10000;
                if (wasCompleted) {
                    // Post-completion: frozen = min(tokenAmount + arbFee, available)
                    // Priority: arbFee to case first, rest to seller
                    uint256 toCase = buyerGuaranteeAmount >= arbFeeFromGuarantee ? arbFeeFromGuarantee : buyerGuaranteeAmount;
                    uint256 toSeller = buyerGuaranteeAmount - toCase;
                    if (toCase > 0) {
                        IMerchantDeposit(buyerGuaranteeDepositContract).deductFromFrozen(toCase, msg.sender, paymentToken);
                    }
                    if (toSeller > 0) {
                        IMerchantDeposit(buyerGuaranteeDepositContract).deductFromFrozen(toSeller, seller, paymentToken);
                    }
                    _settings.recordArbitrationPayout(buyer, paymentToken, toCase);
                    if (toSeller > 0) {
                        _settings.recordRefund(buyer, paymentToken, toSeller);
                    }
                } else {
                    // Pre-completion: guarantee = arbFee only → all to case
                    IMerchantDeposit(buyerGuaranteeDepositContract).deductFromFrozen(buyerGuaranteeAmount, msg.sender, paymentToken);
                    _settings.recordArbitrationPayout(buyer, paymentToken, buyerGuaranteeAmount);
                }
            }

            if (!wasCompleted) {
                // Pre-completion: buyer's C2C deposit handling (separate from MD guarantee)
                // Arb fee is covered FIRST by the buyer's frozen MD guarantee (already paid to case
                // above). The C2C deposit only tops up any SHORTFALL the MD guarantee left uncovered;
                // the remainder is refunded. If the MD guarantee already covers the full 10% fee, the
                // C2C deposit is returned to the buyer in full (no double-charging).
                if (buyerDepositPaid) {
                    uint256 depAmt = tokenAmount * buyerDepositRate / 10000;
                    if (depAmt > 0) {
                        uint256 arbFeeTarget = tokenAmount * 1000 / 10000; // 10% arbitration fee
                        uint256 alreadyPaid = buyerGuaranteeFromDeposit ? buyerGuaranteeAmount : 0;
                        uint256 shortfall = arbFeeTarget > alreadyPaid ? arbFeeTarget - alreadyPaid : 0;
                        uint256 penaltyAmt = depAmt <= shortfall ? depAmt : shortfall;
                        uint256 refundAmt = depAmt - penaltyAmt;
                        if (penaltyAmt > 0) {
                            ICooldownManager(_cm).penalizeToCase(buyer, msg.sender, penaltyAmt, paymentToken);
                        }
                        if (refundAmt > 0) {
                            ICooldownManager(_cm).releaseDeposit(buyer, refundAmt, paymentToken);
                        }
                    }
                } else if (isBuyOrderTrade && buyOrderContract != address(0) && arbFee > 0) {
                    // `arbFee > 0` is the ONLY place the passed-in arbFee parameter is used: it acts as a
                    // "not a tie" flag. The arbitration template passes arbFee==0 on a tie (_handleTie) and a
                    // non-zero standard fee on a real seller win, so a tie correctly skips forfeiting the
                    // buyer's buy-order deposit. The forfeit amount itself is computed inside the buy order.
                    //
                    // Buy-order trades have no separate C2C deposit (buyerDepositPaid==false), so the buyer's
                    // buy-order frozen deposit plays the same role the C2C deposit does above: it may only
                    // cover the arbitration-fee SHORTFALL the MD guarantee left uncovered. Anything beyond the
                    // shortfall is unfrozen back to the buyer (no double-charging of the 10% fee).
                    uint256 arbFeeTarget = tokenAmount * 1000 / 10000; // 10% arbitration fee
                    uint256 alreadyPaid = buyerGuaranteeFromDeposit ? buyerGuaranteeAmount : 0;
                    uint256 shortfall = arbFeeTarget > alreadyPaid ? arbFeeTarget - alreadyPaid : 0;
                    IC2CBuyOrder(buyOrderContract).forfeitDepositToCase(tokenAmount, msg.sender, shortfall);
                }
            }
        }

        if (!wasCompleted) {
            ICooldownManager(_cm).tradeEnded(buyer);
            ICooldownManager(_cm).tradeEnded(seller);
            // [FIX] Clear the hasDispute flag from the trade contract (an authorized caller) rather
            // than relying on the arbitration case contract's disputeResolved() call — the case clone
            // is never added to CooldownManager.authorizedCallers, so its call reverts and is silently
            // swallowed by a try/catch, leaving hasDispute stuck true forever and permanently bricking
            // withdrawDeposit for both parties. disputeRaised() is only ever called here on !wasCompleted,
            // so the clear mirrors it exactly. The trade clone IS authorized, so this always succeeds.
            ICooldownManager(_cm).disputeResolved(buyer);
            ICooldownManager(_cm).disputeResolved(seller);
        }
        // Release the buyer's buy-order arbitration hold so they can create buy orders again.
        if (buyerBuyOrdersFrozen) {
            IC2CFactory(c2cFactory).endBuyOrderArbitration(buyer);
            buyerBuyOrdersFrozen = false;
        }
        IC2CFactory(c2cFactory).disputeResolved(address(this));
        emit DisputeResolved(winner);
    }

    function _returnToSeller() internal {
        if (isBuyOrderTrade) {
            if (!IERC20(paymentToken).transfer(seller, tokenAmount)) revert TransferFailed();
            // Release the buy order's locked amount so its available capacity is restored.
            IC2CFactory(c2cFactory).buyOrderTradeUnlock(buyOrderContract, tokenAmount);
        } else {
            sellOrderContract.unlockAmount(tokenAmount);
        }
    }

    function _releaseToTrade() internal {
        if (isBuyOrderTrade) {
            IC2CFactory(c2cFactory).buyOrderTradeFilled(buyOrderContract, tokenAmount);
        } else {
            sellOrderContract.releaseAmount(tokenAmount, address(this));
        }
    }

    /**
     * @notice Internal logic for completing a trade
     * @dev Performs the following steps:
     *      1. Set status to Completed
     *      2. Get C2C fee rate (type 3) from platform settings, calculate fee (0.2%)
     *      3. Release USDT from sell order contract to this trade contract
     *      4. After deducting fee, transfer remaining USDT to buyer
     *      5. Transfer fee to platform wallet
     *      6. If buyer paid deposit, refund deposit to buyer
     *      7. Record seller's completed order in platform settings (for reputation system)
     */
    function _completeTrade() internal {
        status = C2CTradeStatus.Completed;
        confirmReceiveTime = uint64(block.timestamp);
        uint256 feeRate = settings.getFeeRate(3); // C2C = 3
        uint256 fee = tokenAmount * feeRate / 10000;
        // [H-09 fix]: Check for zero-amount bypass BEFORE multiplication
        if (tokenAmount == 0) revert ZeroAmount();
        if (fee == 0 && feeRate > 0 && tokenAmount > 0) fee = 1;
        uint256 buyerReceived = tokenAmount - fee;

        _releaseToTrade();
        _safeTransferToUser(buyer, buyerReceived);
        if (fee > 0) {
            if (!IERC20(paymentToken).transfer(address(inviteRegistry), fee)) revert TransferFailed();
            inviteRegistry.distributeFee(seller, fee, IERC20(paymentToken));
            settings.recordFee(fee, paymentToken);
        }
        address _cm = cooldownManager;
        if (buyerDepositPaid) {
            ICooldownManager(_cm).releaseDeposit(buyer, tokenAmount * buyerDepositRate / 10000, paymentToken);
        }
        ICooldownManager(_cm).tradeEnded(buyer);
        ICooldownManager(_cm).tradeEnded(seller);
        settings.recordOrder(seller);
        IC2CFactory(c2cFactory).recordC2CTrade(seller, buyer, paymentToken, tokenAmount, hadDispute);
        emit TradeCompleted(buyerReceived, fee);
    }

    // ==================== Query Functions ====================

    /**
     * @notice Get trade basic information
     * @return Buyer address, seller address, USDT amount, unit price, trade status, order ID
     */
    /// @notice Get trade basic info (dual payment channel: return value includes paymentToken)
    function getTradeInfo() external view returns (
        address buyer_, address seller_, address paymentToken_, uint256 tokenAmount_,
        uint256 price_, C2CTradeStatus status_, bytes16 orderId_
    ) {
        return (buyer, seller, paymentToken, tokenAmount, price, status, orderId);
    }

    function getTradeDepositInfo() external view returns (
        bool, uint256, bool, uint256
    ) {
        uint256 depositAmt = tokenAmount * buyerDepositRate / 10000;
        return (requireBuyerDeposit, buyerDepositRate, buyerDepositPaid, depositAmt);
    }

    /// @notice Get language for arbitration language inheritance.
    /// @dev Buy-order trades have sellOrderContract == address(0); read from the buy order instead.
    function getLanguage() external view returns (string memory) {
        if (isBuyOrderTrade) {
            return IC2CBuyOrder(buyOrderContract).language();
        }
        return sellOrderContract.language();
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

    function claimPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoBalance();
        pendingWithdrawals[msg.sender] = 0;
        if (!IERC20(paymentToken).transfer(msg.sender, amount)) revert TransferFailed();
    }
}

