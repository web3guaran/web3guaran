// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "./interfaces/Interfaces.sol";

library ProductLib {

    event OrderCompleted(uint256 sellerAmount, uint256 fee, address token);
    event ArbitrationShortfall(address indexed buyer, uint256 shortfall);
    event TransferPending(address indexed to, address indexed token, uint256 amount);

    function _safeTransferToUser(
        address _token,
        address to,
        uint256 amount,
        mapping(address => mapping(address => uint256)) storage _pending
    ) internal {
        if (amount == 0) return;
        try IERC20(_token).transfer(to, amount) returns (bool ok) {
            if (!ok) {
                _pending[_token][to] += amount;
                emit TransferPending(to, _token, amount);
            }
        } catch {
            _pending[_token][to] += amount;
            emit TransferPending(to, _token, amount);
        }
    }

    struct SettleParams {
        address seller;
        uint256 orderAmount;
        uint8 feeType;
        address token;
        address settings;
        address inviteRegistry;
        address keywordWeight;
    }

    function settle(
        SettleParams memory p,
        mapping(address => mapping(address => uint256)) storage _pending
    ) internal {
        uint256 fee = _calcFee(p);
        uint256 sellerAmount = p.orderAmount - fee;
        _safeTransferToUser(p.token, p.seller, sellerAmount, _pending);
        _distributeFee(p, fee);
        _recordStats(p, sellerAmount);
    }

    function _calcFee(SettleParams memory p) private view returns (uint256 fee) {
        uint256 feeRate = IPlatformSettings(p.settings).getFeeRate(p.feeType);
        fee = p.orderAmount * feeRate / 10000;
        if (fee == 0 && feeRate > 0 && p.orderAmount > 0) fee = 1;
    }

    function _distributeFee(SettleParams memory p, uint256 fee) private {
        if (fee == 0) return;
        if (!IERC20(p.token).transfer(p.inviteRegistry, fee)) revert TransferFailed();
        IInviteRegistry(p.inviteRegistry).distributeFee(p.seller, fee, IERC20(p.token));
        IPlatformSettings(p.settings).recordFee(fee, p.token);
    }

    function _recordStats(SettleParams memory p, uint256 sellerAmount) private {
        IKeywordWeight(p.keywordWeight).recordSale(address(this), p.orderAmount);
        IPlatformSettings(p.settings).recordOrder(p.seller);
        IPlatformSettings(p.settings).recordSettlement(p.seller, p.token, sellerAmount, p.orderAmount);
        emit OrderCompleted(sellerAmount, p.orderAmount - sellerAmount, p.token);
    }

    function claimPending(
        address _token,
        mapping(address => mapping(address => uint256)) storage _pending
    ) internal {
        uint256 amount = _pending[_token][msg.sender];
        if (amount == 0) revert NoBalance();
        _pending[_token][msg.sender] = 0;
        if (!IERC20(_token).transfer(msg.sender, amount)) revert TransferFailed();
    }
}
