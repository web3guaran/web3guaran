// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * AuctionFactoryReader — Auction factory batch query contract
 *
 * Standalone Reader contract, architecturally consistent with ProductFactoryReader / C2CFactoryReader.
 * Batch returns complete auction data (including images, paymentToken, orderId); frontend gets all display fields in one call.
 */

import "./interfaces/Interfaces.sol";
import "./ArchiveStore.sol";

interface IAuctionTemplateInfo {
    function getAuctionInfo() external view returns (
        address seller_, string memory title_, string memory description_,
        string[] memory images_, uint256 startPrice_, uint256 buyNowPrice_, uint256 minBidIncrement_
    );
    function getAuctionBidInfo() external view returns (
        uint256 startTime_, uint256 endTime_, AuctionStatus status_,
        address highestBidder_, uint256 highestBid_, uint256 bidCount_, bytes16 orderId_
    );
    function getPaymentToken() external view returns (address);
}

interface IAuctionFactoryState {
    function activeAuctions(uint256) external view returns (address);
    function arbitratingAuctions(uint256) external view returns (address);
    function sellerAuctions(address, uint256) external view returns (address);
    function auctionArchives(uint256) external view returns (ArchiveStore);
    function getActiveAuctionCount() external view returns (uint256);
    function getArbitratingAuctionCount() external view returns (uint256);
    function getSellerAuctionCount(address) external view returns (uint256);
    function getArchiveGenerationCount() external view returns (uint256);
    // Language market isolation
    function auctionsByLanguage(string calldata, uint256) external view returns (address);
    function getAuctionCountByLanguage(string calldata) external view returns (uint256);
}

/// @title AuctionFactoryReader - Auction batch query interface
contract AuctionFactoryReader {

    address public factory;
    uint256 public constant MAX_PAGE_SIZE = 24;

    constructor(address _factory) {
        factory = _factory;
    }

    // ==================== Paginated Query ====================

    function getActiveAuctions(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = IAuctionFactoryState(factory).getActiveAuctionCount();
        return _paginate(0, address(0), 0, offset, limit, total);
    }

    function getArbitratingAuctions(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = IAuctionFactoryState(factory).getArbitratingAuctionCount();
        return _paginate(1, address(0), 0, offset, limit, total);
    }

    function getAuctionsBySeller(address seller, uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = IAuctionFactoryState(factory).getSellerAuctionCount(seller);
        return _paginate(2, seller, 0, offset, limit, total);
    }

    function getUserAuctionHistory(address user, uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IAuctionFactoryState f = IAuctionFactoryState(factory);
        if (generation >= f.getArchiveGenerationCount()) revert InvalidGeneration();
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        return f.auctionArchives(generation).getUserRecords(user, offset, limit);
    }

    function getAllAuctionHistory(uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IAuctionFactoryState f = IAuctionFactoryState(factory);
        if (generation >= f.getArchiveGenerationCount()) revert InvalidGeneration();
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        return f.auctionArchives(generation).getGlobalRecords(offset, limit);
    }

    // ==================== Language Market Isolation: Query by Language ====================

    /// @notice Get auctions by language with pagination
    /// @param language Language code (e.g., "zh", "en", "es")
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return Array of auction addresses for the specified language
    function getAuctionsByLanguage(string calldata language, uint256 offset, uint256 limit) external view returns (address[] memory) {
        IAuctionFactoryState f = IAuctionFactoryState(factory);
        uint256 total = f.getAuctionCountByLanguage(language);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = f.auctionsByLanguage(language, i);
        }
        return result;
    }

    /// @notice Get auction count by language
    function getAuctionCountByLanguage(string calldata language) external view returns (uint256) {
        return IAuctionFactoryState(factory).getAuctionCountByLanguage(language);
    }

    function _paginate(uint8 arrType, address seller, uint256, uint256 offset, uint256 limit, uint256 total) internal view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        IAuctionFactoryState f = IAuctionFactoryState(factory);
        for (uint256 i = offset; i < end; i++) {
            if (arrType == 0) result[i - offset] = f.activeAuctions(i);
            else if (arrType == 1) result[i - offset] = f.arbitratingAuctions(i);
            else result[i - offset] = f.sellerAuctions(seller, i);
        }
        return result;
    }

    // ==================== Batch Query Full Auction Info ====================

    struct AuctionInfoResult {
        address addr;
        address seller;
        string title;
        string description;
        string[] images;
        uint256 startPrice;
        uint256 buyNowPrice;
        uint256 minBidIncrement;
        uint256 startTime;
        uint256 endTime;
        uint8 status;
        address highestBidder;
        uint256 highestBid;
        uint256 bidCount;
        bytes16 orderId;
        address paymentToken;
    }

    function batchGetAuctionInfos(address[] calldata auctions) external view returns (AuctionInfoResult[] memory results) {
        uint256 len = auctions.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        results = new AuctionInfoResult[](len);
        for (uint256 i; i < len; i++) {
            results[i].addr = auctions[i];
            _fillBasic(results[i], auctions[i]);
            _fillBid(results[i], auctions[i]);
            _fillPayment(results[i], auctions[i]);
        }
    }

    function _fillBasic(AuctionInfoResult memory r, address a) internal view {
        try IAuctionTemplateInfo(a).getAuctionInfo() returns (
            address s, string memory t, string memory d, string[] memory imgs,
            uint256 sp, uint256 bnp, uint256 mbi
        ) {
            r.seller = s;
            r.title = t;
            r.description = d;
            r.images = imgs;
            r.startPrice = sp;
            r.buyNowPrice = bnp;
            r.minBidIncrement = mbi;
        } catch {}
    }

    function _fillBid(AuctionInfoResult memory r, address a) internal view {
        try IAuctionTemplateInfo(a).getAuctionBidInfo() returns (
            uint256 st, uint256 et, AuctionStatus status,
            address hb, uint256 hBid, uint256 bc, bytes16 oid
        ) {
            r.startTime = st;
            r.endTime = et;
            r.status = uint8(status);
            r.highestBidder = hb;
            r.highestBid = hBid;
            r.bidCount = bc;
            r.orderId = oid;
        } catch {}
    }

    function _fillPayment(AuctionInfoResult memory r, address a) internal view {
        try IAuctionTemplateInfo(a).getPaymentToken() returns (address pt) {
            r.paymentToken = pt;
        } catch {}
    }

}
