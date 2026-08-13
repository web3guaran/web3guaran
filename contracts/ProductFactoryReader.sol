// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * ProductFactoryReader — Product Factory Query Contract
 * Reads data from ProductFactory / ProductFactoryKeywords, provides paginated queries
 */

import "./interfaces/Interfaces.sol";
import "./ArchiveStore.sol";

interface IPhysicalProductInfo {
    function getProductInfo() external view returns (
        address seller_, string memory keyword_, string memory language_,
        string memory metadataURI_, uint8 deliveryMethod_, bool delisted_,
        uint256 activeOrderCount_,
        string[] memory specNames, uint256[] memory specPrices, uint256[] memory specStocks
    );
}

interface IVirtualProductInfo {
    function getProductInfo() external view returns (
        address seller_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_,
        string[] memory specNames, uint256[] memory specPrices, uint256[] memory specStocks
    );
}

interface IServiceProductInfo {
    function getProductInfo() external view returns (
        address seller_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_, uint256 totalStock_,
        string[] memory itemNames, uint256[] memory itemPrices, uint256[] memory itemStocks
    );
}

interface IWantToBuyInfo {
    function getProductInfo() external view returns (
        address buyer_, string memory keyword_, string memory language_,
        string memory metadataURI_, bool delisted_,
        uint256 activeOrderCount_, uint256 requestPrice_, uint256 stock_, uint256 originalStock_
    );
}

interface IProductFactoryState {
    function isFactoryProduct(address) external view returns (bool);
    function productType(address) external view returns (uint8);
    function activeProductCount(address) external view returns (uint256);
    function activeProducts(address, uint256) external view returns (address);
    function lastDelistTime(address) external view returns (uint256);
    function totalProductCount() external view returns (uint256);
    function allKeywordKeys(uint256) external view returns (bytes32);
    function keywordExists(bytes32) external view returns (bool);
    function keywordKeysByLanguage(string calldata, uint256) external view returns (bytes32);
    function productsByLanguage(string calldata, uint256) external view returns (address);
    function productLanguage(address) external view returns (string memory);
    function arbitratingProducts(uint256) external view returns (address);
    function productArchives(uint256) external view returns (ArchiveStore);
    function sellerArchives(uint256) external view returns (ArchiveStore);
    function buyerArchives(uint256) external view returns (ArchiveStore);
    function productKeyword(address) external view returns (string memory);
    function getAllKeywordCount() external view returns (uint256);
    function getKeywordProductCount(string calldata) external view returns (uint256);
    function getLanguageProductCount(string calldata) external view returns (uint256);
    function getLanguageKeywordCount(string calldata) external view returns (uint256);
    function getArbitratingProductCount() external view returns (uint256);
    function getSellerArchiveCount() external view returns (uint256);
    function getBuyerArchiveCount() external view returns (uint256);
    function getProductArchiveCount() external view returns (uint256);
    function DELIST_COOLDOWN() external view returns (uint256);
    function usdtAddr() external view returns (address);
    function keywordWeightAddr() external view returns (address);
    function keywordAuctionAddr() external view returns (address);
    function serviceLocationIndex() external view returns (address);
    function depositFactoryAddr() external view returns (address);
    function bumpSeedExternal(string calldata language, string calldata keyword) external;
    function keywordSeed(bytes32) external view returns (uint256);
    function getKeywordProductCountByLanguage(string calldata language, string calldata keyword) external view returns (uint256);
    function keywordToProducts(bytes32 key, uint256 index) external view returns (address);
}

interface IKeywordsState {
    function pendingKeywordKeys(uint256) external view returns (bytes32);
    function approvedKeywordKeys(bytes32) external view returns (bool);
    function isPendingKey(bytes32) external view returns (bool);
    function isRejectedKey(bytes32) external view returns (bool);
    function keywordTypeByKey(bytes32) external view returns (uint8);
    function keywordSubmitterByKey(bytes32) external view returns (address);
    function submitterKeywordKeys(address, uint256) external view returns (bytes32);
    function keywordLanguage(bytes32) external view returns (string memory);
    function keywordText(bytes32) external view returns (string memory);
    function physicalKeywordKeysByLanguage(string calldata, uint256) external view returns (bytes32);
    function virtualKeywordKeysByLanguage(string calldata, uint256) external view returns (bytes32);
    function serviceKeywordKeysByLanguage(string calldata, uint256) external view returns (bytes32);
    function wantToBuyKeywordKeysByLanguage(string calldata, uint256) external view returns (bytes32);
    function getPendingCount() external view returns (uint256);
    function getSubmitterKeywordCount(address) external view returns (uint256);
    function getPhysicalKeywordCount(string calldata) external view returns (uint256);
    function getVirtualKeywordCount(string calldata) external view returns (uint256);
    function getServiceKeywordCount(string calldata) external view returns (uint256);
    function getWantToBuyKeywordCount(string calldata) external view returns (uint256);
    function getAllKeywordCount(string calldata) external view returns (uint256);
}

