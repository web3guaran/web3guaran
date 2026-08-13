// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #19: AuctionFactory — Auction factory contract
 * Responsibility: Deploy auction instances via EIP-1167 minimal proxy, manage auction index and lifecycle callbacks
 * Deploy order: #19 (depends on AuctionTemplate, PlatformSettings, USDT, InviteRegistry, DepositFactory)
 *
 * Business flow:
 *   1. Merchant calls createAuction() to create auction (clone + initialize + authorize + register index)
 *   2. Auction clones call back to factory on lifecycle events (auctionEnded, disputeCreated, disputeResolved)
 *   3. Frontend queries active auctions, arbitrating auctions, seller history via pagination
 */

import "./interfaces/Interfaces.sol";
import "./ArchiveStore.sol";
import "./AuctionTemplate.sol";

/// @title AuctionFactory - Auction Deployment Factory
/// @author WEB3GUARANTEE
/// @notice Deploys auction contracts via EIP-1167 clone and tracks active/completed auctions per seller
contract AuctionFactory {

    // ==================== Anti-contract-call ====================

    /// @dev Reject unauthorized contract calls; only EOA or whitelisted contract wallets allowed
    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    /// @dev Only contract owner can call
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    // ==================== State Variables ====================

    // ===== Payment channel (USDT only) =====

    /// Contract owner
    address public owner;

    /// Auction template contract address (for EIP-1167 clone)
    address public auctionTemplate;

    /// Platform settings contract address
    address public settingsAddr;

    /// USDT token contract address
    address public usdtAddr;

    /// Invite registry contract address
    address public inviteRegistryAddr;

    /// Deposit factory contract address
    address public depositFactoryAddr;
    address public archiveTemplate;

    /// Factory-created auction identifier
    mapping(address => bool) public isFactoryAuction;

    /// Seller's auction list
    mapping(address => address[]) public sellerAuctions;

    /// Active auction list (Created/Active status)
    address[] public activeAuctions;
    mapping(address => uint256) public activeAuctionIndex;
    mapping(address => bool) public isActiveAuction;

    /// Seller active auction count (for deposit withdrawal check)
    mapping(address => uint256) public activeSellerAuctionCount;

    /// Language market isolation: index auctions by language
    mapping(string => address[]) public auctionsByLanguage;
    mapping(address => string) public auctionLanguage;
    mapping(address => uint256) public auctionLanguageIndex;

    /// Arbitrating auction list
    address[] public arbitratingAuctions;
    mapping(address => uint256) public arbitratingIndex;
    mapping(address => bool) public isArbitratingAuction;

    /// Keyword randomization seed (for auction exposure)
    mapping(bytes32 => uint256) public keywordSeed;

    /// Archive storage (global auction history, 1000 per generation)
    ArchiveStore[] public auctionArchives;
    ArchiveStore public currentAuctionArchive;

    /// Total auction count
    uint256 public totalAuctionCount;

    /// Pagination query limit
    uint256 public constant MAX_PAGE_SIZE = 24;

    // Auction limits (shared with Product/C2C)
    uint256 public constant MAX_AUCTIONS_WITHOUT_DEPOSIT = 5;
    uint256 public constant MAX_AUCTIONS_WITH_DEPOSIT = 20;
    uint256 public constant MAX_AUCTIONS_PER_LANGUAGE = 10000;  // Maximum auctions per language
    uint256 public constant MAX_TOTAL_AUCTIONS = 100000;        // Global maximum auctions

    // ==================== Event Definitions ====================

    /// Auction created
    event AuctionCreated(address indexed auction, address indexed seller, string title);

    /// Dispute started
    event DisputeCreated(address indexed auction);

    /// Dispute resolved
    event DisputeResolved(address indexed auction);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    // ==================== Constructor ====================

    /**
     * @notice Deploy auction factory
     * @param _template       Auction template contract address
     * @param _settings       Platform settings contract address
     * @param _inviteRegistry Invite registry contract address
     * @param _depositFactory Deposit factory contract address
     * @param _usdt           USDT token address
     */
    constructor(
        address _template,
        address _settings,
        address _inviteRegistry,
        address _depositFactory,
        address _usdt,
        address _archiveTemplate
    ) {
        if (
            _template == address(0) || _settings == address(0) || _inviteRegistry == address(0) ||
            _depositFactory == address(0) || _archiveTemplate == address(0)
        ) revert ZeroAddress();
        if (_usdt == address(0)) revert ZeroAddress();
        owner = msg.sender;
        auctionTemplate = _template;
        settingsAddr = _settings;
        usdtAddr = _usdt;
        inviteRegistryAddr = _inviteRegistry;
        depositFactoryAddr = _depositFactory;

        // Initialize first generation archive storage (EIP-1167 clone)
        archiveTemplate = _archiveTemplate;
        currentAuctionArchive = ArchiveStore(_cloneArchive(_archiveTemplate));
        auctionArchives.push(currentAuctionArchive);
    }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    function setAuctionTemplate(address _tpl) external { if (msg.sender != owner) revert NotOwner(); if (_tpl == address(0)) revert ZeroAddress(); auctionTemplate = _tpl; }
    function setDepositFactory(address _depositFactory) external onlyOwner { if (_depositFactory == address(0)) revert ZeroAddress(); depositFactoryAddr = _depositFactory; }
    function setSettings(address _settings) external onlyOwner { if (_settings == address(0)) revert ZeroAddress(); settingsAddr = _settings; }
    function setArchiveTemplate(address _archiveTemplate) external onlyOwner { if (_archiveTemplate == address(0)) revert ZeroAddress(); archiveTemplate = _archiveTemplate; }

    // ==================== Create Auction ====================

    /**
     * @notice Create auction (merchant calls)
     * @dev clone template -> initialize -> authorize -> register index
     * @param _params Auction parameters struct
     * @return Newly created auction contract address
     */
    function createAuction(AuctionParams calldata _params) external noContract returns (address) {
        if (IPlatformSettings(settingsAddr).isBlacklisted(msg.sender)) revert IsBlacklisted();

        address depositAddr = IDepositFactory(depositFactoryAddr).getDeposit(msg.sender);
        if (depositAddr == address(0)) revert NoMerchantDeposit();

        // Check shared auction limit (Auctions count toward product limit)
        uint256 maxAllowed = _getMaxAuctionsForMerchant(msg.sender);
        uint256 totalActiveOrders = _getTotalActiveOrdersForMerchant(msg.sender);
        if (totalActiveOrders >= maxAllowed) revert MaxActiveProducts();

        // Check language market limit (10,000 auctions per language)
        if (auctionsByLanguage[_params.language].length >= MAX_AUCTIONS_PER_LANGUAGE) revert TooHigh();

        // Check global auction limit (100,000 total auctions)
        if (activeAuctions.length >= MAX_TOTAL_AUCTIONS) revert TooHigh();

        address clone = _clone(auctionTemplate);

        // Registration must precede initialize: initialize internally lets the auction contract self-authorize with the deposit contract, which checks isFactoryAuction.
        _registerAuction(clone, msg.sender, _params.language);

        // Initialize auction clone (USDT only)
        AuctionTemplate(clone).initialize(
            msg.sender,
            _params,
            settingsAddr,
            inviteRegistryAddr,
            depositFactoryAddr,
            usdtAddr
        );

        _refreshDeposit(msg.sender);

        emit AuctionCreated(clone, msg.sender, _params.title);
        return clone;
    }

    // ==================== Lifecycle Callbacks (only callable by auction clones) ====================

    /**
     * @notice Auction ended callback (remove from active list)
     * @dev Called by auction clone on finalizeAuction/buyNow/cancelAuction
     * @param auction Auction contract address
     */
    function auctionEnded(address auction) external {
        if (!isFactoryAuction[msg.sender]) revert NotAuthorized();
        if (msg.sender != auction) revert Mismatch();
        if (!isActiveAuction[auction]) revert WrongStatus();
        _removeActiveAuction(auction);
        _refreshDeposit(IAuctionTemplate(msg.sender).seller());
    }

    /**
     * @notice Dispute started callback
     * @param auction Auction contract address
     */
    function disputeCreated(address auction) external {
        if (!isFactoryAuction[msg.sender]) revert NotAuthorized();
        if (msg.sender != auction) revert Mismatch();
        if (isArbitratingAuction[auction]) revert WrongStatus();
        arbitratingIndex[auction] = arbitratingAuctions.length;
        arbitratingAuctions.push(auction);
        isArbitratingAuction[auction] = true;
        emit DisputeCreated(auction);
    }

    /**
     * @notice Dispute resolved callback
     * @param auction Auction contract address
     */
    function disputeResolved(address auction) external {
        if (!isFactoryAuction[msg.sender]) revert NotAuthorized();
        if (msg.sender != auction) revert Mismatch();
        if (!isArbitratingAuction[auction]) revert WrongStatus();
        _removeArbitratingAuction(auction);
        emit DisputeResolved(auction);
    }

    /// @notice Auction shipped notification (called by auction contract, refreshes seller deposit activity)
    function auctionShipped(address _seller) external {
        if (!isFactoryAuction[msg.sender]) revert NotAuthorized();
        _refreshDeposit(_seller);
    }

    /// @notice Bump seed on auction activity (bid/buyNow/ship/receive)
    /// @dev Called by auction contracts during normal business activities to increase exposure
    /// @param auction Auction contract address
    function bumpSeedOnActivity(address auction) external {
        // [M-06 fix]: Only allow the auction contract itself to call this function
        if (msg.sender != auction) revert NotAuthorized();
        if (!isFactoryAuction[auction]) revert NotAuthorized();

        // Read language from auction contract
        string memory language_ = AuctionTemplate(auction).language();

        // Get keyword from auction title (use title as keyword for auctions)
        string memory keyword_ = AuctionTemplate(auction).title();

        bytes32 key = keccak256(abi.encodePacked(language_, ":", keyword_));
        _bumpSeed(key);
    }

    /// @notice Internal function to update keyword seed
    /// @param key Keyword key (keccak256(abi.encodePacked(language, ":", keyword)))
    function _bumpSeed(bytes32 key) internal {
        // Mix timestamp, prevrandao, and old seed for pseudo-random entropy
        keywordSeed[key] = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            keywordSeed[key]
        )));
    }

    function _refreshDeposit(address merchant) internal {
        if (depositFactoryAddr != address(0)) {
            IDepositFactory(depositFactoryAddr).refreshMerchantActivity(merchant);
        }
    }

    // ==================== Internal Functions ====================

    /**
     * @notice EIP-1167 minimal proxy clone
     * @param impl Template contract address
     * @return instance Clone instance address
     */
    // Audit note [H-03]: Using create instead of create2 is an intentional choice.
    // (1) Target chains (BSC/Polygon PoS) have extremely rare and short reorgs
    // (2) Clone address is immediately registered in the factory mapping within the same transaction
    // (3) create2 requires extra salt management, adding complexity with insufficient benefit to justify the cost
    function _cloneArchive(address impl) internal returns (address instance) {
        instance = _clone(impl);
        ArchiveStore(instance).initialize(address(this));
    }

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

    /**
     * @notice Register auction index (internal)
     * @param auction Auction contract address
     * @param _seller Seller address
     */
    function _registerAuction(address auction, address _seller, string calldata _language) internal {
        isFactoryAuction[auction] = true;

        // Add to seller auction list
        sellerAuctions[_seller].push(auction);

        // Add to active auction list
        activeAuctionIndex[auction] = activeAuctions.length;
        activeAuctions.push(auction);
        isActiveAuction[auction] = true;
        activeSellerAuctionCount[_seller]++;

        // Language market isolation: add to language-specific index
        auctionLanguage[auction] = _language;
        auctionLanguageIndex[auction] = auctionsByLanguage[_language].length;
        auctionsByLanguage[_language].push(auction);

        // Write to archive storage (auto-generation)
        currentAuctionArchive.pushUser(_seller, auction);
        bool isFull = currentAuctionArchive.pushGlobal(auction);
        if (isFull) {
            currentAuctionArchive = ArchiveStore(_cloneArchive(archiveTemplate));
            auctionArchives.push(currentAuctionArchive);
        }

        unchecked { totalAuctionCount++; }

        // Authorize clone contract to call PlatformSettings sensitive methods
        IPlatformSettings(settingsAddr).authorizeContractByFactory(auction);
    }

    /**
     * @notice Remove from active auction list (swap-delete)
     * @param auction Auction contract address
     */
    function _removeActiveAuction(address auction) internal {
        uint256 idx = activeAuctionIndex[auction];
        uint256 lastIdx = activeAuctions.length - 1;
        if (idx != lastIdx) {
            address last = activeAuctions[lastIdx];
            activeAuctions[idx] = last;
            activeAuctionIndex[last] = idx;
        }
        activeAuctions.pop();
        delete activeAuctionIndex[auction];
        delete isActiveAuction[auction];
        // Language market isolation: remove from language-specific index (swap-pop)
        // so by-language queries never surface ended auctions.
        string memory lang = auctionLanguage[auction];
        if (bytes(lang).length != 0) {
            address[] storage arr = auctionsByLanguage[lang];
            uint256 lIdx = auctionLanguageIndex[auction];
            uint256 lLast = arr.length - 1;
            if (lIdx != lLast) {
                address lastA = arr[lLast];
                arr[lIdx] = lastA;
                auctionLanguageIndex[lastA] = lIdx;
            }
            arr.pop();
            delete auctionLanguageIndex[auction];
            delete auctionLanguage[auction];
        }
        address auctionSeller = IAuctionTemplate(auction).seller();
        if (activeSellerAuctionCount[auctionSeller] > 0) {
            activeSellerAuctionCount[auctionSeller]--;
        }
    }

    /**
     * @notice Remove from arbitrating auction list (swap-delete)
     * @param auction Auction contract address
     */
    function _removeArbitratingAuction(address auction) internal {
        uint256 idx = arbitratingIndex[auction];
        uint256 lastIdx = arbitratingAuctions.length - 1;
        if (idx != lastIdx) {
            address last = arbitratingAuctions[lastIdx];
            arbitratingAuctions[idx] = last;
            arbitratingIndex[last] = idx;
        }
        arbitratingAuctions.pop();
        delete arbitratingIndex[auction];
        delete isArbitratingAuction[auction];
    }

    // ==================== Query Functions ====================

    /// @notice Get max auction limit for a merchant based on their deposit status
    /// @param _merchant Merchant address
    /// @return Maximum number of auctions (C2C + products + auctions) this merchant can have active
    function _getMaxAuctionsForMerchant(address _merchant) internal view returns (uint256) {
        address depositAddr = IDepositFactory(depositFactoryAddr).getDeposit(_merchant);
        if (depositAddr == address(0)) {
            return MAX_AUCTIONS_WITHOUT_DEPOSIT;
        }
        try IMerchantDeposit(depositAddr).balanceOf(usdtAddr) returns (uint256 balance) {
            if (balance > 0) {
                return MAX_AUCTIONS_WITH_DEPOSIT;
            }
        } catch {}
        return MAX_AUCTIONS_WITHOUT_DEPOSIT;
    }

    /// @notice Get total active orders for a merchant (C2C + products + auctions)
    /// @param _merchant Merchant address
    /// @return Total active order count across all factories
    function _getTotalActiveOrdersForMerchant(address _merchant) internal view returns (uint256) {
        uint256 total = activeSellerAuctionCount[_merchant];

        // Add product count from ProductFactory
        address pf = IPlatformSettings(settingsAddr).getProductFactory();
        if (pf != address(0)) {
            try IProductFactory(pf).getDelistInfo(_merchant) returns (uint256 activeProducts, uint256, bool) {
                total += activeProducts;
            } catch {}
        }

        // Add C2C order count from C2CFactory
        address cf = IPlatformSettings(settingsAddr).getC2CFactory();
        if (cf != address(0)) {
            try IC2CFactory(cf).activeOrderCountOf(_merchant) returns (uint256 activeOrders) {
                total += activeOrders;
            } catch {}
        }

        return total;
    }

    /// @notice Check if seller has active auctions (checked during deposit withdrawal)
    function hasActiveAuctions(address _seller) external view returns (bool) {
        return activeSellerAuctionCount[_seller] > 0;
    }

    /**
     * @notice Get active auctions with pagination
     * @param offset Start index
     * @param limit  Return count
     * @return auctions Auction contract address array
     */
    function getActiveAuctions(uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= activeAuctions.length) return new address[](0);
        uint256 end = offset + limit;
        if (end > activeAuctions.length) end = activeAuctions.length;
        uint256 len = end - offset;
        address[] memory result = new address[](len);
        for (uint256 i = 0; i < len;) {
            result[i] = activeAuctions[offset + i];
            unchecked { ++i; }
        }
        return result;
    }

    /**
     * @notice Get active auction count
     * @return Active auction count
     */
    function getActiveAuctionCount() external view returns (uint256) {
        return activeAuctions.length;
    }

    /**
     * @notice Get arbitrating auctions with pagination
     * @param offset Start index
     * @param limit  Return count
     * @return auctions Auction contract address array
     */
    function getArbitratingAuctions(uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= arbitratingAuctions.length) return new address[](0);
        uint256 end = offset + limit;
        if (end > arbitratingAuctions.length) end = arbitratingAuctions.length;
        uint256 len = end - offset;
        address[] memory result = new address[](len);
        for (uint256 i = 0; i < len;) {
            result[i] = arbitratingAuctions[offset + i];
            unchecked { ++i; }
        }
        return result;
    }

    /**
     * @notice Get arbitrating auction count
     * @return Arbitrating auction count
     */
    function getArbitratingAuctionCount() external view returns (uint256) {
        return arbitratingAuctions.length;
    }

    /// Language market isolation: get auction count by language
    function getAuctionCountByLanguage(string calldata language) external view returns (uint256) {
        return auctionsByLanguage[language].length;
    }

    /**
     * @notice Get seller's auction history with pagination
     * @param _seller Seller address
     * @param offset Start index
     * @param limit  Return count
     * @return auctions Auction contract address array
     */
    function getAuctionsBySeller(address _seller, uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        address[] storage arr = sellerAuctions[_seller];
        if (offset >= arr.length) return new address[](0);
        uint256 end = offset + limit;
        if (end > arr.length) end = arr.length;
        uint256 len = end - offset;
        address[] memory result = new address[](len);
        for (uint256 i = 0; i < len;) {
            result[i] = arr[offset + i];
            unchecked { ++i; }
        }
        return result;
    }

    /**
     * @notice Get seller's total auction count
     * @param _seller Seller address
     * @return Auction count
     */
    function getSellerAuctionCount(address _seller) external view returns (uint256) {
        return sellerAuctions[_seller].length;
    }

    /**
     * @notice Get archive generation count
     * @return Archive storage generation count
     */
    function getArchiveGenerationCount() external view returns (uint256) {
        return auctionArchives.length;
    }
}
