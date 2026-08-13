// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * ProductFactory — Product Factory Contract
 * Deploys three types of product contracts via EIP-1167 cloning, manages product indexes
 */

import "./interfaces/Interfaces.sol";
import "./ArchiveStore.sol";

// IServiceLocationIndex is declared in interfaces/Interfaces.sol (imported above)

/// @title ProductFactory - Product Deployment Factory
/// @author WEB3GUARANTEE
/// @notice Deploys product contracts via EIP-1167 minimal proxy, manages product indexes and keyword mappings
contract ProductFactory {

    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    address public owner;
    address public physicalTemplate;
    address public virtualTemplate;
    address public serviceTemplate;
    address public wantToBuyTemplate;
    address public settingsAddr;
    address public keywordWeightAddr;
    address public inviteRegistryAddr;
    address public keywordAuctionAddr;
    /// Dual payment channel: USDT address (hardcoded into factory at construction)
    address public usdtAddr;
    address public depositFactoryAddr;
    address public keywordsAddr;
    address public archiveTemplate;
    address public serviceLocationIndex;

    mapping(bytes32 => address[]) public keywordToProducts;
    mapping(bytes32 => uint256) public keywordSeed;  // Keyword randomization seed: keywordKey => seed
    bytes32[] public allKeywordKeys;
    mapping(bytes32 => bool) public keywordExists;
    mapping(string => bytes32[]) public keywordKeysByLanguage;
    mapping(string => address[]) public productsByLanguage;
    mapping(address => string) public productLanguage;
    /// @dev Position of each product within productsByLanguage[lang] for swap-pop removal on delist
    mapping(address => uint256) public productLanguageIndex;
    mapping(address => bool) public isFactoryProduct;
    mapping(address => uint8) public productType;
    mapping(address => uint256) public activeProductCount;
    mapping(address => address[]) public activeProducts;
    mapping(address => uint256) public activeProductIndex;
    mapping(address => uint256) public keywordProductIndex;
    mapping(address => string) public productKeyword;
    mapping(address => uint256) public lastDelistTime;
    address[] public arbitratingProducts;
    mapping(address => uint256) public arbitratingIndex;
    mapping(address => uint256) public arbitratingProductCount;

    ArchiveStore[] public productArchives;
    ArchiveStore public currentProductArchive;
    uint256 public totalProductCount;
    ArchiveStore[] public sellerArchives;
    ArchiveStore public currentSellerArchive;
    ArchiveStore[] public buyerArchives;
    ArchiveStore public currentBuyerArchive;

    // [C-01 fix]: Incremental counters to avoid nested loop DoS in view functions
    uint256 public activeSellerCount;      // Count of sellers with at least one active product
    uint256 public totalActiveProductCount; // Total count of active products across all sellers

    uint256 public constant MAX_PRODUCTS_WITHOUT_DEPOSIT = 5; // production
    uint256 public constant MAX_PRODUCTS_WITH_DEPOSIT = 20; // production
    uint256 public constant MAX_PRODUCTS_PER_SELLER = 20; // production
    uint256 public constant MAX_PRODUCTS_PER_KEYWORD = 100000;  // ✅ Maximum products per keyword (language+keyword combo)

    event ProductCreated(uint8 productType, address contractAddress, address indexed seller, string language, string keyword, bytes32 indexed keywordKey, string metadataURI);
    event ProductDelisted(address product, address indexed seller, uint256 remainingActive);
    event ProductsCleaned(string language, string keyword, uint256 cleaned);
    event DisputeCreated(address indexed product);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Audit note: owner is a multisig wallet (Gnosis Safe); all onlyOwner operations require multi-party signature confirmation
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address _physicalTpl, address _virtualTpl, address _serviceTpl,
        address _settings, address _keywordWeight, address _inviteRegistry,
        address _keywordAuction, address _depositFactory, address _keywords,
        address _usdt, address _archiveTemplate
    ) {
        owner = msg.sender;
        physicalTemplate = _physicalTpl;
        virtualTemplate = _virtualTpl;
        serviceTemplate = _serviceTpl;
        settingsAddr = _settings;
        keywordWeightAddr = _keywordWeight;
        inviteRegistryAddr = _inviteRegistry;
        keywordAuctionAddr = _keywordAuction;
        usdtAddr = _usdt;
        depositFactoryAddr = _depositFactory;
        keywordsAddr = _keywords;
        archiveTemplate = _archiveTemplate;
        currentProductArchive = ArchiveStore(_cloneArchive(_archiveTemplate));
        productArchives.push(currentProductArchive);
        currentSellerArchive = ArchiveStore(_cloneArchive(_archiveTemplate));
        sellerArchives.push(currentSellerArchive);
        currentBuyerArchive = ArchiveStore(_cloneArchive(_archiveTemplate));
        buyerArchives.push(currentBuyerArchive);
    }

    function setPhysicalTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); physicalTemplate = _tpl; }
    function setVirtualTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); virtualTemplate = _tpl; }
    function setServiceTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); serviceTemplate = _tpl; }
    function setWantToBuyTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); wantToBuyTemplate = _tpl; }
    function setServiceLocationIndex(address _idx) external onlyOwner { serviceLocationIndex = _idx; }
    function setKeywordWeight(address _keywordWeight) external onlyOwner { if (_keywordWeight == address(0)) revert ZeroAddress(); keywordWeightAddr = _keywordWeight; }
    function setDepositFactory(address _depositFactory) external onlyOwner { if (_depositFactory == address(0)) revert ZeroAddress(); depositFactoryAddr = _depositFactory; }
    function setSettings(address _settings) external onlyOwner { if (_settings == address(0)) revert ZeroAddress(); settingsAddr = _settings; }
    function setArchiveTemplate(address _archiveTemplate) external onlyOwner { if (_archiveTemplate == address(0)) revert ZeroAddress(); archiveTemplate = _archiveTemplate; }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    function _cloneArchive(address impl) internal returns (address instance) {
        instance = _clone(impl);
        ArchiveStore(instance).initialize(address(this));
    }

    /// @dev Constructs PlatformContracts with USDT address
    function _platformContracts() internal view returns (PlatformContracts memory) {
        return PlatformContracts(usdtAddr, settingsAddr, inviteRegistryAddr, keywordWeightAddr);
    }

    function _validateCreate() internal view returns (address) {
        if (IPlatformSettings(settingsAddr).isBlacklisted(msg.sender)) revert IsBlacklisted();
        // Platform mechanism: allows listing products without deposit. Merchants without deposit have reduced ranking/risk control
        // reflected by frontend prompts and KeywordWeight deposit weight; arbitration payout path emits a shortfall event
        // when deposit is insufficient, rather than blocking at creation time.
        return IDepositFactory(depositFactoryAddr).getDeposit(msg.sender);
    }

    /// @notice Create physical product contract
    /// @param _strings Product text info (title, keyword, description)
    /// @param _specs Specification array
    /// @param _images Image URL array
    /// @param _deliveryMethod Delivery method (0=shipping, 1=self-pickup)
    /// @return Newly created product contract address
    function createPhysicalProduct(
        ProductStrings calldata _strings,
        Spec[] calldata _specs, string[] calldata _images,
        uint8 _deliveryMethod
    ) external noContract returns (address) {
        if (!IProductFactoryKeywords(keywordsAddr).isApproved(_strings.language, _strings.keyword)) revert KeywordNotApproved();
        address depositAddr = _validateCreate();
        address clone = _clone(physicalTemplate);
        IPhysicalProductTemplate(clone).initialize(
            msg.sender, _strings, _specs, _images, _deliveryMethod,
            _platformContracts(),
            depositAddr
        );
        _registerProduct(clone, msg.sender, _strings.language, _strings.keyword, 0);
        return clone;
    }

    /// @notice Create virtual product contract
    function createVirtualProduct(
        ProductStrings calldata _strings,
        Spec[] calldata _specs, string[] calldata _images
    ) external noContract returns (address) {
        if (!IProductFactoryKeywords(keywordsAddr).isApproved(_strings.language, _strings.keyword)) revert KeywordNotApproved();
        address depositAddr = _validateCreate();
        address clone = _clone(virtualTemplate);
        IVirtualProductTemplate(clone).initialize(
            msg.sender, _strings, _specs, _images,
            _platformContracts(),
            depositAddr
        );
        _registerProduct(clone, msg.sender, _strings.language, _strings.keyword, 1);
        return clone;
    }

    /// @notice Create service product contract (clone template and initialize)
    /// @param _strings Service text info (title, keyword, description, country, city)
    /// @param _images Image URL array
    /// @param _serviceItems Service item array
    /// @return Newly created product contract address
    function createServiceProduct(
        ServiceStrings calldata _strings,
        string[] calldata _images, ServiceItem[] calldata _serviceItems
    ) external noContract returns (address) {
        if (!IProductFactoryKeywords(keywordsAddr).isApproved(_strings.language, _strings.keyword)) revert KeywordNotApproved();
        if (!IPlatformSettings(settingsAddr).isCountryApproved(_strings.language, _strings.country)) revert CountryNotApproved();
        if (!IPlatformSettings(settingsAddr).isProvinceApproved(_strings.language, _strings.country, _strings.province)) revert ProvinceNotApproved();
        if (!IPlatformSettings(settingsAddr).isCityApproved(_strings.language, _strings.country, _strings.province, _strings.city)) revert CityNotApproved();
        address depositAddr = _validateCreate();
        address clone = _clone(serviceTemplate);
        IServiceProductTemplate(clone).initialize(
            msg.sender, _strings, _images, _serviceItems,
            _platformContracts(),
            depositAddr
        );
        _registerProduct(clone, msg.sender, _strings.language, _strings.keyword, 2);
        _registerServiceLocation(clone, _strings);
        return clone;
    }

    function _registerServiceLocation(address clone, ServiceStrings calldata _strings) internal {
        if (serviceLocationIndex != address(0)) {
            IServiceLocationIndex(serviceLocationIndex).registerProduct(clone, _strings.language, _strings.keyword, _strings.country, _strings.province, _strings.city);
        }
    }

    function createWantToBuyProduct(
        ProductStrings calldata _strings,
        uint256 _requestPrice, uint256 _stock,
        string[] calldata _images
    ) external noContract returns (address) {
        if (!IProductFactoryKeywords(keywordsAddr).isApproved(_strings.language, _strings.keyword)) revert KeywordNotApproved();
        if (IPlatformSettings(settingsAddr).isBlacklisted(msg.sender)) revert IsBlacklisted();

        // Check shared limit (products + C2C + auctions)
        uint256 maxAllowed = _getMaxProductsForSeller(msg.sender);
        uint256 totalActiveOrders = _getTotalActiveOrdersForMerchant(msg.sender);
        if (totalActiveOrders >= maxAllowed) revert MaxActiveProducts();

        uint256 totalEscrow = _requestPrice * _stock;
        if (totalEscrow == 0) revert ZeroAmount();
        address clone = _clone(wantToBuyTemplate);
        if (!IERC20(usdtAddr).transferFrom(msg.sender, clone, totalEscrow)) revert TransferFailed();
        IWantToBuyTemplate(clone).initialize(
            msg.sender, _strings, _requestPrice, _stock, _images,
            _platformContracts()
        );
        _registerProduct(clone, msg.sender, _strings.language, _strings.keyword, 3);
        _refreshDeposit(msg.sender);
        return clone;
    }

    function getKeywordKey(string memory language, string memory keyword) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(language, ":", keyword));
    }

    /// @notice Get max product limit for a seller based on their deposit status
    /// @param _seller Seller address
    /// @return Maximum number of products this seller can list
    function _getMaxProductsForSeller(address _seller) internal view returns (uint256) {
        address depositAddr = IDepositFactory(depositFactoryAddr).getDeposit(_seller);
        if (depositAddr == address(0)) {
            // No deposit contract = no deposit
            return MAX_PRODUCTS_WITHOUT_DEPOSIT;
        }
        // Check if seller has any USDT deposit balance
        try IMerchantDeposit(depositAddr).balanceOf(usdtAddr) returns (uint256 balance) {
            if (balance > 0) {
                return MAX_PRODUCTS_WITH_DEPOSIT;
            }
        } catch {
            // If call fails, treat as no deposit
        }
        return MAX_PRODUCTS_WITHOUT_DEPOSIT;
    }

    function _registerProduct(address product, address _seller, string calldata _language, string calldata _keyword, uint8 _type) internal {
        // Check shared limit (products + C2C + auctions)
        uint256 maxAllowed = _getMaxProductsForSeller(_seller);
        uint256 totalActiveOrders = _getTotalActiveOrdersForMerchant(_seller);
        if (totalActiveOrders >= maxAllowed) revert MaxActiveProducts();

        bytes32 key = getKeywordKey(_language, _keyword);

        // Enforce the per-keyword product count cap
        if (keywordToProducts[key].length >= MAX_PRODUCTS_PER_KEYWORD) revert TooHigh();

        keywordProductIndex[product] = keywordToProducts[key].length;
        keywordToProducts[key].push(product);
        _bumpSeed(key);  // Bump seed on product list
        productKeyword[product] = _keyword;
        productLanguage[product] = _language;
        productLanguageIndex[product] = productsByLanguage[_language].length;
        productsByLanguage[_language].push(product);
        currentSellerArchive.pushUser(_seller, product);
        bool isFull = currentProductArchive.pushGlobal(product);
        if (isFull) {
            currentProductArchive = ArchiveStore(_cloneArchive(archiveTemplate));
            productArchives.push(currentProductArchive);
        }
        unchecked { totalProductCount++; }
        isFactoryProduct[product] = true;
        productType[product] = _type;
        activeProductIndex[product] = activeProducts[_seller].length;
        activeProducts[_seller].push(product);

        // [C-01 fix]: Update incremental counters when product becomes active
        uint256 prevCount = activeProductCount[_seller];
        activeProductCount[_seller]++;
        if (prevCount == 0) {
            // Seller transitioned from 0 to 1 active product
            activeSellerCount++;
        }
        totalActiveProductCount++;

        if (!keywordExists[key]) {
            keywordExists[key] = true;
            allKeywordKeys.push(key);
            keywordKeysByLanguage[_language].push(key);
        }
        IKeywordWeight(keywordWeightAddr).addAuthorizedCallerByFactory(product);
        IPlatformSettings(settingsAddr).authorizeContractByFactory(product);
        _refreshDeposit(_seller);
        emit ProductCreated(_type, product, _seller, _language, _keyword, key, "");
    }

    /// @notice Product delisting callback (called by product contract, updates seller's active product list)
    /// @param _seller Seller address
    function productDelisted(address _seller) external {
        if (!isFactoryProduct[msg.sender]) revert NotFactoryProduct();
        if (activeProductCount[_seller] == 0) revert NoActiveProduct();
        _removeActiveProduct(_seller, msg.sender);
        bytes32 key = getKeywordKey(productLanguage[msg.sender], productKeyword[msg.sender]);
        _removeKeywordProduct(msg.sender);
        _bumpSeed(key);  // Bump seed on product delist
        if (serviceLocationIndex != address(0) && productType[msg.sender] == 2) {
            IServiceLocationIndex(serviceLocationIndex).removeProduct(msg.sender);
        }

        // [C-01 fix]: Update incremental counters when product becomes inactive
        uint256 prevCount = activeProductCount[_seller];
        activeProductCount[_seller]--;
        if (prevCount == 1) {
            // Seller transitioned from 1 to 0 active products
            activeSellerCount--;
        }
        totalActiveProductCount--;

        if (activeProductCount[_seller] == 0) {
            lastDelistTime[_seller] = block.timestamp;
        }
        emit ProductDelisted(msg.sender, _seller, activeProductCount[_seller]);
        _refreshDeposit(_seller);
    }

    /// @notice Dispute started callback (called by product contract, added to arbitration list)
    /// @param product Product contract address
    function disputeCreated(address product) external {
        if (!isFactoryProduct[msg.sender]) revert NotFactoryProduct();
        if (msg.sender != product) revert Mismatch();
        if (arbitratingProductCount[product] == 0) {
            arbitratingIndex[product] = arbitratingProducts.length;
            arbitratingProducts.push(product);
        }
        arbitratingProductCount[product]++;
        emit DisputeCreated(product);
    }

    /// @notice Dispute resolved callback (called by product contract, removed from arbitration list)
    /// @param product Product contract address
    function disputeResolved(address product) external {
        if (!isFactoryProduct[msg.sender]) revert NotFactoryProduct();
        if (msg.sender != product) revert Mismatch();
        uint256 count = arbitratingProductCount[product];
        if (count == 0) revert WrongStatus();
        if (count == 1) {
            _removeArbitrating(product);
        } else {
            arbitratingProductCount[product] = count - 1;
        }
    }

    /// @notice Order created callback (called by product contract, records buyer history and refreshes deposit activity)
    /// @param _buyer Buyer address
    function orderCreated(address _buyer) external {
        if (!isFactoryProduct[msg.sender]) revert NotFactoryProduct();
        currentBuyerArchive.pushUser(_buyer, msg.sender);
        if (productType[msg.sender] == 3) {
            _refreshDeposit(IWantToBuyTemplate(msg.sender).buyer());
        } else {
            _refreshDeposit(IProductTemplate(msg.sender).seller());
        }
    }

    /// @notice Order shipped notification (called by product contract, refreshes seller deposit activity)
    function orderShipped(address _seller) external {
        if (!isFactoryProduct[msg.sender]) revert NotFactoryProduct();
        _refreshDeposit(_seller);
    }

    /// @notice Want-to-buy seller acceptance notification (called by WantToBuy contract, records seller index)
    function orderAcceptedBySeller(address _seller) external {
        if (!isFactoryProduct[msg.sender]) revert NotFactoryProduct();
        currentBuyerArchive.pushUser(_seller, msg.sender);
        _refreshDeposit(_seller);
    }

    function _refreshDeposit(address merchant) internal {
        if (depositFactoryAddr != address(0)) {
            IDepositFactory(depositFactoryAddr).refreshMerchantActivity(merchant);
        }
    }

    function _removeArbitrating(address product) internal {
        uint256 idx = arbitratingIndex[product];
        uint256 lastIdx = arbitratingProducts.length - 1;
        if (idx != lastIdx) {
            address last = arbitratingProducts[lastIdx];
            arbitratingProducts[idx] = last;
            arbitratingIndex[last] = idx;
        }
        arbitratingProducts.pop();
        delete arbitratingIndex[product];
        delete arbitratingProductCount[product];
    }

    function _removeActiveProduct(address _seller, address product) internal {
        uint256 idx = activeProductIndex[product];
        address[] storage arr = activeProducts[_seller];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            address last = arr[lastIdx];
            arr[idx] = last;
            activeProductIndex[last] = idx;
        }
        arr.pop();
        delete activeProductIndex[product];
    }

    function _removeKeywordProduct(address product) internal {
        string memory kw = productKeyword[product];
        if (bytes(kw).length == 0) return;
        string memory lang = productLanguage[product];
        bytes32 key = getKeywordKey(lang, kw);
        address[] storage arr = keywordToProducts[key];
        uint256 idx = keywordProductIndex[product];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            address last = arr[lastIdx];
            arr[idx] = last;
            keywordProductIndex[last] = idx;
        }
        arr.pop();
        delete keywordProductIndex[product];
        // Language market isolation: also remove from productsByLanguage (swap-pop) so the
        // by-language "all products" listing never surfaces delisted products.
        address[] storage langArr = productsByLanguage[lang];
        if (langArr.length > 0) {
            uint256 lIdx = productLanguageIndex[product];
            uint256 lLast = langArr.length - 1;
            if (lIdx != lLast) {
                address lastP = langArr[lLast];
                langArr[lIdx] = lastP;
                productLanguageIndex[lastP] = lIdx;
            }
            langArr.pop();
            delete productLanguageIndex[product];
        }
        delete productLanguage[product];
        delete productKeyword[product];
    }

    /// @notice Seller batch delist all products
    /// @dev Audit note [L-02]: MAX_PRODUCTS_PER_SELLER (production: 20) limits each seller's
    ///      active products, so the loop upper bound is fixed and there is no gas overflow risk
    // Audit note [L-01]: try/catch swallowing exceptions is intentional design for batch operations.
    // A single product delist failure (e.g., active orders) should not block other products from delisting.
    // When delistedCount==0, revert NoProductsDelisted ensures silent total failure is not possible.
    function delistAllProducts() external noContract {
        uint256 count = activeProductCount[msg.sender];
        if (count == 0) revert NoActiveProduct();
        address[] storage products = activeProducts[msg.sender];
        uint256 delistedCount = 0;
        for (uint256 i = count; i > 0;) {
            address product = products[i - 1];
            try IProductTemplate(product).delistByFactory(msg.sender) {
                delistedCount++;
            } catch {}
            unchecked { i--; }
        }
        if (delistedCount == 0) revert NoProductsDelisted();
    }

    /// @notice Deposit factory force-delists all products for a given seller (called during zombie recycling)
    /// @dev Audit note: only checking msg.sender==depositFactory is safe because DepositFactory.adminRecycleDeposit
    ///      has an isAdmin check (admin=owner EOA), and flash loans cannot obtain admin privileges
    /// @param _seller Seller address
    function delistAllProductsFor(address _seller) external {
        address df = IPlatformSettings(settingsAddr).getDepositFactory();
        if (msg.sender != df) revert NotAuthorized();
        uint256 count = activeProductCount[_seller];
        if (count == 0) return;
        address[] storage products = activeProducts[_seller];
        for (uint256 i = count; i > 0;) {
            address product = products[i - 1];
            try IProductTemplate(product).delistByFactory(_seller) {} catch {}
            unchecked { i--; }
        }
    }

    /// @notice Check if seller can withdraw deposit (no active products and cooldown period has passed)
    /// @param _seller Seller address
    /// @return Whether withdrawal is allowed
    function canWithdrawDeposit(address _seller) external view returns (bool) {
        if (activeProductCount[_seller] > 0) return false;
        uint256 delist = lastDelistTime[_seller];
        if (delist == 0) return true;
        return block.timestamp >= delist + 24 hours; // production
    }

    /// @notice Get seller delist info (active count, last delist time, whether deposit can be withdrawn)
    /// @param _seller Seller address
    /// @return Active product count, last delist timestamp, whether deposit can be withdrawn
    function getDelistInfo(address _seller) external view returns (uint256, uint256, bool) {
        uint256 ac = activeProductCount[_seller];
        uint256 delist = lastDelistTime[_seller];
        bool ok = ac == 0 && (delist == 0 || block.timestamp >= delist + 24 hours); // production
        return (ac, delist, ok);
    }

    /// @notice Get total active orders for a merchant (products + C2C + auctions)
    /// @param _merchant Merchant address
    /// @return Total active order count across all factories
    function _getTotalActiveOrdersForMerchant(address _merchant) internal view returns (uint256) {
        uint256 total = activeProductCount[_merchant];

        // Add C2C order count from C2CFactory
        address cf = IPlatformSettings(settingsAddr).getC2CFactory();
        if (cf != address(0)) {
            try IC2CFactory(cf).activeOrderCountOf(_merchant) returns (uint256 activeOrders) {
                total += activeOrders;
            } catch {}
        }

        // Add auction count from AuctionFactory
        address af = IPlatformSettings(settingsAddr).getAuctionFactory();
        if (af != address(0)) {
            try IAuctionFactory(af).activeSellerAuctionCount(_merchant) returns (uint256 activeAuctions) {
                total += activeAuctions;
            } catch {}
        }

        return total;
    }

    /// @notice Get total keyword count
    /// @return Keyword count
    function getAllKeywordCount() external view returns (uint256) { return allKeywordKeys.length; }
    /// @notice Get product count under a specific keyword
    /// @param keyword Keyword
    /// @return Product count
    function getKeywordProductCount(string calldata keyword) external view returns (uint256) { return keywordToProducts[getKeywordKey("", keyword)].length; }
    function getKeywordProductCountByLanguage(string calldata language, string calldata keyword) external view returns (uint256) { return keywordToProducts[getKeywordKey(language, keyword)].length; }
    function getLanguageProductCount(string calldata language) external view returns (uint256) { return productsByLanguage[language].length; }
    function getLanguageKeywordCount(string calldata language) external view returns (uint256) { return keywordKeysByLanguage[language].length; }
    /// @notice Get total count of products under arbitration
    /// @return Arbitrating product count
    function getArbitratingProductCount() external view returns (uint256) { return arbitratingProducts.length; }
    /// @notice Get seller archive generation count
    /// @return Archive generation count
    function getSellerArchiveCount() external view returns (uint256) { return sellerArchives.length; }
    /// @notice Get buyer archive generation count
    /// @return Archive generation count
    function getBuyerArchiveCount() external view returns (uint256) { return buyerArchives.length; }
    /// @notice Get product archive generation count
    /// @return Archive generation count
    function getProductArchiveCount() external view returns (uint256) { return productArchives.length; }

    /// @notice Get total seller count (across all archives)
    /// @return Total seller count
    function getSellerCount() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < sellerArchives.length; i++) {
            total += ArchiveStore(sellerArchives[i]).getGlobalCount();
        }
        return total;
    }

    /// @notice Get active seller count (sellers with at least one active product)
    /// @return Active seller count
    function getActiveSellerCount() external view returns (uint256) {
        // [C-01 fix]: Return cached counter instead of nested loop traversal
        return activeSellerCount;
    }

    /// @notice Get total active product count (across all sellers)
    /// @return Total active product count
    function getActiveProductCount() external view returns (uint256) {
        // [C-01 fix]: Return cached counter instead of nested loop traversal
        return totalActiveProductCount;
    }

    // ==================== Pagination Functions (Gas-Optimized) ====================

    /// @notice Get product at specific index for a keyword (pagination-friendly)
    /// @param language Language code
    /// @param keyword Keyword
    /// @param index Index position
    /// @return Product address at the given index
    function getKeywordProductAt(string calldata language, string calldata keyword, uint256 index)
        external view returns (address) {
        bytes32 key = getKeywordKey(language, keyword);
        require(index < keywordToProducts[key].length, "Index out of bounds");
        return keywordToProducts[key][index];
    }

    /// @notice Get product at specific index for a language (pagination-friendly)
    /// @param language Language code
    /// @param index Index position
    /// @return Product address at the given index
    function getLanguageProductAt(string calldata language, uint256 index)
        external view returns (address) {
        require(index < productsByLanguage[language].length, "Index out of bounds");
        return productsByLanguage[language][index];
    }

    /// @notice Get active product at specific index for a seller (pagination-friendly)
    /// @param seller Seller address
    /// @param index Index position
    /// @return Product address at the given index
    function getActiveProductAt(address seller, uint256 index)
        external view returns (address) {
        require(index < activeProducts[seller].length, "Index out of bounds");
        return activeProducts[seller][index];
    }

    /// @notice Get arbitrating product at specific index (pagination-friendly)
    /// @param index Index position
    /// @return Product address at the given index
    function getArbitratingProductAt(uint256 index)
        external view returns (address) {
        require(index < arbitratingProducts.length, "Index out of bounds");
        return arbitratingProducts[index];
    }

    /// @notice Get keyword key at specific index for a language (pagination-friendly)
    /// @param language Language code
    /// @param index Index position
    /// @return Keyword key at the given index
    function getLanguageKeywordAt(string calldata language, uint256 index)
        external view returns (bytes32) {
        require(index < keywordKeysByLanguage[language].length, "Index out of bounds");
        return keywordKeysByLanguage[language][index];
    }

    /// @notice Get delisted product count for a specific keyword
    /// @param language Language code
    /// @param keyword Keyword
    /// @return delistedCount Delisted product count
    function getDelistedProductCount(string calldata language, string calldata keyword) external view returns (uint256 delistedCount) {
        bytes32 key = getKeywordKey(language, keyword);
        address[] storage products = keywordToProducts[key];
        for (uint256 i = 0; i < products.length; i++) {
            try IProductTemplate(products[i]).delisted() returns (bool isDelisted) {
                if (isDelisted) delistedCount++;
            } catch {}
        }
    }

    /// @notice Cleanup delisted products from a keyword to free storage
    /// @param language Language code
    /// @param keyword Keyword
    /// @param maxCleanup Maximum number of products to check (0 = check all)
    /// @return cleaned Number of delisted products removed
    function cleanupDelistedProducts(
        string calldata language,
        string calldata keyword,
        uint256 maxCleanup
    ) external onlyOwner returns (uint256 cleaned) {
        bytes32 key = getKeywordKey(language, keyword);
        address[] storage products = keywordToProducts[key];

        if (products.length == 0) return 0;
        if (maxCleanup == 0) maxCleanup = products.length;

        // [H-06 fix]: Collect ALL products, not just the first maxCleanup
        address[] memory activeList = new address[](products.length);
        uint256 activeCount = 0;

        uint256 checkCount = products.length < maxCleanup ? products.length : maxCleanup;
        for (uint256 i = 0; i < checkCount; i++) {
            address product = products[i];
            try IProductTemplate(product).delisted() returns (bool isDelisted) {
                if (!isDelisted) {
                    activeList[activeCount++] = product;
                } else {
                    cleaned++;
                }
            } catch {
                // If call fails, keep the product (safer default)
                activeList[activeCount++] = product;
            }
        }

        // [H-06 fix]: Also preserve unchecked products (from maxCleanup onwards)
        for (uint256 i = checkCount; i < products.length; i++) {
            activeList[activeCount++] = products[i];
        }

        // If no delisted products found, nothing to clean
        if (cleaned == 0) return 0;

        // Rebuild array with only active products
        delete keywordToProducts[key];
        for (uint256 i = 0; i < activeCount; i++) {
            keywordToProducts[key].push(activeList[i]);
        }

        emit ProductsCleaned(language, keyword, cleaned);
    }

    // Audit note [3.3.3]: _clone being duplicated across multiple factory contracts is intentional design.
    // Each factory contract is independently deployed without shared inheritance, avoiding extra dependencies and upgrade coupling.
    // EIP-1167 clone code is only 10 lines; duplication cost is far lower than introducing a base contract's complexity.
    // Audit note [H-03]: Using create instead of create2 is intentional.
    // (1) Target chains (BSC/Polygon PoS) have extremely rare and brief reorgs
    // (2) Clone address is immediately registered in the factory mapping within the same transaction
    // (3) create2 requires additional salt management, adding complexity with insufficient benefit to justify the cost
    function _clone(address impl) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(96, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
            if iszero(instance) { revert(0, 0) }
        }
    }

    /// @notice Internal function to update keyword seed (called on list/delist/sale)
    /// @dev Uses block.timestamp, block.prevrandao (or block.difficulty on older chains), and existing seed for entropy
    /// @param key Keyword key (keccak256(abi.encodePacked(language, ":", keyword)))
    function _bumpSeed(bytes32 key) internal {
        // Mix timestamp, prevrandao/difficulty, and old seed for pseudo-random entropy
        // prevrandao available post-merge; fallback to block.difficulty on pre-merge chains (both return uint256)
        keywordSeed[key] = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,  // Safe: falls back to block.difficulty on pre-merge chains
            keywordSeed[key]
        )));
    }

    /// @notice External seed bump interface (only callable by KeywordAuction or Keywords contract)
    /// @dev Allows authorized contracts (auction) to bump seed when bid succeeds
    /// @param language Language code
    /// @param keyword Keyword string
    function bumpSeedExternal(string calldata language, string calldata keyword) external {
        // Only KeywordAuction or Keywords contract can call
        if (msg.sender != keywordAuctionAddr && msg.sender != keywordsAddr) revert NotAuthorized();
        bytes32 key = keccak256(abi.encodePacked(language, ":", keyword));
        _bumpSeed(key);
    }

    /// @notice Bump seed on product sale (only callable by KeywordWeight)
    /// @dev Called by KeywordWeight.recordSale to trigger seed refresh on transaction completion
    /// @param product Product contract address
    function bumpSeedOnSale(address product) external {
        if (msg.sender != keywordWeightAddr) revert NotAuthorized();

        // Get language and keyword via the dedicated keyword()/language() getters
        // (present on all four templates). Do NOT decode getProductInfo() here: the
        // four templates return different tuple shapes (Physical 10, Virtual 9,
        // Service 10 with different field types, WantToBuy 9), so decoding every type
        // through one fixed-arity interface corrupts the layout and reverts — this
        // mirrors the bumpSeedOnActivity fix and was the silent revert on
        // Virtual/Service/WantToBuy order settlement.
        string memory keyword_ = IProductTemplate(product).keyword();
        string memory language_ = IProductTemplate(product).language();

        bytes32 key = keccak256(abi.encodePacked(language_, ":", keyword_));
        _bumpSeed(key);
    }

    /// @notice Bump seed on product activity (purchase/ship/receive)
    /// @dev Called by any factory product during normal business activities to increase exposure
    /// @param product Product contract address
    function bumpSeedOnActivity(address product) external {
        // [M-06 fix]: Only allow the product contract itself to call this function
        if (msg.sender != product) revert NotAuthorized();
        if (!isFactoryProduct[product]) revert NotFactoryProduct();

        // Read language and keyword from product contract.
        // Use the dedicated keyword()/language() getters (present on all four templates)
        // instead of decoding getProductInfo() — the four templates return different
        // tuple shapes (Physical 10, Virtual 9, Service 10, WantToBuy 9), so decoding
        // every type through one fixed-arity interface corrupts the dynamic-offset
        // layout and reverts (this was the silent revert on Virtual/Service purchase).
        string memory keyword_;
        string memory language_;

        uint8 pType = productType[product];
        if (pType == 0 || pType == 1 || pType == 2 || pType == 3) {
            keyword_ = IProductTemplate(product).keyword();
            language_ = IProductTemplate(product).language();
        } else {
            revert InvalidProductType();
        }

        bytes32 key = keccak256(abi.encodePacked(language_, ":", keyword_));
        _bumpSeed(key);
    }
}