/// @title ProductFactoryReader - Product Query Interface
/// @author WEB3GUARANTEE
/// @notice Read-only query functions for product listings, split from ProductFactory for EIP-170 size compliance
contract ProductFactoryReader {

    address public factory;
    address public keywords;
    uint256 public constant MAX_PAGE_SIZE = 50;

    constructor(address _factory, address _keywords, address _settings) {
        factory = _factory;
        keywords = _keywords;
        settingsAddr = _settings;
    }

    // ==================== Keyword Queries ====================

    /// @notice Paginated pending keywords
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Keyword string array
    function getPendingKeywords(uint256 offset, uint256 limit) external view returns (string[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = IKeywordsState(keywords).getPendingCount();
        if (offset >= total) return new string[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        string[] memory result = new string[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            bytes32 key = IKeywordsState(keywords).pendingKeywordKeys(i);
            result[i - offset] = IKeywordsState(keywords).keywordText(key);
        }
        return result;
    }

    /// @notice Get pending keyword count
    /// @return Pending count
    function getPendingKeywordCount() external view returns (uint256) {
        return IKeywordsState(keywords).getPendingCount();
    }

    /// @notice Paginated submitter keywords with status
    /// @param _submitter Submitter address
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return resultKeywords Keyword array
    /// @return statuses Status array (0=pending, 1=approved, 2=rejected)
    /// @return types Product type array
    /// @return total Total keyword count for submitter
    function getSubmitterKeywords(address _submitter, uint256 offset, uint256 limit) external view returns (
        string[] memory resultKeywords, uint8[] memory statuses, uint8[] memory types, uint256 total
    ) {
        total = IKeywordsState(keywords).getSubmitterKeywordCount(_submitter);
        if (offset >= total) return (new string[](0), new uint8[](0), new uint8[](0), total);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;
        resultKeywords = new string[](size);
        statuses = new uint8[](size);
        types = new uint8[](size);
        IKeywordsState k = IKeywordsState(keywords);
        for (uint256 i = 0; i < size;) {
            bytes32 key = k.submitterKeywordKeys(_submitter, offset + i);
            resultKeywords[i] = k.keywordText(key);
            types[i] = k.keywordTypeByKey(key);
            if (k.approvedKeywordKeys(key)) {
                statuses[i] = 1;
            } else if (k.isPendingKey(key)) {
                statuses[i] = 0;
            } else {
                statuses[i] = 2;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Paginated all keywords
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Keyword string array
    function getAllKeywords(string calldata language, uint256 offset, uint256 limit) external view returns (string[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = IProductFactoryState(factory).getLanguageKeywordCount(language);
        if (offset >= total) return new string[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        string[] memory result = new string[](end - offset);
        IKeywordsState k = IKeywordsState(keywords);
        for (uint256 i = offset; i < end; i++) {
            bytes32 key = IProductFactoryState(factory).keywordKeysByLanguage(language, i);
            result[i - offset] = k.keywordText(key);
        }
        return result;
    }

    /// @notice Get keyword count
    /// @return Keyword count
    function getKeywordCount(string calldata language) external view returns (uint256) {
        return IProductFactoryState(factory).getLanguageKeywordCount(language);
    }

    /// @notice Paginated keywords by type
    /// @param _type Product type (0=physical, 1=virtual, 2=service)
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Keyword string array
    function getKeywordsByType(string calldata language, uint8 _type, uint256 offset, uint256 limit) external view returns (string[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = _getKeywordCountByType(language, _type);
        if (offset >= total) return new string[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        string[] memory result = new string[](end - offset);
        IKeywordsState k = IKeywordsState(keywords);
        for (uint256 i = offset; i < end; i++) {
            bytes32 key;
            if (_type == 0) key = k.physicalKeywordKeysByLanguage(language, i);
            else if (_type == 1) key = k.virtualKeywordKeysByLanguage(language, i);
            else if (_type == 2) key = k.serviceKeywordKeysByLanguage(language, i);
            else key = k.wantToBuyKeywordKeysByLanguage(language, i);
            result[i - offset] = k.keywordText(key);
        }
        return result;
    }

    /// @notice Get keyword count by type
    /// @param _type Product type
    /// @return Keyword count
    function getKeywordCountByType(string calldata language, uint8 _type) external view returns (uint256) {
        return _getKeywordCountByType(language, _type);
    }

    function _getKeywordCountByType(string calldata language, uint8 _type) internal view returns (uint256) {
        IKeywordsState k = IKeywordsState(keywords);
        if (_type == 0) return k.getPhysicalKeywordCount(language);
        if (_type == 1) return k.getVirtualKeywordCount(language);
        if (_type == 2) return k.getServiceKeywordCount(language);
        return k.getWantToBuyKeywordCount(language);
    }

    /// @notice Get product count under a keyword
    /// @param keyword Keyword
    /// @return Product count
    function getKeywordProductCount(string calldata language, string calldata keyword) external view returns (uint256) {
        return IProductFactoryState(factory).getKeywordProductCountByLanguage(language, keyword);
    }

    // ==================== Product Queries ====================

    /// @notice Paginated products by keyword
    /// @param keyword Keyword
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Product address array
    function getProductsByKeyword(string calldata language, string calldata keyword, uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = IProductFactoryState(factory).getKeywordProductCountByLanguage(language, keyword);
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        bytes32 key = keccak256(abi.encodePacked(language, ":", keyword));
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = IProductFactoryState(factory).keywordToProducts(key, i);
        }
        return result;
    }

    function getProductsByLanguage(string calldata language, uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = IProductFactoryState(factory).getLanguageProductCount(language);
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = IProductFactoryState(factory).productsByLanguage(language, i);
        }
        return result;
    }

    /// @notice Get all active products by seller
    /// @param _seller Seller address
    /// @return Product address array
    function getActiveProductsBySeller(address _seller) external view returns (address[] memory) {
        uint256 count = IProductFactoryState(factory).activeProductCount(_seller);
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count;) {
            result[i] = IProductFactoryState(factory).activeProducts(_seller, i);
            unchecked { ++i; }
        }
        return result;
    }

    /// @notice Get seller's products under a specific keyword
    /// @param _seller Seller address
    /// @param keyword Keyword
    /// @return Matching product address array
    function getSellerProductsByKeyword(address _seller, string calldata language, string calldata keyword) external view returns (address[] memory) {
        IProductFactoryState f = IProductFactoryState(factory);
        uint256 count = f.activeProductCount(_seller);
        address[] memory tmp = new address[](count);
        uint256 matched = 0;
        for (uint256 i = 0; i < count;) {
            address product = f.activeProducts(_seller, i);
            string memory productKw = f.productKeyword(product);
            string memory productLang = f.productLanguage(product);
            if (keccak256(bytes(productKw)) == keccak256(bytes(keyword)) && keccak256(bytes(productLang)) == keccak256(bytes(language))) {
                tmp[matched] = product;
                matched++;
            }
            unchecked { ++i; }
        }
        address[] memory result = new address[](matched);
        for (uint256 i = 0; i < matched;) {
            result[i] = tmp[i];
            unchecked { ++i; }
        }
        return result;
    }

    // ==================== Archive Queries ====================

    /// @notice Get seller archived products (paginated, by generation)
    /// @param _seller Seller address
    /// @param generation Archive generation
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Product address array
    function getSellerArchive(address _seller, uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        ArchiveStore store = IProductFactoryState(factory).sellerArchives(generation);
        return store.getUserRecords(_seller, offset, limit);
    }

    /// @notice Get seller archive generation count
    /// @return Generation count
    function getSellerArchiveCount() external view returns (uint256) {
        return IProductFactoryState(factory).getSellerArchiveCount();
    }

    /// @notice Get buyer order archive (paginated, by generation)
    /// @param _buyer Buyer address
    /// @param generation Archive generation
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Product address array
    function getBuyerOrders(address _buyer, uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        ArchiveStore store = IProductFactoryState(factory).buyerArchives(generation);
        return store.getUserRecords(_buyer, offset, limit);
    }

    /// @notice Get buyer archive generation count
    /// @return Generation count
    function getBuyerArchiveCount() external view returns (uint256) {
        return IProductFactoryState(factory).getBuyerArchiveCount();
    }

    /// @notice Get global product archive (paginated, by generation)
    /// @param generation Archive generation
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Product address array
    function getAllProducts(uint256 generation, uint256 offset, uint256 limit) external view returns (address[] memory) {
        ArchiveStore store = IProductFactoryState(factory).productArchives(generation);
        return store.getGlobalRecords(offset, limit);
    }

    /// @notice Get product archive generation count
    /// @return Generation count
    function getProductArchiveCount() external view returns (uint256) {
        return IProductFactoryState(factory).getProductArchiveCount();
    }

    // ==================== Arbitration Queries ====================

    /// @notice Paginated arbitrating products
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Product address array
    function getArbitratingProducts(uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = IProductFactoryState(factory).getArbitratingProductCount();
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = IProductFactoryState(factory).arbitratingProducts(i);
        }
        return result;
    }

    /// @notice Get arbitrating product count
    /// @return Arbitrating product count
    function getArbitratingProductCount() external view returns (uint256) {
        return IProductFactoryState(factory).getArbitratingProductCount();
    }

    // ==================== Deposit/Delist Queries ====================

    /// @notice Check if seller can withdraw deposit (no active products and delist cooldown passed)
    /// @param _seller Seller address
    /// @return Whether withdrawal is allowed
    function canWithdrawDeposit(address _seller) external view returns (bool) {
        IProductFactoryState f = IProductFactoryState(factory);
        if (f.activeProductCount(_seller) > 0) return false;
        uint256 delist = f.lastDelistTime(_seller);
        if (delist == 0) return true;
        return block.timestamp >= delist + f.DELIST_COOLDOWN();
    }

    /// @notice Get seller delist info
    /// @param _seller Seller address
    /// @return Active product count, last delist time, whether deposit withdrawal is allowed
    function getDelistInfo(address _seller) external view returns (uint256, uint256, bool) {
        IProductFactoryState f = IProductFactoryState(factory);
        uint256 activeCount = f.activeProductCount(_seller);
        uint256 delist = f.lastDelistTime(_seller);
        bool ok = true;
        if (activeCount > 0) {
            ok = false;
        } else if (delist > 0 && block.timestamp < delist + f.DELIST_COOLDOWN()) {
            ok = false;
        }
        return (activeCount, delist, ok);
    }

    // ==================== Expired Order Queries ====================

    /// @notice Get all expired unconfirmed orders for a seller
    /// @param _seller Seller address
    /// @return expiredProducts Expired product address array
    /// @return expiredOrderIds Expired order ID array
    /// @return amounts Order amount array
    function getExpiredOrders(address _seller) external view returns (
        address[] memory expiredProducts, bytes16[] memory expiredOrderIds, uint256[] memory amounts
    ) {
        IProductFactoryState f = IProductFactoryState(factory);
        uint256 len = f.activeProductCount(_seller);
        uint256 maxOrders = len * 20;
        address[] memory tmpAddrs = new address[](maxOrders);
        bytes16[] memory tmpIds = new bytes16[](maxOrders);
        uint256[] memory tmpAmts = new uint256[](maxOrders);
        uint256 count = 0;
        for (uint256 i = 0; i < len;) {
            address product = f.activeProducts(_seller, i);
            count = _collectExpired(product, tmpAddrs, tmpIds, tmpAmts, count, maxOrders);
            unchecked { ++i; }
        }
        expiredProducts = new address[](count);
        expiredOrderIds = new bytes16[](count);
        amounts = new uint256[](count);
        for (uint256 i = 0; i < count;) {
            expiredProducts[i] = tmpAddrs[i];
            expiredOrderIds[i] = tmpIds[i];
            amounts[i] = tmpAmts[i];
            unchecked { ++i; }
        }
    }

    function _collectExpired(address product, address[] memory ta, bytes16[] memory ti, uint256[] memory tm, uint256 count, uint256 max) internal view returns (uint256) {
        (bool ok, bytes memory data) = product.staticcall(abi.encodeWithSelector(IProductTemplate.getActiveOrderExpiryInfos.selector));
        if (!ok) return count;
        (bytes16[] memory ids, OrderStatus[] memory statuses, uint64[] memory deadlines, uint256[] memory amts) = abi.decode(data, (bytes16[], OrderStatus[], uint64[], uint256[]));
        for (uint256 j = 0; j < ids.length; j++) {
            if ((statuses[j] == OrderStatus.Shipped || statuses[j] == OrderStatus.Delivered) && deadlines[j] > 0 && block.timestamp > deadlines[j]) {
                if (count < max) { ta[count] = product; ti[count] = ids[j]; tm[count] = amts[j]; count++; }
            }
        }
        return count;
    }

    // ==================== Simple Getters ====================

    /// @notice Get total product count
    /// @return Total product count
    function getProductCount() external view returns (uint256) {
        return IProductFactoryState(factory).totalProductCount();
    }

    /// @notice Check if product was created by factory
    /// @param product Product address
    /// @return Whether it is a factory product
    function isFactoryProduct(address product) external view returns (bool) {
        return IProductFactoryState(factory).isFactoryProduct(product);
    }

    // ==================== Batch auto-receive (merged from ProductFactoryHelper) ====================

    uint256 public constant MAX_BATCH = 50;
    address public settingsAddr;

    event BatchAutoReceived(address indexed caller, uint256 successCount);

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    function batchAutoReceive(address[] calldata products, bytes16[] calldata orderIds) external noContract {
        if (products.length != orderIds.length) revert LengthMismatch();
        if (products.length > MAX_BATCH) revert TooManyProducts();
        IProductFactoryState f = IProductFactoryState(factory);
        uint256 success = 0;
        for (uint256 i = 0; i < products.length;) {
            if (!f.isFactoryProduct(products[i])) { unchecked { ++i; } continue; }
            try IProductTemplate(products[i]).triggerAutoReceive(orderIds[i]) {
                success++;
            } catch {}
            unchecked { ++i; }
        }
        if (success == 0) revert NoExpiredOrders();
        emit BatchAutoReceived(msg.sender, success);
    }

    // ==================== Batch Product Info ====================

    struct ProductInfoResult {
        address addr;
        uint8 pType;
        address owner;
        string keyword;
        string language;
        string metadataURI;
        bool delisted;
        uint256 activeOrderCount;
        uint8 deliveryMethod;
        uint256 requestPrice;
        uint256 stock;
        uint256 originalStock;
        string[] specNames;
        uint256[] specPrices;
        uint256[] specStocks;
    }

    function batchGetProductInfos(address[] calldata products) external view returns (ProductInfoResult[] memory results) {
        uint256 len = products.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        results = new ProductInfoResult[](len);
        IProductFactoryState f = IProductFactoryState(factory);
        for (uint256 i; i < len; i++) {
            address p = products[i];
            results[i].addr = p;
            uint8 pt = f.productType(p);
            results[i].pType = pt;
            if (pt == 0) _fillPhysical(results[i], p);
            else if (pt == 1) _fillVirtual(results[i], p);
            else if (pt == 2) _fillService(results[i], p);
            else if (pt == 3) _fillWantToBuy(results[i], p);
        }
    }

    function _fillPhysical(ProductInfoResult memory r, address p) internal view {
        (bool ok, bytes memory data) = p.staticcall(abi.encodeWithSelector(IPhysicalProductInfo.getProductInfo.selector));
        if (!ok) return;
        _decodePhysical(r, data);
    }

    function _decodePhysical(ProductInfoResult memory r, bytes memory data) internal pure {
        (address s, string memory kw, string memory lang, string memory uri,
         uint8 dm, bool dl, uint256 aoc,
         string[] memory sn, uint256[] memory sp, uint256[] memory ss
        ) = abi.decode(data, (address, string, string, string, uint8, bool, uint256, string[], uint256[], uint256[]));
        r.owner = s; r.keyword = kw; r.language = lang; r.metadataURI = uri;
        r.deliveryMethod = dm; r.delisted = dl; r.activeOrderCount = aoc;
        r.specNames = sn; r.specPrices = sp; r.specStocks = ss;
    }

    function _fillVirtual(ProductInfoResult memory r, address p) internal view {
        (bool ok, bytes memory data) = p.staticcall(abi.encodeWithSelector(IVirtualProductInfo.getProductInfo.selector));
        if (!ok) return;
        _decodeVirtual(r, data);
    }

    function _decodeVirtual(ProductInfoResult memory r, bytes memory data) internal pure {
        (address s, string memory kw, string memory lang, string memory uri,
         bool dl, uint256 aoc,
         string[] memory sn, uint256[] memory sp, uint256[] memory ss
        ) = abi.decode(data, (address, string, string, string, bool, uint256, string[], uint256[], uint256[]));
        r.owner = s; r.keyword = kw; r.language = lang; r.metadataURI = uri;
        r.delisted = dl; r.activeOrderCount = aoc;
        r.specNames = sn; r.specPrices = sp; r.specStocks = ss;
    }

    function _fillService(ProductInfoResult memory r, address p) internal view {
        (bool ok, bytes memory data) = p.staticcall(abi.encodeWithSelector(IServiceProductInfo.getProductInfo.selector));
        if (!ok) return;
        _decodeService(r, data);
    }

    function _decodeService(ProductInfoResult memory r, bytes memory data) internal pure {
        (address s, string memory kw, string memory lang, string memory uri,
         bool dl, uint256 aoc, uint256 ts,
         string[] memory sn, uint256[] memory sp, uint256[] memory ss
        ) = abi.decode(data, (address, string, string, string, bool, uint256, uint256, string[], uint256[], uint256[]));
        r.owner = s; r.keyword = kw; r.language = lang; r.metadataURI = uri;
        r.delisted = dl; r.activeOrderCount = aoc; r.stock = ts;
        r.specNames = sn; r.specPrices = sp; r.specStocks = ss;
    }

    function _fillWantToBuy(ProductInfoResult memory r, address p) internal view {
        (bool ok, bytes memory data) = p.staticcall(abi.encodeWithSelector(IWantToBuyInfo.getProductInfo.selector));
        if (!ok) return;
        _decodeWantToBuy(r, data);
    }

    function _decodeWantToBuy(ProductInfoResult memory r, bytes memory data) internal pure {
        (address b, string memory kw, string memory lang, string memory uri,
         bool dl, uint256 aoc, uint256 rp, uint256 st, uint256 os
        ) = abi.decode(data, (address, string, string, string, bool, uint256, uint256, uint256, uint256));
        r.owner = b; r.keyword = kw; r.language = lang; r.metadataURI = uri;
        r.delisted = dl; r.activeOrderCount = aoc;
        r.requestPrice = rp; r.stock = st; r.originalStock = os;
    }

    // ==================== Batch Product Extras (deposit/weight/bidding) ====================

    struct ProductExtras {
        address addr;
        uint256 depositBalance;
        uint256 totalOrders;
        bool isBiddingTop;
    }

    function batchGetProductExtras(address[] calldata products) external view returns (ProductExtras[] memory results) {
        uint256 len = products.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        results = new ProductExtras[](len);
        IProductFactoryState f = IProductFactoryState(factory);
        address depFactory = f.depositFactoryAddr();
        address kwW = f.keywordWeightAddr();
        address kwA = f.keywordAuctionAddr();
        address usdt = f.usdtAddr();
        for (uint256 i; i < len; i++) {
            results[i].addr = products[i];
            _fillDeposit(results[i], products[i], depFactory, usdt);
            _fillWeightAndBidding(results[i], products[i], kwW, kwA);
        }
    }

    function _fillDeposit(ProductExtras memory r, address p, address depFactory, address usdt) internal view {
        try IProductTemplate(p).seller() returns (address seller) {
            try IDepositFactory(depFactory).getDeposit(seller) returns (address depAddr) {
                try IMerchantDeposit(depAddr).getAvailableBalance(usdt) returns (uint256 bal) {
                    r.depositBalance += bal;
                } catch {}
            } catch {}
        } catch {}
    }

    function _fillWeightAndBidding(ProductExtras memory r, address p, address kwW, address kwA) internal view {
        try IKeywordWeight(kwW).getTotalOrders(p) returns (uint256 o) {
            r.totalOrders = o;
        } catch {}
        try IProductTemplate(p).language() returns (string memory lang) {
            try IProductTemplate(p).keyword() returns (string memory kw) {
                if (bytes(kw).length > 0) {
                    try IKeywordAuction(kwA).isTopProduct(lang, kw, p) returns (bool top) {
                        r.isBiddingTop = top;
                    } catch {}
                }
            } catch {}
        } catch {}
    }

    // ==================== Batch Keyword Product Counts ====================

    function batchGetKeywordProductCounts(string calldata language, string[] calldata _kws) external view returns (uint256[] memory counts) {
        uint256 len = _kws.length;
        if (len > MAX_PAGE_SIZE) len = MAX_PAGE_SIZE;
        counts = new uint256[](len);
        IProductFactoryState f = IProductFactoryState(factory);
        for (uint256 i; i < len; i++) {
            try f.getKeywordProductCountByLanguage(language, _kws[i]) returns (uint256 c) {
                counts[i] = c;
            } catch {}
        }
    }

    // ==================== Ranked Pagination with Seed ====================

    /// @notice Check if a product is available (not delisted)
    /// @dev Uses staticcall to avoid revert if product contract is invalid
    /// @param product Product address
    /// @return Whether product is available (not delisted)
    function _isStockAvailable(address product) internal view returns (bool) {
        (bool success, bytes memory data) = product.staticcall(
            abi.encodeWithSignature("delisted()")
        );
        if (!success || data.length < 32) return false;
        bool isDelisted = abi.decode(data, (bool));
        return !isDelisted;
    }

    /// @notice Get ranked products by keyword with pagination and randomization
    /// @dev First page (offset=0): Top ≤20 + random fill to 21; Subsequent pages: pure random 21
    /// @param language Language code
    /// @param keyword Keyword
    /// @param offset Page offset (0 for first page)
    /// @param limit Items per page (frontend always sends 21)
    /// @param seedParam Random seed parameter from frontend
    /// @return products Product address array (filtered for stock availability)
    /// @return currentSeed Current seed value (latest if offset==0, seedParam otherwise)
    /// @return hasMore Whether more products are available
    function getRankedProductsByKeyword(
        string calldata language,
        string calldata keyword,
        uint256 offset,
        uint256 limit,
        uint256 seedParam
    ) external view returns (
        address[] memory products,
        uint256 currentSeed,
        bool hasMore
    ) {
        // A. Get base data
        bytes32 key = keccak256(abi.encodePacked(language, ":", keyword));

        // Fetch the total count instead of reading the whole array
        uint256 totalCount = IProductFactoryState(factory).getKeywordProductCountByLanguage(language, keyword);
        if (totalCount == 0) return (new address[](0), 0, false);

        uint256 seed = seedParam ^ IProductFactoryState(factory).keywordSeed(key);

        // Set currentSeed: return latest seed if offset==0, otherwise return seedParam
        currentSeed = (offset == 0) ? seed : seedParam;

        // B. First page special handling (offset == 0)
        if (offset == 0) {
            products = new address[](limit);
            uint256 topCount;

            // 1. Get top bidding products and filter for stock availability
            {
                (address[20] memory topArray, ) = IKeywordAuction(
                    IProductFactoryState(factory).keywordAuctionAddr()
                ).getTopProducts(language, keyword);

                // Directly filter and copy valid top products
                for (uint256 i = 0; i < 20 && topCount < 20; i++) {
                    if (topArray[i] == address(0)) break;
                    if (_isStockAvailable(topArray[i])) {
                        products[topCount++] = topArray[i];
                    }
                }
            }

            // 2. Random fill remaining slots from non-top products
            uint256 filled = topCount;
            uint256 attempt = 0;
            uint256 maxAttempts = totalCount < 1000 ? totalCount * 2 : 2000; // cap the number of attempts

            while (filled < limit && attempt < maxAttempts) {
                address candidate = IProductFactoryState(factory).keywordToProducts(
                    key,
                    (attempt * 1000003 + seed) % totalCount
                );

                // Check if already in results and has stock
                if (_isStockAvailable(candidate)) {
                    bool isDuplicate = false;
                    for (uint256 k = 0; k < filled; k++) {
                        if (products[k] == candidate) {
                            isDuplicate = true;
                            break;
                        }
                    }
                    if (!isDuplicate) {
                        products[filled++] = candidate;
                    }
                }
                attempt++;
            }

            // Return actual collected count
            address[] memory finalResult = new address[](filled);
            for (uint256 i = 0; i < filled; i++) {
                finalResult[i] = products[i];
            }
            hasMore = (totalCount > filled);
            return (finalResult, currentSeed, hasMore);
        }

        // C. Subsequent pages (offset > 0) - pure random mapping
        products = new address[](limit);
        uint256 collected = 0;
        uint256 virtualIdx = offset;
        uint256 maxVirtualIdx = totalCount < 1000 ? totalCount * 3 : offset + 3000; // cap the virtual index

        while (collected < limit && virtualIdx < maxVirtualIdx) {
            // Read by index
            uint256 mappedIdx = (virtualIdx * 1000003 + seed) % totalCount;
            address candidate = IProductFactoryState(factory).keywordToProducts(key, mappedIdx);

            if (_isStockAvailable(candidate)) {
                bool duplicate = false;
                for (uint256 k = 0; k < collected; k++) {
                    if (products[k] == candidate) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    products[collected++] = candidate;
                }
            }
            virtualIdx++;
        }

        // D. Return actual collected count
        address[] memory result = new address[](collected);
        for (uint256 i = 0; i < collected; i++) {
            result[i] = products[i];
        }
        hasMore = (virtualIdx < maxVirtualIdx && collected == limit);
        return (result, currentSeed, hasMore);
    }

    /// @notice Ranked service products for one city, mirroring getRankedProductsByKeyword for physical/virtual.
    ///         Service listings live in ServiceLocationIndex (keyword->country->province->city), not the flat
    ///         keyword map, so ranking is done here: keyword-bidding winners (KeywordAuction.getTopServiceProducts,
    ///         keyed on the same full hierarchy) are pinned to the front, then the rest of the city's products
    ///         follow in insertion order. Service has no per-keyword seed, so ordering is deterministic (no random fill).
    /// @return products page of addresses; hasMore whether further pages exist
    function getRankedServiceProductsByCity(
        string calldata language,
        string calldata keyword,
        string calldata country,
        string calldata province,
        string calldata city,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory products, bool hasMore) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (limit == 0) return (new address[](0), false);

        address sli = IProductFactoryState(factory).serviceLocationIndex();
        if (sli == address(0)) return (new address[](0), false);

        bytes32 cityKey = keccak256(abi.encode(language, keyword, country, province, city));
        uint256 totalCount = IServiceLocationIndex(sli).getCityProductCount(language, keyword, country, province, city);
        if (totalCount == 0) return (new address[](0), false);

        // 1. Pinned bidding winners for this exact city (bid key == cityKey), in-city + in-stock, dedup.
        address[20] memory pinned;
        uint256 pinnedCount;
        {
            (address[20] memory topArr, ) = IKeywordAuction(
                IProductFactoryState(factory).keywordAuctionAddr()
            ).getTopServiceProducts(language, keyword, country, province, city);
            for (uint256 i = 0; i < 20; ) {
                address p = topArr[i];
                if (p == address(0)) break;
                if (IServiceLocationIndex(sli).productCityKey(p) == cityKey && _isStockAvailable(p)) {
                    pinned[pinnedCount++] = p;
                }
                unchecked { i++; }
            }
        }

        // 2. Walk the virtual ordering [pinned..., city products excl. pinned & out-of-stock] and slice [offset, offset+limit).
        address[] memory buf = new address[](limit);
        uint256 got;
        uint256 logicalIdx;

        for (uint256 i = 0; i < pinnedCount && got < limit; ) {
            if (logicalIdx >= offset) { buf[got++] = pinned[i]; }
            unchecked { logicalIdx++; i++; }
        }

        uint256 ci;
        for (ci = 0; ci < totalCount && got < limit; ) {
            address c = IServiceLocationIndex(sli).cityProducts(cityKey, ci);
            bool isPinned = false;
            for (uint256 k = 0; k < pinnedCount; ) {
                if (pinned[k] == c) { isPinned = true; break; }
                unchecked { k++; }
            }
            if (!isPinned && _isStockAvailable(c)) {
                if (logicalIdx >= offset) { buf[got++] = c; }
                unchecked { logicalIdx++; }
            }
            unchecked { ci++; }
        }

        products = new address[](got);
        for (uint256 i = 0; i < got; ) { products[i] = buf[i]; unchecked { i++; } }
        // More remain if we filled the page and haven't exhausted the city list yet.
        hasMore = (got == limit) && (ci < totalCount);
        return (products, hasMore);
    }
}
