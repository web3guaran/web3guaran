// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "./interfaces/Interfaces.sol";

/**
 * ============================================================
 *  PlatformFeeSplitter — eight-way proportional auto-split contract (governable version)
 *  Push model: the receiving contract calls distribute(token, amount) within the same tx,
 *           and funds are immediately dispatched to the 8 payees by the current shareN, with no intermediate custody.
 *
 *  Governance model:
 *    - owner can independently change any payee address (guards against blacklist freezes)
 *    - owner can adjust the share ratios as a whole (the eight must sum to = 10000)
 *    - owner can transfer ownership (emergency / multisig upgrade)
 *    - no custody: every distribute transfers the full amount to the 8 parties, so the balance is theoretically always 0
 *    - leftover wei (the non-divisible remainder) goes to the first payee, payee0
 *
 *  Call convention:
 *    the receiving contract first transferFrom(payer, splitter, amount), then calls distribute(token, amount).
 *    In distribute, the splitter checks its own token balance >= amount before dispatching,
 *    preventing under-transfer from "calling distribute before transferFrom" or a caller passing the wrong amount.
 * ============================================================
 */

error InvalidShares();
error PayeeZero();
error AmountZero();
error InsufficientBalance();
error TransferFail();
error InvalidIndex();

contract PlatformFeeSplitter {

    uint256 public constant PAYEE_COUNT = 8;
    uint256 public constant TOTAL_SHARES = 10000;

    /// Governor: can modify payee/share and transfer ownership
    address public owner;

    /// Payee addresses (owner can change), index 0..7
    address[8] public payees;

    /// Shares in basis points (the eight must sum to = TOTAL_SHARES), index 0..7
    uint256[8] public shares;

    event Distributed(address indexed token, uint256 amount, uint256[8] amounts);
    event PayeeUpdated(uint8 indexed index, address indexed oldPayee, address indexed newPayee);
    event SharesUpdated(uint256[8] shares);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _owner,
        address[8] memory _payees,
        uint256[8] memory _shares
    ) {
        if (_owner == address(0)) revert PayeeZero();
        uint256 sum;
        for (uint256 i = 0; i < PAYEE_COUNT; i++) {
            if (_payees[i] == address(0)) revert PayeeZero();
            if (_shares[i] == 0) revert InvalidShares();
            sum += _shares[i];
        }
        if (sum != TOTAL_SHARES) revert InvalidShares();

        owner = _owner;
        payees = _payees;
        shares = _shares;

        emit OwnershipTransferred(address(0), _owner);
    }

    // ==================== Governance ====================

    /// Modify any payee. index ∈ {0..7}
    function setPayee(uint8 index, address newPayee) external onlyOwner {
        if (newPayee == address(0)) revert PayeeZero();
        if (index >= PAYEE_COUNT) revert InvalidIndex();
        emit PayeeUpdated(index, payees[index], newPayee);
        payees[index] = newPayee;
    }

    /// Adjust all eight shares at once (their sum must = 10000)
    function setShares(uint256[8] calldata _shares) external onlyOwner {
        uint256 sum;
        for (uint256 i = 0; i < PAYEE_COUNT; i++) {
            if (_shares[i] == 0) revert InvalidShares();
            sum += _shares[i];
        }
        if (sum != TOTAL_SHARES) revert InvalidShares();
        shares = _shares;
        emit SharesUpdated(_shares);
    }

    /// Transfer ownership (emergency switch to a multisig or new admin wallet)
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert PayeeZero();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ==================== Distribution ====================

    /// @dev Split `total` across the 8 payees by current shares and transfer.
    ///      Payees 1..7 get floor(total*share/10000); payee0 gets the remainder (absorbs non-divisible wei).
    function _dispatch(address token, uint256 total) internal {
        uint256[8] memory amounts;
        uint256 allocated;
        for (uint256 i = 1; i < PAYEE_COUNT; i++) {
            uint256 a = (total * shares[i]) / TOTAL_SHARES;
            amounts[i] = a;
            allocated += a;
        }
        amounts[0] = total - allocated;

        for (uint256 i = 0; i < PAYEE_COUNT; i++) {
            if (!IERC20(token).transfer(payees[i], amounts[i])) revert TransferFail();
        }
        emit Distributed(token, total, amounts);
    }

    /**
     * Splits the given amount of token currently held by this contract to the 8 parties by the current share ratios.
     *
     * Callable by anyone (ERC20 has no hooks, so the receiving contract must call it immediately after transferFrom).
     * Before calling, the splitter must have already received amount (i.e. the calling contract must transferFrom to the splitter first).
     *
     * Leftover wei (non-divisible) goes to the first payee, payee0.
     */
    function distribute(address token, uint256 amount) external {
        if (amount == 0) revert AmountZero();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) revert InsufficientBalance();
        _dispatch(token, amount);
    }

    /**
     * Emergency sweep: distributes the contract's current balance by the current ratios.
     * Handles residual balances left by legacy contracts that transferred directly, and recovery from accidental transfers.
     */
    function sweep(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert AmountZero();
        _dispatch(token, bal);
    }

    /**
     * View function: given an amount, preview the split result across the 8 payees.
     */
    function previewSplit(uint256 amount) external view returns (uint256[8] memory amounts) {
        uint256 allocated;
        for (uint256 i = 1; i < PAYEE_COUNT; i++) {
            uint256 a = (amount * shares[i]) / TOTAL_SHARES;
            amounts[i] = a;
            allocated += a;
        }
        amounts[0] = amount - allocated;
    }

    // ==================== Back-compat accessors ====================
    // The auto-generated getters for `payees`/`shares` require an index arg.
    // These named getters preserve the payee0()..payee7() interface other contracts rely on.

    function payee0() external view returns (address) { return payees[0]; }
    function payee1() external view returns (address) { return payees[1]; }
    function payee2() external view returns (address) { return payees[2]; }
    function payee3() external view returns (address) { return payees[3]; }
    function payee4() external view returns (address) { return payees[4]; }
    function payee5() external view returns (address) { return payees[5]; }
    function payee6() external view returns (address) { return payees[6]; }
    function payee7() external view returns (address) { return payees[7]; }
}
