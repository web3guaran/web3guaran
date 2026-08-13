// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * ServiceLocationIndex — Service Product Geographic Index Contract
 *
 * Hierarchy: Keyword -> Country -> Province -> City -> Product list
 * Called by ProductFactory when creating/delisting service products
 * Frontend expands level by level, eventually paginating products at city level
 */

contract ServiceLocationIndex {

    address public factory;
    address public owner;
    uint256 public constant MAX_PAGE_SIZE = 24;

    // Hierarchy index key rules:
    // Countries under a keyword: keccak256(language, keyword) -> countries[]
    // Provinces under a country: keccak256(language, keyword, country) -> provinces[]
    // Cities under a province: keccak256(language, keyword, country, province) -> cities[]
    // Products under a city: keccak256(language, keyword, country, province, city) -> products[]

    // Keyword -> Country
    mapping(bytes32 => string[]) public keywordCountries;
    mapping(bytes32 => mapping(bytes32 => bool)) public countryExists;

    // Keyword+Country -> Province
    mapping(bytes32 => string[]) public countryProvinces;
    mapping(bytes32 => mapping(bytes32 => bool)) public provinceExists;

    // Keyword+Country+Province -> City
    mapping(bytes32 => string[]) public provinceCities;
    mapping(bytes32 => mapping(bytes32 => bool)) public cityExists;

    // City -> Product list
    mapping(bytes32 => address[]) public cityProducts;
    mapping(address => uint256) public productCityIndex;
    mapping(address => bytes32) public productCityKey;

    // ==================== Errors ====================
    error NotFactory();
    error NotOwner();
    error ZeroAddress();

    
    // ==================== Events ====================
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        owner = msg.sender;
        factory = _factory;
    }

    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    // ==================== Register (called by Factory when creating service product) ====================

    function registerProduct(
        address product,
        string calldata language,
        string calldata keyword,
        string calldata country,
        string calldata province,
        string calldata city
    ) external onlyFactory {
        bytes32 cityKey = _buildHierarchy(language, keyword, country, province, city);
        productCityIndex[product] = cityProducts[cityKey].length;
        productCityKey[product] = cityKey;
        cityProducts[cityKey].push(product);
    }

    function _buildHierarchy(
        string calldata language,
        string calldata keyword,
        string calldata country,
        string calldata province,
        string calldata city
    ) internal returns (bytes32) {
        bytes32 provinceKey;
        {
            // [M-10 fix]: Use abi.encode to prevent hash collisions
            bytes32 kwKey = keccak256(abi.encode(language, keyword));
            bytes32 countryHash = keccak256(bytes(country));
            if (!countryExists[kwKey][countryHash]) {
                countryExists[kwKey][countryHash] = true;
                keywordCountries[kwKey].push(country);
            }
        }
        {
            // [M-10 fix]: Use abi.encode to prevent hash collisions
            bytes32 countryKey = keccak256(abi.encode(language, keyword, country));
            bytes32 provinceHash = keccak256(bytes(province));
            if (!provinceExists[countryKey][provinceHash]) {
                provinceExists[countryKey][provinceHash] = true;
                countryProvinces[countryKey].push(province);
            }
            // [M-10 fix]: Use abi.encode to prevent hash collisions
            provinceKey = keccak256(abi.encode(language, keyword, country, province));
        }
        {
            bytes32 cityHash = keccak256(bytes(city));
            if (!cityExists[provinceKey][cityHash]) {
                cityExists[provinceKey][cityHash] = true;
                provinceCities[provinceKey].push(city);
            }
        }
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        return keccak256(abi.encode(language, keyword, country, province, city));
    }

    // ==================== Remove (called by Factory when delisting service product) ====================

    function removeProduct(address product) external onlyFactory {
        bytes32 cityKey = productCityKey[product];
        if (cityKey == bytes32(0)) return;

        address[] storage arr = cityProducts[cityKey];
        uint256 idx = productCityIndex[product];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            address last = arr[lastIdx];
            arr[idx] = last;
            productCityIndex[last] = idx;
        }
        arr.pop();
        delete productCityIndex[product];
        delete productCityKey[product];
    }

    // ==================== Query ====================

    /// @notice Get list of countries under a keyword
    function getCountries(string calldata language, string calldata keyword) external view returns (string[] memory) {
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        bytes32 kwKey = keccak256(abi.encode(language, keyword));
        return keywordCountries[kwKey];
    }

    /// @notice Get list of provinces under a country
    function getProvinces(string calldata language, string calldata keyword, string calldata country) external view returns (string[] memory) {
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        bytes32 countryKey = keccak256(abi.encode(language, keyword, country));
        return countryProvinces[countryKey];
    }

    /// @notice Get list of cities under a province
    function getCities(string calldata language, string calldata keyword, string calldata country, string calldata province) external view returns (string[] memory) {
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        bytes32 provinceKey = keccak256(abi.encode(language, keyword, country, province));
        return provinceCities[provinceKey];
    }

    /// @notice Get product count under a city
    function getCityProductCount(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) external view returns (uint256) {
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        bytes32 cityKey = keccak256(abi.encode(language, keyword, country, province, city));
        return cityProducts[cityKey].length;
    }

    /// @notice Paginated retrieval of product addresses under a city
    function getProductsByCity(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city, uint256 offset, uint256 limit) external view returns (address[] memory) {
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        bytes32 cityKey = keccak256(abi.encode(language, keyword, country, province, city));
        address[] storage arr = cityProducts[cityKey];
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= arr.length) return new address[](0);
        uint256 end = offset + limit > arr.length ? arr.length : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = arr[i];
        }
        return result;
    }

    /// @notice Get city key (for use by KeywordAuction)
    function getCityKey(string calldata language, string calldata keyword, string calldata country, string calldata province, string calldata city) external pure returns (bytes32) {
        // [M-10 fix]: Use abi.encode to prevent hash collisions
        return keccak256(abi.encode(language, keyword, country, province, city));
    }
}
