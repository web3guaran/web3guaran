// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * C2CFactoryReader - C2C Factory Query Contract
 *
 * Provides paymentToken filtering, seller/buyer C2C cumulative statistics query.
 */

import "./interfaces/Interfaces.sol";
import "./ArchiveStore.sol";

interface IC2CTradeInfo {
    function getTradeInfo() external view returns (address, address, address, uint256, uint256, C2CTradeStatus, bytes16);
    function getTradeDepositInfo() external view returns (bool, uint256, bool, uint256);
    function paymentDeadline() external view returns (uint256);
    function isBuyOrderTrade() external view returns (bool);
}

interface IC2CSellOrderInfo {
    function getOrderInfo() external view returns (
        address seller_, string memory title_, uint256 tokenAmount_, uint256 price_,
        string[] memory paymentMethods_, string memory fiatType_, uint256 expireTime_, address paymentToken_
    );
    function getOrderConfig() external view returns (uint256 minTradeAmount, bool requireBuyerDeposit, uint256 buyerDepositRate, C2COrderStatus status);
    function getAvailable() external view returns (uint256);
}

interface IC2CBuyOrderInfo {
    function getOrderInfo() external view returns (
        address buyer_, string memory title_, address paymentToken_, uint256 tokenAmount_,
        uint256 price_, uint256 expireTime_, uint256 minTradeAmount_, C2COrderStatus status_
    );
    function getOrderText() external view returns (string[] memory paymentMethods_, string memory fiatType_);
    function getAvailable() external view returns (uint256);
}

interface IC2CFactoryState {
    function activeSellOrders(uint256) external view returns (address);
    function activeBuyOrders(uint256) external view returns (address);
    function orderLanguage(address) external view returns (string memory);
    function disputedTrades(uint256) external view returns (address);
    function sellerSellOrders(address, uint256) external view returns (address);
    function buyerBuyOrders(address, uint256) external view returns (address);
    function paymentTokenToOrders(address, uint256) external view returns (address);
    function orderPaymentToken(address) external view returns (address);
    function isFactorySellOrder(address) external view returns (bool);
    function isFactoryBuyOrder(address) external view returns (bool);
    function tradeArchives(uint256) external view returns (ArchiveStore);
    function getSellOrderCount() external view returns (uint256);
    function getBuyOrderCount() external view returns (uint256);
    function getTradeCount() external view returns (uint256);
    function getTradeArchiveCount() external view returns (uint256);
    function getDisputedTradeCount() external view returns (uint256);
    function getPaymentTokenOrderCount(address token) external view returns (uint256);
    function getSellerSellOrderCount(address seller) external view returns (uint256);
    function getBuyerBuyOrderCount(address buyer) external view returns (uint256);
    // Language market isolation
    function sellOrdersByLanguage(string calldata, uint256) external view returns (address);
    function buyOrdersByLanguage(string calldata, uint256) external view returns (address);
    function getSellOrderCountByLanguage(string calldata) external view returns (uint256);
    function getBuyOrderCountByLanguage(string calldata) external view returns (uint256);
    // C2C dedicated accumulators (separate from PlatformSettings 7-group mapping)
    function sellerC2CCompletedAmount(address, address) external view returns (uint256);
    function sellerC2CCompletedCount(address, address) external view returns (uint256);
    function sellerC2CDisputeAmount(address, address) external view returns (uint256);
    function sellerC2CDisputeCount(address, address) external view returns (uint256);
    function buyerC2CCompletedAmount(address, address) external view returns (uint256);
    function buyerC2CCompletedCount(address, address) external view returns (uint256);
    function buyerC2CDisputeAmount(address, address) external view returns (uint256);
    function buyerC2CDisputeCount(address, address) external view returns (uint256);
    function usdtAddr() external view returns (address);
}

