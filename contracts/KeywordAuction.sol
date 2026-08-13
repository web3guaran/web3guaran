// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #13: KeywordAuction — Keyword bidding ranking contract (product-level)
 * Responsibility: Manage language-scoped keyword bidding, top 20 products pinned
 */

import "./interfaces/Interfaces.sol";

/// @title KeywordAuction - Daily Language-scoped Keyword Bidding for Search Ranking
/// @author WEB3GUARANTEE
/// @notice Manages daily bidding by (language, keyword), so identical keywords in different languages do not share rankings
contract KeywordAuction {

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    uint256 public constant TOP_SIZE = 20;
    uint256 public constant MAX_ACTIVE_KEYWORDS_PER_DAY = 50000;
    uint256 public minBid;

    // ===== BSC Mainnet USDT Address =====
    address public constant USDT_ADDRESS = 0x55d398326f99059fF775485246999027B3197955;

    mapping(uint256 => mapping(bytes32 => address[20])) internal topProducts;
    mapping(uint256 => mapping(bytes32 => mapping(address => uint256))) public productBid;
    mapping(uint256 => mapping(bytes32 => mapping(address => uint256))) public productBidTime;
    mapping(uint256 => mapping(bytes32 => uint256)) public topCount;

    /// @notice Active keyword count tracking (guards against unbounded-keyword DoS)
    mapping(uint256 => uint256) public activeKeywordsCountPerDay;
    mapping(uint256 => mapping(bytes32 => bool)) public keywordActiveOnDay;

    IERC20 public usdt;
    address public owner;
    IPlatformSettings public settings;
    address public productFactoryAddr;

    event BidPlaced(bytes32 indexed keywordKey, address indexed product, address indexed merchant, uint256 amount, uint256 totalBid, uint256 day);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        usdt = IERC20(USDT_ADDRESS);
        uint8 dec = IERC20(USDT_ADDRESS).decimals();
        minBid = 10 ** uint256(dec);
    }

    function setSettings(address _settings) external onlyOwner {
        if (_settings == address(0)) revert ZeroAddress();
        settings = IPlatformSettings(_settings);
    }

    function setProductFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        productFactoryAddr = _factory;
    }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    function getCurrentDay() public view returns (uint256) {
        return block.timestamp / 86400;
    }

    function getKeywordKey(string memory language, string memory keyword) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(language, ":", keyword));
    }

    /// @dev Send platform fee. Routes through PlatformFeeSplitter (auto 3-way split) when configured.
    ///      [C-07 fix]: No fallback to platformWallet when splitter is configured but fails (e.g. blacklisted payee).
    ///      Falls back to platformWallet ONLY when splitter is not configured at all.
    ///      Atomic rollback via external self-call + try/catch.
    function _payPlatform(uint256 amount) internal {
        address splitter = settings.getFeeSplitter();
        if (splitter != address(0)) {
            // [C-07 fix]: When splitter is configured, failure must revert (no silent fallback)
            this._splitterRoute(msg.sender, splitter, amount);
            return;
        }
        // Splitter not configured: use single-recipient platformWallet
        address platformWallet = settings.getPlatformWallet();
        if (platformWallet == address(0)) revert ZeroAddress();
        if (!usdt.transferFrom(msg.sender, platformWallet, amount)) revert TransferFailed();
    }

    /// @dev External wrapper for atomic try/catch rollback. Self-call only.
    function _splitterRoute(address payer, address splitter, uint256 amount) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        if (!usdt.transferFrom(payer, splitter, amount)) revert TransferFailed();
        IPlatformFeeSplitter(splitter).distribute(address(usdt), amount);
    }

    function bid(string calldata language, string calldata keyword, address product, uint256 amount) external noContract {
        if (amount < minBid) revert MinBid1USDT();
        if (product == address(0)) revert ZeroAddress();
        if (!_isSupportedLanguage(language)) revert InvalidLanguage();

        IProductFactory pf = IProductFactory(productFactoryAddr);
        if (!pf.isFactoryProduct(product)) revert NotFactoryProduct();

        IProductTemplate template = IProductTemplate(product);

        // WantToBuy (type 3) publisher is buyer(); the template has no seller() function,
        // so template.seller() would staticcall a non-existent selector and revert. Route
        // the ownership check to buyer() for type 3, seller() for all other product types.
        address productOwner = pf.productType(product) == 3
            ? IWantToBuyTemplate(product).buyer()
            : template.seller();
        if (productOwner != msg.sender) revert NotSeller();

        string memory productLang = template.language();
        if (keccak256(bytes(productLang)) != keccak256(bytes(language))) revert Mismatch();

        string memory productKw = template.keyword();
        if (keccak256(bytes(productKw)) != keccak256(bytes(keyword))) revert Mismatch();

        if (template.delisted()) revert IsDelisted();

        bytes32 key = getKeywordKey(language, keyword);
        uint256 day = getCurrentDay();

        // Enforce the active-keyword count cap (on first bid of the day)
        if (!keywordActiveOnDay[day][key]) {
            if (activeKeywordsCountPerDay[day] >= MAX_ACTIVE_KEYWORDS_PER_DAY) revert TooHigh();
            keywordActiveOnDay[day][key] = true;
            activeKeywordsCountPerDay[day]++;
        }

        // Audit fix [L-1]: CEI pattern — record state (Effects) before external call (Interactions)
        (uint256 recordedDay, uint256 totalBid) = _recordBidAndRank(key, product, amount);

        // Audit note [H-03]: Bid funds transfer directly to platform wallet — intentional design.
        // Keyword bidding is a daily advertising fee (like Google Ads), not an escrow.
        // No refund mechanism is needed; merchants pay to rank higher for that day.
        // platformWallet is controlled by Owner via PlatformSettings; admin key risk is mitigated by multisig.
        // Platform fee prefers the split routing splitter (30/30/40); falls back to single-recipient platformWallet when unconfigured
        _payPlatform(amount);

        emit BidPlaced(key, product, msg.sender, amount, totalBid, recordedDay);
    }

    function _recordBidAndRank(bytes32 key, address product, uint256 amount) internal returns (uint256 day, uint256 totalBid) {
        day = getCurrentDay();
        productBid[day][key][product] += amount;
        totalBid = productBid[day][key][product];
        if (productBidTime[day][key][product] == 0) {
            productBidTime[day][key][product] = block.timestamp;
        }
        _updateTop20(day, key, product);
    }

    function _updateTop20(uint256 day, bytes32 key, address product) internal {
        address[20] storage top = topProducts[day][key];
        uint256 senderBid = productBid[day][key][product];
        uint256 senderTime = productBidTime[day][key][product];
        uint256 listEnd = topCount[day][key];

        uint256 pos = type(uint256).max;
        for (uint256 i = 0; i < listEnd; ) {
            if (top[i] == product) { pos = i; break; }
            unchecked { i++; }
        }

        bool rankingChanged = false;
        if (pos == type(uint256).max) {
            if (listEnd < TOP_SIZE) {
                pos = listEnd;
                top[pos] = product;
                topCount[day][key] = listEnd + 1;
                rankingChanged = true;
            } else {
                uint256 lastBid = productBid[day][key][top[TOP_SIZE - 1]];
                uint256 lastTime = productBidTime[day][key][top[TOP_SIZE - 1]];
                bool canReplace = senderBid > lastBid ||
                    (senderBid == lastBid && senderTime < lastTime);
                if (!canReplace) return;
                pos = TOP_SIZE - 1;
                top[pos] = product;
                rankingChanged = true;
            }
        }

        while (pos > 0) {
            address prev = top[pos - 1];
            uint256 prevBid = productBid[day][key][prev];
            uint256 prevTime = productBidTime[day][key][prev];
            bool shouldSwap = senderBid > prevBid ||
                (senderBid == prevBid && senderTime < prevTime);
            if (!shouldSwap) break;
            top[pos] = prev;
            unchecked { pos--; }
            rankingChanged = true;
        }
        top[pos] = product;

        if (rankingChanged) {
            IProductTemplate template = IProductTemplate(product);
            IProductFactory(productFactoryAddr).bumpSeedExternal(template.language(), template.keyword());
        }
    }

    function getTopProducts(string calldata language, string calldata keyword) external view returns (
        address[20] memory products, uint256[20] memory amounts
    ) {
        uint256 day = getCurrentDay();
        bytes32 key = getKeywordKey(language, keyword);
        products = topProducts[day][key];
        uint256 count = topCount[day][key];
        for (uint256 i = 0; i < count; ) {
            amounts[i] = productBid[day][key][products[i]];
            unchecked { i++; }
        }
    }

    function isTopProduct(string calldata language, string calldata keyword, address product) external view returns (bool) {
        uint256 day = getCurrentDay();
        bytes32 key = getKeywordKey(language, keyword);
        address[20] storage top = topProducts[day][key];
        uint256 count = topCount[day][key];
        for (uint256 i = 0; i < count; ) {
            if (top[i] == product) return true;
            unchecked { i++; }
        }
        return false;
    }

    /// @notice Get today's active bidding keyword count (for monitoring)
    function getActiveKeywordsCountToday() external view returns (uint256) {
        return activeKeywordsCountPerDay[getCurrentDay()];
    }

    /// @notice Get the active keyword count for a given day
    function getActiveKeywordsCountByDay(uint256 day) external view returns (uint256) {
        return activeKeywordsCountPerDay[day];
    }

    function _isSupportedLanguage(string calldata language) internal pure returns (bool) {
        bytes32 lang = keccak256(bytes(language));
        return lang == keccak256(bytes("en")) ||
            lang == keccak256(bytes("es")) ||
            lang == keccak256(bytes("zh")) ||
            lang == keccak256(bytes("de")) ||
            lang == keccak256(bytes("fr")) ||
            lang == keccak256(bytes("ja")) ||
            lang == keccak256(bytes("pt")) ||
            lang == keccak256(bytes("ar")) ||
            lang == keccak256(bytes("ko")) ||
            lang == keccak256(bytes("id")) ||
            lang == keccak256(bytes("ru"));
    }

    // ==================== Service Product City-Level Bidding ====================

    /// @notice Service bidding key — full geographic hierarchy (keyword -> country -> province -> city),
    ///         matching ServiceLocationIndex's cityKey exactly so rankings and listings share one key.
    ///         [FIX] Previously keyed on city only, which made same-named cities across provinces share
    ///         one leaderboard and never matched the location index used for display.
    function getServiceKey(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) public pure returns (bytes32) {
        return keccak256(abi.encode(language, keyword, country, province, city));
    }

    function bidService(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city, address product, uint256 amount) external noContract {
        if (amount < minBid) revert MinBid1USDT();
        if (product == address(0)) revert ZeroAddress();
        if (!_isSupportedLanguage(language)) revert InvalidLanguage();

        IProductFactory pf = IProductFactory(productFactoryAddr);
        if (!pf.isFactoryProduct(product)) revert NotFactoryProduct();
        if (pf.productType(product) != 2) revert Mismatch();

        IProductTemplate template = IProductTemplate(product);
        if (template.seller() != msg.sender) revert NotSeller();
        if (template.delisted()) revert IsDelisted();

        string memory productLang = template.language();
        if (keccak256(bytes(productLang)) != keccak256(bytes(language))) revert Mismatch();
        string memory productKw = template.keyword();
        if (keccak256(bytes(productKw)) != keccak256(bytes(keyword))) revert Mismatch();

        bytes32 key = getServiceKey(language, keyword, country, province, city);

        // [FIX] Bind the bid to the product's actual registered city. ServiceLocationIndex keys a
        // product on its (language,keyword,country,province,city); require the bid target to match so
        // a merchant cannot bid their service into a city where it isn't listed (fail fast, no wasted fee).
        address sli = pf.serviceLocationIndex();
        if (sli != address(0) && IServiceLocationIndex(sli).productCityKey(product) != key) revert Mismatch();

        uint256 day = getCurrentDay();

        // Enforce the active-keyword count cap (city-level keywords count too)
        if (!keywordActiveOnDay[day][key]) {
            if (activeKeywordsCountPerDay[day] >= MAX_ACTIVE_KEYWORDS_PER_DAY) revert TooHigh();
            keywordActiveOnDay[day][key] = true;
            activeKeywordsCountPerDay[day]++;
        }

        // CEI: state changes before external call
        (uint256 recordedDay, uint256 totalBid) = _recordBidAndRank(key, product, amount);

        // As above: platform fee prefers the split routing splitter
        _payPlatform(amount);

        emit BidPlaced(key, product, msg.sender, amount, totalBid, recordedDay);
    }

    function getTopServiceProducts(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) external view returns (
        address[20] memory products, uint256[20] memory amounts
    ) {
        uint256 day = getCurrentDay();
        bytes32 key = getServiceKey(language, keyword, country, province, city);
        products = topProducts[day][key];
        uint256 count = topCount[day][key];
        for (uint256 i = 0; i < count; ) {
            amounts[i] = productBid[day][key][products[i]];
            unchecked { i++; }
        }
    }

    function isTopServiceProduct(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city, address product) external view returns (bool) {
        uint256 day = getCurrentDay();
        bytes32 key = getServiceKey(language, keyword, country, province, city);
        address[20] storage top = topProducts[day][key];
        uint256 count = topCount[day][key];
        for (uint256 i = 0; i < count; ) {
            if (top[i] == product) return true;
            unchecked { i++; }
        }
        return false;
    }
}
