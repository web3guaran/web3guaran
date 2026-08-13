// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "./interfaces/Interfaces.sol";

/**
 * Contract #16: ArchiveStore — Generational Archive Storage
 * Responsibility: Provides generational storage for unbounded history arrays, preventing single-contract storage bloat
 *
 * Design:
 *   - Each generation stores up to GENERATION_SIZE records (default 1000)
 *   - When current generation is full, factory creates a new ArchiveStore instance as next generation
 *   - Queries locate the correct generation via factory's generational index
 *   - Each generation contract stores independently
 *
 * Storage types:
 *   - global: Global list (e.g. allProducts, allTrades)
 *   - perUser: Per-user grouped (e.g. buyerOrders[buyer], userTrades[user], sellerProducts[seller])
 */
/// @title ArchiveStore - Generational Archive Storage
/// @author WEB3GUARANTEE
/// @notice Provides bounded storage for historical records with automatic generation rollover at 1000 entries
contract ArchiveStore {

    // ==================== State Variables ====================

    /// Factory contract address (only factory can write)
    address public factory;

    // Audit note [3.2.2]: GENERATION_SIZE is intentionally hardcoded to 1000.
    // 1000 per generation balances deployment cost and query efficiency for current business volume.
    // If volume changes, new generations can use a different size by upgrading the factory contract.
    uint256 public constant GENERATION_SIZE = 1000;

    /// Max page size for paginated queries
    uint256 public constant MAX_PAGE_SIZE = 24;

    /// Global archive list
    address[] public globalArchive;

    /// Per-user archive list (user address => their record address list)
    mapping(address => address[]) public userArchive;

    // ==================== Modifier ====================

    /// Clone mode init flag
    bool public initialized;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ==================== Initialize (EIP-1167 clone) ====================

    function initialize(address _factory) external {
        if (initialized) revert AlreadyInit();
        initialized = true;
        factory = _factory;
    }

    // ==================== Write Functions ====================

    /// @notice Push a global archive record
    /// @param record Record address
    /// @return isFull Whether this generation is full (factory should create a new one)
    function pushGlobal(address record) external onlyFactory returns (bool isFull) {
        globalArchive.push(record);
        isFull = globalArchive.length >= GENERATION_SIZE;
    }

    /// @notice Push a user archive record
    /// @param user User address
    /// @param record Record address
    function pushUser(address user, address record) external onlyFactory {
        userArchive[user].push(record);
    }

    // ==================== Query Functions ====================

    /// @notice Paginated global archive list
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Address array
    function getGlobalRecords(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginate(globalArchive, offset, limit);
    }

    /// @notice Get global archive count
    function getGlobalCount() external view returns (uint256) {
        return globalArchive.length;
    }

    /// @notice Paginated user archive list
    /// @param user User address
    /// @param offset Start offset
    /// @param limit Max return count
    /// @return Address array
    function getUserRecords(address user, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginate(userArchive[user], offset, limit);
    }

    /// @notice Get user archive count
    /// @param user User address
    /// @return Archive record count
    function getUserCount(address user) external view returns (uint256) {
        return userArchive[user].length;
    }

    // ==================== Internal Functions ====================

    function _paginate(address[] storage arr, uint256 offset, uint256 limit) internal view returns (address[] memory) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 total = arr.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; ) {
            result[i - offset] = arr[i];
            unchecked { i++; }
        }
        return result;
    }
}