/// @title C2CFactoryReader - C2C Query Interface
contract C2CFactoryReader {

    address public factory;
    uint256 public constant MAX_PAGE_SIZE = 24;

    constructor(address _factory) {
        factory = _factory;
    }

    // ==================== Original Queries ====================

    function getActiveSellOrders(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginateIndexed(0, "", address(0), offset, limit, IC2CFactoryState(factory).getSellOrderCount());
    }

    function getActiveBuyOrders(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginateIndexed(1, "", address(0), offset, limit, IC2CFactoryState(factory).getBuyOrderCount());
    }

    function getDisputedTrades(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginateIndexed(2, "", address(0), offset, limit, IC2CFactoryState(factory).getDisputedTradeCount());
    }



    function getUserTrades(address user, uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        if (generation >= f.getTradeArchiveCount()) revert InvalidGeneration();
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        return f.tradeArchives(generation).getUserRecords(user, offset, limit);
    }

    function getAllTrades(uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        if (generation >= f.getTradeArchiveCount()) revert InvalidGeneration();
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        return f.tradeArchives(generation).getGlobalRecords(offset, limit);
    }

    function getSellerSellOrders(address seller, uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = IC2CFactoryState(factory).getSellerSellOrderCount(seller);
        return _paginateIndexed(3, "", seller, offset, limit, total);
    }

    function getBuyerBuyOrders(address buyer, uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = IC2CFactoryState(factory).getBuyerBuyOrderCount(buyer);
        return _paginateIndexed(4, "", buyer, offset, limit, total);
    }

    function getSellerSellOrderCount(address seller) external view returns (uint256) {
        return IC2CFactoryState(factory).getSellerSellOrderCount(seller);
    }

    function getBuyerBuyOrderCount(address buyer) external view returns (uint256) {
        return IC2CFactoryState(factory).getBuyerBuyOrderCount(buyer);
    }

    // ==================== Language Market Isolation: Query by Language ====================

    /// @notice Get sell orders by language with pagination
    /// @param language Language code (e.g., "zh", "en", "es")
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return Array of sell order addresses for the specified language
    function getSellOrdersByLanguage(string calldata language, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        uint256 total = f.getSellOrderCountByLanguage(language);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = f.sellOrdersByLanguage(language, i);
        }
        return result;
    }

    /// @notice Get buy orders by language with pagination
    /// @param language Language code (e.g., "zh", "en", "es")
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return Array of buy order addresses for the specified language
    function getBuyOrdersByLanguage(string calldata language, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        uint256 total = f.getBuyOrderCountByLanguage(language);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = f.buyOrdersByLanguage(language, i);
        }
        return result;
    }

    /// @notice Get order counts by language
    function getSellOrderCountByLanguage(string calldata language) external view returns (uint256) {
        return IC2CFactoryState(factory).getSellOrderCountByLanguage(language);
    }

    function getBuyOrderCountByLanguage(string calldata language) external view returns (uint256) {
        return IC2CFactoryState(factory).getBuyOrderCountByLanguage(language);
    }

    // ==================== Dual Payment Channel: Query by Token Dimension ====================

    /// @notice Filter all active orders of a given token
    /// @dev Used by frontend token filter tab
    function filterByPaymentToken(address token, uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = IC2CFactoryState(factory).getPaymentTokenOrderCount(token);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        IC2CFactoryState f = IC2CFactoryState(factory);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = f.paymentTokenToOrders(token, i);
        }
        return result;
    }

    /// @notice Filter by (side, token) dual dimensions -- frontend 4 tabs in one lookup
    /// @param side 0=sell orders only (user scenario: buyer wants to buy USDT), 1=buy orders only (seller wants to sell USDT)
    /// @param token paymentToken (USDT)
    /// @return Order address array filtered by side
    /// @dev Since paymentTokenToOrders contains both sell/buy orders, this function uses isFactorySellOrder/isFactoryBuyOrder for secondary filtering;
    ///      To prevent gas explosion, scans paymentToken list with pagination, results may be less than limit (filtered out by the other side)
    function filterBySideAndToken(uint8 side, address token, uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        IC2CFactoryState f = IC2CFactoryState(factory);
        uint256 total = f.getPaymentTokenOrderCount(token);
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory tmp = new address[](end - offset);
        uint256 count;
        for (uint256 i = offset; i < end; i++) {
            address ord = f.paymentTokenToOrders(token, i);
            bool match_;
            if (side == 0) match_ = f.isFactorySellOrder(ord);
            else match_ = f.isFactoryBuyOrder(ord);
            if (match_) {
                tmp[count] = ord;
                count++;
            }
        }
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count;) { result[i] = tmp[i]; unchecked { ++i; } }
        return result;
    }

    /// @notice Filter by (paymentMethod, token) combined


    // ==================== C2C Seller/Buyer Cumulative Statistics (Strictly Accounted by Token) ====================

    /// @notice Seller's C2C cumulative statistics for a specified token
    /// @return completedAmount Total completed trade amount
    /// @return completedCount Total completed trade count
    /// @return disputeAmount Total amount of trades that went through disputes
    /// @return disputeCount Total count of trades that went through disputes
    function getSellerC2CStats(address seller, address token) external view returns (
        uint256 completedAmount, uint256 completedCount, uint256 disputeAmount, uint256 disputeCount
    ) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        completedAmount = f.sellerC2CCompletedAmount(seller, token);
        completedCount = f.sellerC2CCompletedCount(seller, token);
        disputeAmount = f.sellerC2CDisputeAmount(seller, token);
        disputeCount = f.sellerC2CDisputeCount(seller, token);
    }

    /// @notice Buyer's C2C cumulative statistics for a specified token
    function getBuyerC2CStats(address buyer, address token) external view returns (
        uint256 completedAmount, uint256 completedCount, uint256 disputeAmount, uint256 disputeCount
    ) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        completedAmount = f.buyerC2CCompletedAmount(buyer, token);
        completedCount = f.buyerC2CCompletedCount(buyer, token);
        disputeAmount = f.buyerC2CDisputeAmount(buyer, token);
        disputeCount = f.buyerC2CDisputeCount(buyer, token);
    }

    /// @notice Seller C2C income aggregation (USDT only)
    /// @return usdtCompleted USDT completed amount
    /// @return usdtCount USDT completed count
    function getSellerC2CStatsAll(address seller) external view returns (
        uint256 usdtCompleted, uint256 usdtCount
    ) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        address u = f.usdtAddr();
        usdtCompleted = f.sellerC2CCompletedAmount(seller, u);
        usdtCount = f.sellerC2CCompletedCount(seller, u);
    }

    /// @notice Buyer C2C cumulative aggregation (USDT only)
    function getBuyerC2CStatsAll(address buyer) external view returns (
        uint256 usdtCompleted, uint256 usdtCount
    ) {
        IC2CFactoryState f = IC2CFactoryState(factory);
        address u = f.usdtAddr();
        usdtCompleted = f.buyerC2CCompletedAmount(buyer, u);
        usdtCount = f.buyerC2CCompletedCount(buyer, u);
    }

    function _paginateIndexed(uint8 arrType, string memory, address seller, uint256 offset, uint256 limit, uint256 total) internal view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        IC2CFactoryState f = IC2CFactoryState(factory);
        for (uint256 i = offset; i < end; i++) {
            if (arrType == 0) result[i - offset] = f.activeSellOrders(i);
            else if (arrType == 1) result[i - offset] = f.activeBuyOrders(i);
            else if (arrType == 2) result[i - offset] = f.disputedTrades(i);
            else if (arrType == 3) result[i - offset] = f.sellerSellOrders(seller, i);
            else result[i - offset] = f.buyerBuyOrders(seller, i);
        }
        return result;
    }

    // ==================== Batch Order Info ====================

    struct SellOrderInfo {
        address addr;
        address seller;
        string title;
        uint256 tokenAmount;
        uint256 price;
        string[] paymentMethods;
        string fiatType;
        uint256 expireTime;
        address paymentToken;
        uint256 minTradeAmount;
        uint256 available;
        uint8 status;
        bool requireBuyerDeposit;
        uint256 buyerDepositRate;
    }

    struct BuyOrderInfo {
        address addr;
        address buyer;
        string title;
        address paymentToken;
        uint256 tokenAmount;
        uint256 price;
        uint256 expireTime;
        uint256 minTradeAmount;
        uint8 status;
        string[] paymentMethods;
        string fiatType;
        uint256 available;
    }

    function batchGetSellOrderInfos(address[] calldata orders) external view returns (SellOrderInfo[] memory results) {
        uint256 len = orders.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        results = new SellOrderInfo[](len);
        for (uint256 i; i < len; i++) {
            results[i].addr = orders[i];
            try IC2CSellOrderInfo(orders[i]).getOrderInfo() returns (
                address s, string memory t, uint256 ta, uint256 p,
                string[] memory pm, string memory ft, uint256 et, address pt
            ) {
                results[i].seller = s;
                results[i].title = t;
                results[i].tokenAmount = ta;
                results[i].price = p;
                results[i].paymentMethods = pm;
                results[i].fiatType = ft;
                results[i].expireTime = et;
                results[i].paymentToken = pt;
            } catch {}
            try IC2CSellOrderInfo(orders[i]).getOrderConfig() returns (uint256 mta, bool req, uint256 rate, C2COrderStatus st) {
                results[i].minTradeAmount = mta;
                results[i].status = uint8(st);
                results[i].requireBuyerDeposit = req;
                results[i].buyerDepositRate = rate;
            } catch {}
            try IC2CSellOrderInfo(orders[i]).getAvailable() returns (uint256 av) {
                results[i].available = av;
            } catch {}
        }
    }

    function batchGetBuyOrderInfos(address[] calldata orders) external view returns (BuyOrderInfo[] memory results) {
        uint256 len = orders.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        results = new BuyOrderInfo[](len);
        for (uint256 i; i < len; i++) {
            results[i].addr = orders[i];
            try IC2CBuyOrderInfo(orders[i]).getOrderInfo() returns (
                address b, string memory t, address pt, uint256 ta,
                uint256 p, uint256 et, uint256 mta, C2COrderStatus st
            ) {
                results[i].buyer = b;
                results[i].title = t;
                results[i].paymentToken = pt;
                results[i].tokenAmount = ta;
                results[i].price = p;
                results[i].expireTime = et;
                results[i].minTradeAmount = mta;
                results[i].status = uint8(st);
            } catch {}
            try IC2CBuyOrderInfo(orders[i]).getOrderText() returns (string[] memory pm, string memory ft) {
                results[i].paymentMethods = pm;
                results[i].fiatType = ft;
            } catch {}
            try IC2CBuyOrderInfo(orders[i]).getAvailable() returns (uint256 av) {
                results[i].available = av;
            } catch {}
        }
    }

    // ==================== Batch Trade Info ====================

    struct TradeInfo {
        address addr;
        address buyer;
        address seller;
        address paymentToken;
        uint256 tokenAmount;
        uint256 price;
        uint8 status;
        bytes16 orderId;
        uint256 paymentDeadline;
        bool isBuyOrderTrade;
        bool requireBuyerDeposit;
        uint256 buyerDepositRate;
        bool buyerDepositPaid;
    }

    function batchGetTradeInfos(address[] calldata trades) external view returns (TradeInfo[] memory results) {
        uint256 len = trades.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        results = new TradeInfo[](len);
        for (uint256 i; i < len; i++) {
            results[i].addr = trades[i];
            _fillTrade(results[i], trades[i]);
        }
    }

    function _fillTrade(TradeInfo memory r, address t) internal view {
        try IC2CTradeInfo(t).getTradeInfo() returns (
            address buyer_, address seller_, address pt_, uint256 ta_,
            uint256 price_, C2CTradeStatus status_, bytes16 oid_
        ) {
            r.buyer = buyer_;
            r.seller = seller_;
            r.paymentToken = pt_;
            r.tokenAmount = ta_;
            r.price = price_;
            r.status = uint8(status_);
            r.orderId = oid_;
        } catch {}
        try IC2CTradeInfo(t).getTradeDepositInfo() returns (bool req, uint256 rate, bool paid, uint256) {
            r.requireBuyerDeposit = req;
            r.buyerDepositRate = rate;
            r.buyerDepositPaid = paid;
        } catch {}
        try IC2CTradeInfo(t).paymentDeadline() returns (uint256 d) {
            r.paymentDeadline = d;
        } catch {}
        try IC2CTradeInfo(t).isBuyOrderTrade() returns (bool b) {
            r.isBuyOrderTrade = b;
        } catch {}
    }
}

