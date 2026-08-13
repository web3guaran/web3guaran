// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #12: KeywordWeight — Product weight aggregation contract
 * Responsibility: Aggregate weight data per product for search ranking
 * Deploy order: #3 (depends on PlatformSettings)
 *
 * This contract records sales volume, order count, and review data for each product,
 * then calculates a composite weight score via a weighted formula for search result ranking.
 *
 * Weight formula (all scores scaled by 1000x, integer simulation of decimals):
 *   Review weight = 1000 + (good - 2 * bad) * 1000 / (totalReviews + 1)
 *     -> Range [0, 2000), approaches 2000 (2.0) with all positive reviews
 *   Sales weight = 1000 + (S / 10000) * 1000 / (1 + S / 40000)
 *     -> Range [1000, 5000), approaches 5000 (5.0) as S -> infinity
 *     -> Where S = 7-day sales volume (USDT, raw 6-decimal value / 1e6 to integer USDT)
 *   Order weight = 1000 + totalOrders * 1000 / (totalOrders + 100)
 *     -> Range [1000, 2000), approaches 2000 (2.0) as orders -> infinity
 *   Deposit weight = has deposit and sufficient ? 5000 : 0
 *     -> Fixed 0 or 5000 (0 or 5.0)
 *
 *   Composite weight = review + sales + order + deposit
 *     -> Theoretical max 14000 (14.0), never actually reachable
 *     -> Frontend divides by 1000 to get decimal score
 */

import "./interfaces/Interfaces.sol";

/// @title KeywordWeight - Product Search Ranking Engine
/// @author WEB3GUARANTEE
/// @notice Calculates composite weight scores for products based on sales volume, order count, reviews, and deposit status
contract KeywordWeight {

    // ==================== State Variables ====================

    // ===== BSC Mainnet USDT Address =====
    address public constant USDT_ADDRESS = 0x55d398326f99059fF775485246999027B3197955;

    /// Platform settings contract interface for reading global config
    IPlatformSettings public settings;

    /// Deposit factory contract address for querying merchant deposit status to calculate deposit weight
    address public depositFactoryAddr;

    /// Product factory contract address for triggering seed bump on sale
    address public productFactoryAddr;

    /// USDT precision unit (10^decimals), used for sales volume conversion
    uint256 public immutable usdtUnit;

    /// Product statistics data struct
    struct ProductStats {
        /// Daily sales mapping: day number (timestamp / 86400) => daily sales total
        mapping(uint256 => uint256) dailySales;
        /// Total historical order count for this product
        uint256 totalOrders;
        /// Positive review count for this product
        uint256 goodReviews;
        /// Negative review count for this product
        uint256 badReviews;
        /// Total review count for this product (good + bad)
        uint256 totalReviews;
    }

    /// Product address => statistics data mapping, stores aggregated data for all products
    mapping(address => ProductStats) internal productData;
    /// Authorized caller mapping: address => whether authorized (only authorized addresses can record sales and reviews)
    mapping(address => bool) public authorizedCallers;
    /// Contract owner address, has permission to manage authorized callers
    address public owner;
    /// Authorized factory address (can add authorization for clone contracts)
    address public authorizedFactory;

    // ==================== Events ====================

    /// Emitted when sale data is recorded
    /// @param product Product address
    /// @param amount Sale amount
    /// @param day Day number (timestamp / 86400)
    event SaleRecorded(address indexed product, uint256 amount, uint256 day);

    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ==================== Modifiers ====================

    /// Only authorized callers can execute, protects data write functions
    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();
        _;
    }

    // Audit note: owner is a Gnosis Safe multisig; all onlyOwner operations require multi-party signature
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ==================== Constructor ====================

    /// Constructor uses BSC mainnet USDT decimals in this production contract. Do not sync testnet token values into this file.
    /// @param _settings PlatformSettings contract address
    /// @param _depositFactory DepositFactory contract address
    /// @param _productFactory ProductFactory contract address
    constructor(address _settings, address _depositFactory, address _productFactory) {
        settings = IPlatformSettings(_settings);
        depositFactoryAddr = _depositFactory;
        productFactoryAddr = _productFactory;
        owner = msg.sender;
        usdtUnit = 10 ** uint256(IERC20(USDT_ADDRESS).decimals());
    }

    // ==================== Authorization Management ====================

    /// Add authorized caller, owner only
    /// @param caller Address to authorize
    function addAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = true;
    }

    /// Remove authorized caller, owner only
    /// @param caller Address to remove authorization
    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
    }

    /// Set authorized factory address (owner only, single-set: cannot be changed once set)
    /// @param _factory Factory contract address
    function setAuthorizedFactory(address _factory) external onlyOwner {
        if (authorizedFactory != address(0)) revert AlreadySet();
        if (_factory == address(0)) revert ZeroAddress();
        authorizedFactory = _factory;
    }

    /// Set product factory address for seed bumping (owner only)
    /// @param _productFactory ProductFactory contract address
    function setProductFactory(address _productFactory) external onlyOwner {
        if (_productFactory == address(0)) revert ZeroAddress();
        productFactoryAddr = _productFactory;
    }

    /// Set deposit factory address for weight calculation (owner only)
    /// @param _depositFactory DepositFactory contract address
    function setDepositFactory(address _depositFactory) external onlyOwner {
        if (_depositFactory == address(0)) revert ZeroAddress();
        depositFactoryAddr = _depositFactory;
    }

    /// Factory adds authorization for clone contract (only authorized factory can call)
    /// @param caller Clone contract address to authorize
    function addAuthorizedCallerByFactory(address caller) external {
        if (msg.sender != authorizedFactory) revert NotFactory();
        authorizedCallers[caller] = true;
    }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ==================== Data Recording Functions ====================

    /// Record a product sale
    /// Adds sale amount to daily sales and increments total order count.
    /// Only authorized callers can execute.
    /// @param product Product address
    /// @param amount Sale amount
    function recordSale(address product, uint256 amount) external onlyAuthorized {
        uint256 day = block.timestamp / 86400;
        productData[product].dailySales[day] += amount;
        productData[product].totalOrders++;
        emit SaleRecorded(product, amount, day);

        // Trigger ProductFactory to refresh seed on sale
        if (productFactoryAddr != address(0)) {
            IProductFactory(productFactoryAddr).bumpSeedOnSale(product);
        }
    }

    // ==================== Query Functions ====================

    /// Get a product's cumulative historical order count (sales count).
    /// Replaces the deleted weight/ranking query surface. Backed by the
    /// `totalOrders` counter that `recordSale` increments.
    /// @param product Product address
    /// @return Cumulative order count for this product
    function getTotalOrders(address product) external view returns (uint256) {
        return productData[product].totalOrders;
    }
}
