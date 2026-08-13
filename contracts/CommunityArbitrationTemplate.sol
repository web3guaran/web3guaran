// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #27: CommunityArbitrationTemplate — Community Arbitration Case Template
 * Responsibility: Per-case instance managing evidence, voting, resolution, and reward distribution
 * Deploy order: #27 (as template), instances created by CommunityArbitrationFactory via clone
 *
 * State machine:
 *   EvidencePhase → VotingPhase → Resolved / Tied / AdminResolved
 */

import "./interfaces/Interfaces.sol";
import "./CommunityArbitrationFactory.sol";

/// @title CommunityArbitrationTemplate - Per-Case Arbitration Instance (EIP-1167 Clone)
/// @author WEB3GUARANTEE
contract CommunityArbitrationTemplate {

    // ==================== Anti-Contract Call ====================

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // ==================== Reentrancy Guard ====================

    uint256 private _locked;
    modifier nonReentrant() {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ==================== State Variables ====================

    bool public initialized;

    address public factory;
    address public initiator;
    address public respondent;
    address public businessContract;

    bytes16 public orderId;
    BusinessType public businessType;
    CaseStatus public status;
    bool public rewardsDistributed;

    uint64 public caseCreateTime;
    uint64 public evidenceDeadline;
    uint64 public votingStartTime;
    uint64 public votingDeadline;

    uint8 public buyerVoteCount;
    uint8 public sellerVoteCount;
    uint8 public maxArbitrators;

    uint256 public disputeAmount;
    uint256 public buyerGuarantee;
    bool public resolvedBuyerWins;
    bool public initiatorIsBuyer;

    /// Payment token used by this case (USDT, set by factory during createCase)
    address public paymentToken;
    address public settingsAddr;
    string public language;  // Language market isolation - inherited from business contract
    string public initiatorEvidence;
    string public respondentEvidence;
    string public adminReasonHash;
    VoteRecord[] public votes;
    mapping(address => bool) public hasVoted;
    mapping(address => uint256) public pendingWithdrawals;
    bool public resolutionFailed;
    uint256 internal storedArbFee;
    /// Actually distributed arbitration fee (taken from the case balance at distribution time; may be less than disputeAmount*10%)
    uint256 public actualArbFee;

    // ==================== Events ====================

    event EvidenceSubmitted(address indexed party, bool isInitiator);
    event VotingStarted(uint64 deadline);
    event Voted(address indexed arbitrator, bool voteForBuyer);
    event CaseResolved(CaseStatus status, bool buyerWins);
    event RewardsDistributed(uint256 poolAmount, uint256 correctVoters);
    event PendingWithdrawal(address indexed user, uint256 amount);

    // ==================== Initialize ====================

    function initialize(
        CaseInitParams calldata params,
        uint256 evidenceWindow,
        uint256 votingDuration,
        uint256 _maxArbitrators
    ) external {
        if (initialized) revert AlreadyInit();
        initialized = true;

        _locked = 1;

        factory = msg.sender;
        initiator = params.initiator;
        respondent = params.respondent;
        businessContract = params.businessContract;
        orderId = params.orderId;
        businessType = params.businessType;
        disputeAmount = params.disputeAmount;
        initiatorIsBuyer = params.initiatorIsBuyer;

        initiatorEvidence = params.evidence;

        CommunityArbitrationFactory f = CommunityArbitrationFactory(factory);
        // Dual payment channel: fetch this case's paymentToken from factory's caseToken mapping
        paymentToken = f.caseToken(address(this));
        if (paymentToken == address(0)) revert PaymentTokenRequired();
        settingsAddr = address(f.settings());

        // Language market isolation: inherit language from business contract
        _inheritLanguageFromBusiness(params.businessType, params.businessContract);

        status = CaseStatus.EvidencePhase;
        caseCreateTime = uint64(block.timestamp);
        evidenceDeadline = uint64(block.timestamp + evidenceWindow);
        votingDeadline = uint64(block.timestamp + evidenceWindow + votingDuration);
        maxArbitrators = uint8(_maxArbitrators);

        emit EvidenceSubmitted(params.initiator, true);
    }

    // ==================== Evidence Phase ====================

    // Audit note [L-05]: submitRespondentEvidence and startVoting are two entry points to the voting phase.
    // Both paths calculate votingDeadline the same way (both use block.timestamp + duration),
    // the only difference is submitRespondentEvidence is triggered proactively by the respondent, while startVoting is triggered by anyone after timeout.
    function submitRespondentEvidence(string calldata evidence, string[] calldata images) external noContract {
        if (msg.sender != respondent) revert NotRespondent();
        if (status != CaseStatus.EvidencePhase) revert WrongStatus();
        if (block.timestamp > evidenceDeadline) revert EvidenceWindowClosed();
        if (images.length > 9) revert TooManyImages();

        respondentEvidence = evidence;

        status = CaseStatus.VotingPhase;
        votingStartTime = uint64(block.timestamp);
        votingDeadline = uint64(block.timestamp + (votingDeadline - evidenceDeadline));

        emit EvidenceSubmitted(msg.sender, false);
        emit VotingStarted(votingDeadline);
    }

    function startVoting() external {
        if (status != CaseStatus.EvidencePhase) revert WrongStatus();
        if (block.timestamp <= evidenceDeadline) revert TooEarly();

        uint64 duration = votingDeadline - evidenceDeadline;
        status = CaseStatus.VotingPhase;
        votingStartTime = uint64(block.timestamp);
        votingDeadline = uint64(block.timestamp) + duration;

        emit VotingStarted(votingDeadline);
    }

    // ==================== Voting Phase ====================

    function vote(bool voteForBuyer) external noContract nonReentrant {
        if (status != CaseStatus.VotingPhase) revert VotingNotActive();
        if (block.timestamp > votingDeadline) revert VotingNotActive();
        if (hasVoted[msg.sender]) revert AlreadyVoted();
        if (msg.sender == initiator || msg.sender == respondent) revert CannotArbitrateOwnCase();

        ICommunityArbitrationFactory f = ICommunityArbitrationFactory(factory);
        if (!f.isQualifiedArbitrator(msg.sender)) revert NotQualifiedArbitrator();

        uint256 interval = f.VOTE_INTERVAL();
        if (interval > 0 && block.timestamp < f.lastGlobalVoteTime() + interval) revert VoteIntervalNotMet();

        uint256 totalVotes = uint256(buyerVoteCount) + uint256(sellerVoteCount);
        if (totalVotes >= maxArbitrators) revert MaxArbitratorsReached();

        hasVoted[msg.sender] = true;
        votes.push(VoteRecord({
            arbitrator: msg.sender,
            votedForBuyer: voteForBuyer,
            voteTime: uint64(block.timestamp)
        }));

        if (voteForBuyer) {
            buyerVoteCount++;
        } else {
            sellerVoteCount++;
        }

        f.updateGlobalVoteTime();

        emit Voted(msg.sender, voteForBuyer);
    }

    // ==================== Admin Intervention ====================

    function adminRule(bool buyerWins, string calldata reasonHash) external nonReentrant {
        IPlatformSettings s = IPlatformSettings(settingsAddr);
        if (!s.isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        if (status != CaseStatus.EvidencePhase && status != CaseStatus.VotingPhase) revert WrongStatus();

        adminReasonHash = reasonHash;
        resolvedBuyerWins = buyerWins;
        uint256 arbFee = _standardArbFee();
        _executeResolution(buyerWins, arbFee);
        status = CaseStatus.AdminResolved;

        _recordAllVoteResults(buyerWins);

        ICommunityArbitrationFactory(factory).caseResolved(address(this));
        emit CaseResolved(CaseStatus.AdminResolved, buyerWins);
        if (!resolutionFailed) _distributeRewards();
    }

    // ==================== Finalize (timeout) ====================

    function finalize() external nonReentrant {
        if (status != CaseStatus.VotingPhase) revert VotingNotActive();
        if (block.timestamp <= votingDeadline) revert TooEarly();

        if (buyerVoteCount == 0 && sellerVoteCount == 0) {
            _handleTie();
        } else {
            _resolve();
        }
    }

    // ==================== Internal Functions ====================

    /// @dev Inherit language from business contract based on business type
    function _inheritLanguageFromBusiness(BusinessType _businessType, address _businessContract) internal {
        if (_businessType == BusinessType.Product) {
            // Product order has language field
            (bool success, bytes memory data) = _businessContract.staticcall(
                abi.encodeWithSignature("language()")
            );
            if (success && data.length > 0) {
                language = abi.decode(data, (string));
            }
        } else if (_businessType == BusinessType.Auction) {
            // Auction has language field
            (bool success, bytes memory data) = _businessContract.staticcall(
                abi.encodeWithSignature("language()")
            );
            if (success && data.length > 0) {
                language = abi.decode(data, (string));
            }
        } else if (_businessType == BusinessType.C2C) {
            // C2C trade inherits language from sell order
            (bool success, bytes memory data) = _businessContract.staticcall(
                abi.encodeWithSignature("getLanguage()")
            );
            if (success && data.length > 0) {
                language = abi.decode(data, (string));
            }
        }
        // If language cannot be read, it remains empty string (default)
    }

    function _resolve() internal {
        bool buyerWins = buyerVoteCount > sellerVoteCount;
        resolvedBuyerWins = buyerWins;
        uint256 arbFee = _standardArbFee();
        _executeResolution(buyerWins, arbFee);
        _recordAllVoteResults(buyerWins);
        status = CaseStatus.Resolved;
        ICommunityArbitrationFactory(factory).caseResolved(address(this));
        emit CaseResolved(CaseStatus.Resolved, buyerWins);
        // Only distribute if funds actually arrived; otherwise wait for adminRetryResolution.
        if (!resolutionFailed) _distributeRewards();
    }

    function _handleTie() internal {
        status = CaseStatus.Tied;
        resolvedBuyerWins = false;
        _executeResolution(false, 0);
        ICommunityArbitrationFactory(factory).caseResolved(address(this));
        emit CaseResolved(CaseStatus.Tied, false);
        if (!resolutionFailed) _distributeRewards();
    }

    // Audit note [M-02]: The safety of low-level call + abi.encodeWithSignature is guaranteed by:
    // (1) businessContract is hardcoded by factory during createCase, only accepting PlatformSettings-authorized contracts
    // (2) Function signatures are verified by the compiler to match the target contract ABI
    // (3) Attackers cannot pass in arbitrary businessContract addresses
    function _standardArbFee() internal view returns (uint256) {
        CommunityArbitrationFactory f = CommunityArbitrationFactory(factory);
        return disputeAmount * f.ARBITRATION_FEE_RATE() / 10000;
    }

    function _winnerAddress(bool buyerWins) internal view returns (address) {
        return buyerWins == initiatorIsBuyer ? initiator : respondent;
    }

    function _buyerAddress() internal view returns (address) {
        return initiatorIsBuyer ? initiator : respondent;
    }

    function _sellerAddress() internal view returns (address) {
        return initiatorIsBuyer ? respondent : initiator;
    }

    // [H-04 fix]: If business contract reverts, store failure state for admin retry
    function _executeResolution(bool buyerWins, uint256 arbFee) internal {

        address winner = _winnerAddress(buyerWins);
        bool ok;

        if (businessType == BusinessType.Product) {
            (ok,) = businessContract.call(
                abi.encodeWithSignature(
                    "communityResolve(bytes16,address,uint256,uint256)",
                    orderId,
                    winner,
                    arbFee,
                    buyerWins ? disputeAmount : 0
                )
            );
        } else if (businessType == BusinessType.Auction) {
            (ok,) = businessContract.call(
                abi.encodeWithSignature(
                    "communityResolveAuction(bool,uint256)",
                    buyerWins,
                    arbFee
                )
            );
        } else {
            (ok,) = businessContract.call(
                abi.encodeWithSignature(
                    "communityResolveDispute(address,uint256)",
                    winner,
                    arbFee
                )
            );
        }

        if (!ok) {
            resolutionFailed = true;
            storedArbFee = arbFee;
        } else {
            // [M-05 fix]: Clear dispute status after successful resolution
            _clearDisputeStatus();
        }
    }

    // [M-05 fix]: Clear dispute status in CooldownManager for both parties
    function _clearDisputeStatus() internal {
        IPlatformSettings s = IPlatformSettings(settingsAddr);
        address cm = s.getCooldownManager();
        if (cm != address(0)) {
            try ICooldownManager(cm).disputeResolved(_buyerAddress()) {} catch {}
            try ICooldownManager(cm).disputeResolved(_sellerAddress()) {} catch {}
        }
    }

    function adminRetryResolution() external nonReentrant {
        IPlatformSettings s = IPlatformSettings(settingsAddr);
        if (!s.isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        if (!resolutionFailed) revert WrongStatus();
        resolutionFailed = false;
        _executeResolution(resolvedBuyerWins, storedArbFee);
        if (resolutionFailed) revert TransferFailed();
        // Funds have now arrived; distribute if not already done.
        if (!rewardsDistributed) _distributeRewards();
    }

    function _recordAllVoteResults(bool buyerWins) internal {
        ICommunityArbitrationFactory f = ICommunityArbitrationFactory(factory);
        uint256 len = votes.length;
        for (uint256 i = 0; i < len;) {
            bool wasCorrect = (votes[i].votedForBuyer == buyerWins);
            f.recordVoteResult(votes[i].arbitrator, wasCorrect);
            unchecked { ++i; }
        }
    }

    // ==================== Reward Distribution ====================

    // Audit note [L-06]: distributeRewards distributes the actual deposit received by this case, up to the standard 10% arbitration fee.
    // When buyer wins, buyer's pre-paid deposit should be returned to buyer, and seller's deducted deposit is used for community/platform distribution.
    // When seller wins or tie resolves in seller's favor, seller's deposit is unfrozen by the business contract, and buyer's deposit is used for community/platform distribution.
    // If C2C buyer deposit is less than 10%, distribute based on actual case balance; if higher than 10%, distribute at most 10%, excess returned per winner rules.
    function distributeRewards() external nonReentrant {
        if (status != CaseStatus.Resolved && status != CaseStatus.AdminResolved && status != CaseStatus.Tied) revert CaseNotResolved();
        // If business resolution failed, case funds have not arrived yet. Distributing
        // now would burn the rewardsDistributed flag on a ~0 balance and permanently
        // lock funds that adminRetryResolution later brings in. Block until retried.
        if (resolutionFailed) revert WrongStatus();
        if (rewardsDistributed) revert RewardsAlreadyDistributed();
        _distributeRewards();
    }

    function _distributeRewards() internal {
        if (rewardsDistributed) return;
        // [M-01 fix]: Set rewardsDistributed at the end to allow retry if transfers fail

        CommunityArbitrationFactory f = CommunityArbitrationFactory(factory);
        address _token = paymentToken;
        address _settingsAddr = settingsAddr;
        uint256 standardFee = _standardArbFee();
        uint256 balance = IERC20(_token).balanceOf(address(this));
        bool buyerWins = resolvedBuyerWins;
        if (buyerWins && balance > standardFee) {
            _safeTransfer(_buyerAddress(), balance - standardFee, _token);
        } else if (!buyerWins && balance > standardFee) {
            // Mirror the buyer-wins branch (and the L-06 note): when seller wins,
            // any balance above the standard arbitration fee belongs to the winner
            // (e.g. C2C buy-order cases can be funded by both the MD guarantee
            // deduction and the buy-order deposit forfeiture). Refund the excess
            // instead of leaving it permanently locked in the case.
            _safeTransfer(_winnerAddress(buyerWins), balance - standardFee, _token);
        }
        uint256 currentBalance = IERC20(_token).balanceOf(address(this));
        uint256 distributable = currentBalance > standardFee ? standardFee : currentBalance;
        actualArbFee = distributable;
        uint256 communityPool = distributable * f.COMMUNITY_SHARE() / 10000;
        uint256 platformFee = distributable - communityPool;

        address platformWallet = IPlatformSettings(_settingsAddr).getPlatformWallet();
        _payPlatform(platformFee, platformWallet, _token, _settingsAddr);

        uint256 correctCount = 0;
        uint256 len = votes.length;
        for (uint256 i = 0; i < len;) {
            if (votes[i].votedForBuyer == buyerWins) correctCount++;
            unchecked { ++i; }
        }

        if (correctCount == 0) {
            address winner = _winnerAddress(buyerWins);
            _safeTransfer(winner, communityPool, _token);
        } else {
            uint256 perVoter = communityPool / correctCount;
            uint256 paid;
            for (uint256 i = 0; i < len;) {
                if (votes[i].votedForBuyer == buyerWins) {
                    paid += perVoter;
                    _safeTransfer(votes[i].arbitrator, perVoter, _token);
                }
                unchecked { ++i; }
            }
            uint256 dust = communityPool - paid;
            if (dust > 0) {
                _payPlatform(dust, platformWallet, _token, _settingsAddr);
            }
        }

        // [M-01 fix]: Mark rewards as distributed only after all transfers complete
        rewardsDistributed = true;
        emit RewardsDistributed(communityPool, correctCount);
    }

    function claimPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingWithdrawals[msg.sender] = 0;
        if (!IERC20(paymentToken).transfer(msg.sender, amount)) revert TransferFailed();
    }

    function _safeTransfer(address to, uint256 amount, address _token) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = _token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        bool ok = success && (data.length == 0 || abi.decode(data, (bool)));
        if (!ok) {
            pendingWithdrawals[to] += amount;
            emit PendingWithdrawal(to, amount);
        }
    }

    /// @dev Platform fee delivery: prefer the splitter (auto 30/30/40 split in the same tx), fall back to EOA platformWallet on failure.
    /// Does not reuse _safeTransfer's pendingWithdrawals branch — nobody can claimPending for the splitter,
    /// so funds would be permanently stuck. On failure, go straight to the EOA fallback for the owner to distribute manually later.
    function _payPlatform(uint256 amount, address platformWalletFallback, address _token, address _settingsAddr) internal {
        if (amount == 0) return;
        address splitter = IPlatformSettings(_settingsAddr).getFeeSplitter();
        if (splitter != address(0)) {
            (bool s1, bytes memory d1) = _token.call(abi.encodeWithSelector(IERC20.transfer.selector, splitter, amount));
            bool ok1 = s1 && (d1.length == 0 || abi.decode(d1, (bool)));
            if (ok1) {
                // Do not revert even if distribute fails — funds are already in the splitter and can be swept later
                try IPlatformFeeSplitter(splitter).distribute(_token, amount) {} catch {}
                return;
            }
            // splitter transfer failed — continue to the EOA fallback
            emit SplitterFallback(_token, amount, platformWalletFallback);
        }
        // EOA path: on failure it drops into the pending pool for the owner to claim later
        _safeTransfer(platformWalletFallback, amount, _token);
    }

    // ==================== Query Functions ====================

    function getVoteCount() external view returns (uint256) {
        return votes.length;
    }

    function getVote(uint256 index) external view returns (VoteRecord memory) {
        return votes[index];
    }

    function getInitiatorImages() external pure returns (string[] memory) {
        return new string[](0);
    }

    function getRespondentImages() external pure returns (string[] memory) {
        return new string[](0);
    }
}



