// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "./interfaces/Interfaces.sol";

contract ProductFactoryKeywords {
    address public settingsAddr;
    address public owner;
    address public factory;

    mapping(bytes32 => bool) public approvedKeywordKeys;
    mapping(bytes32 => uint8) public keywordTypeByKey;
    mapping(bytes32 => string) public keywordLanguage;
    mapping(bytes32 => string) public keywordText;

    mapping(string => bytes32[]) public physicalKeywordKeysByLanguage;
    mapping(string => bytes32[]) public virtualKeywordKeysByLanguage;
    mapping(string => bytes32[]) public serviceKeywordKeysByLanguage;
    mapping(string => bytes32[]) public wantToBuyKeywordKeysByLanguage;
    mapping(bytes32 => uint256) public typeKeywordIndex;

    bytes32[] public allKeywordKeys;
    mapping(bytes32 => bool) public keywordExists;
    mapping(string => bytes32[]) public keywordKeysByLanguage;

    uint256 public constant MAX_KEYWORD_LENGTH = 64;
    uint256 public constant MAX_LANGUAGE_LENGTH = 16;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant MAX_KEYWORDS_PER_LANGUAGE = 100000;
    uint256 public constant MAX_KEYWORDS_PER_TYPE = 50000;

    /// @notice Incremental counter: tracks approved keyword count per language
    mapping(string => uint256) public approvedKeywordCountByLanguage;
    /// @notice Incremental counter: tracks approved keyword count per language + type
    mapping(string => mapping(uint8 => uint256)) public approvedKeywordCountByLanguageAndType;

    event KeywordApproved(bytes32 indexed keywordKey, string language, string keyword, uint8 productType);
    event KeywordDelisted(bytes32 indexed keywordKey, string language, string keyword);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyAdminOrCS() {
        if (msg.sender != owner && !IPlatformSettings(settingsAddr).isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        _;
    }
    constructor(address _settings) {
        owner = msg.sender;
        settingsAddr = _settings;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    function getKeywordKey(string memory _language, string memory _keyword) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_language, ":", _keyword));
    }

    function addApprovedKeyword(string calldata _language, string calldata _keyword, uint8 _productType) external onlyAdminOrCS {
        _validateKeyword(_language, _keyword, _productType);

        // Check global cap and per-type cap
        if (approvedKeywordCountByLanguage[_language] >= MAX_KEYWORDS_PER_LANGUAGE) revert TooHigh();
        if (approvedKeywordCountByLanguageAndType[_language][_productType] >= MAX_KEYWORDS_PER_TYPE) revert TooHigh();

        bytes32 key = getKeywordKey(_language, _keyword);
        if (approvedKeywordKeys[key]) revert AlreadyApproved();
        keywordLanguage[key] = _language;
        keywordText[key] = _keyword;
        keywordTypeByKey[key] = _productType;
        approvedKeywordKeys[key] = true;
        _addKnownKeyword(key, _language);
        _addToTypeArray(key, _productType);

        // Increment counters
        approvedKeywordCountByLanguage[_language]++;
        approvedKeywordCountByLanguageAndType[_language][_productType]++;

        emit KeywordApproved(key, _language, _keyword, _productType);
    }

    function batchAddApprovedKeywords(string calldata _language, string[] calldata _keywords, uint8[] calldata _productTypes) external onlyAdminOrCS {
        if (_keywords.length > MAX_BATCH_SIZE) revert ExceedsMaxDeposit(); // reuse existing error type
        if (_keywords.length != _productTypes.length) revert LengthMismatch();

        // Track the number added per type in this batch (uses an array instead of a mapping)
        uint256 addedTotal;
        uint256[6] memory typeCounts; // supports types 0-5

        for (uint i; i < _keywords.length; i++) {
            _validateKeyword(_language, _keywords[i], _productTypes[i]);
            bytes32 key = getKeywordKey(_language, _keywords[i]);
            if (approvedKeywordKeys[key]) continue;

            // Check caps (pre-check)
            if (approvedKeywordCountByLanguage[_language] + addedTotal >= MAX_KEYWORDS_PER_LANGUAGE) revert TooHigh();
            if (approvedKeywordCountByLanguageAndType[_language][_productTypes[i]] + typeCounts[_productTypes[i]] >= MAX_KEYWORDS_PER_TYPE) revert TooHigh();

            keywordLanguage[key] = _language;
            keywordText[key] = _keywords[i];
            keywordTypeByKey[key] = _productTypes[i];
            approvedKeywordKeys[key] = true;
            _addKnownKeyword(key, _language);
            _addToTypeArray(key, _productTypes[i]);

            addedTotal++;
            typeCounts[_productTypes[i]]++;

            emit KeywordApproved(key, _language, _keywords[i], _productTypes[i]);
        }

        // Increment counters
        approvedKeywordCountByLanguage[_language] += addedTotal;
        for (uint8 t = 0; t < 6; t++) {
            if (typeCounts[t] > 0) {
                approvedKeywordCountByLanguageAndType[_language][t] += typeCounts[t];
            }
        }
    }

    function delistKeyword(string calldata _language, string calldata _keyword) external onlyAdminOrCS {
        bytes32 key = getKeywordKey(_language, _keyword);
        if (!approvedKeywordKeys[key]) revert NotApproved();
        uint8 pType = keywordTypeByKey[key];
        approvedKeywordKeys[key] = false;
        _removeFromTypeArray(key, pType);

        // Decrement counters
        if (approvedKeywordCountByLanguage[_language] > 0) {
            approvedKeywordCountByLanguage[_language]--;
        }
        if (approvedKeywordCountByLanguageAndType[_language][pType] > 0) {
            approvedKeywordCountByLanguageAndType[_language][pType]--;
        }

        emit KeywordDelisted(key, _language, _keyword);
    }

    function isApproved(string calldata _language, string calldata _keyword) external view returns (bool) {
        return approvedKeywordKeys[getKeywordKey(_language, _keyword)];
    }

    function getKeywordsByType(string calldata _language, uint8 _type) external view returns (string[] memory) {
        bytes32[] storage keys = _type == 0 ? physicalKeywordKeysByLanguage[_language] : _type == 1 ? virtualKeywordKeysByLanguage[_language] : _type == 2 ? serviceKeywordKeysByLanguage[_language] : wantToBuyKeywordKeysByLanguage[_language];
        return _keysToTexts(keys);
    }

    /// @notice Get keywords with pagination
    function getKeywordsPaginated(string calldata _language, uint256 offset, uint256 limit)
        external view returns (string[] memory result, uint256 total) {
        bytes32[] storage keys = keywordKeysByLanguage[_language];
        total = keys.length;

        if (offset >= total) return (new string[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 len = end - offset;
        result = new string[](len);

        for (uint256 i = 0; i < len; i++) {
            result[i] = keywordText[keys[offset + i]];
        }
    }

    function getPhysicalKeywordCount(string calldata language) external view returns (uint256) { return physicalKeywordKeysByLanguage[language].length; }
    function getVirtualKeywordCount(string calldata language) external view returns (uint256) { return virtualKeywordKeysByLanguage[language].length; }
    function getServiceKeywordCount(string calldata language) external view returns (uint256) { return serviceKeywordKeysByLanguage[language].length; }

    /// @notice Get total approved keyword count for a given language (for monitoring, O(1) complexity)
    function getApprovedKeywordCountByLanguage(string calldata language) external view returns (uint256) {
        return approvedKeywordCountByLanguage[language];
    }

    /// @notice Get approved keyword count for a given language and type (for monitoring)
    function getApprovedKeywordCountByType(string calldata language, uint8 productType) external view returns (uint256) {
        return approvedKeywordCountByLanguageAndType[language][productType];
    }

    /// @notice Get the per-language keyword count cap constant
    function getMaxKeywordsPerLanguage() external pure returns (uint256) {
        return MAX_KEYWORDS_PER_LANGUAGE;
    }

    /// @notice Get the per-type keyword count cap constant
    function getMaxKeywordsPerType() external pure returns (uint256) {
        return MAX_KEYWORDS_PER_TYPE;
    }
    function getWantToBuyKeywordCount(string calldata language) external view returns (uint256) { return wantToBuyKeywordKeysByLanguage[language].length; }
    function getAllKeywordCount(string calldata language) external view returns (uint256) { return keywordKeysByLanguage[language].length; }

    function _validateKeyword(string calldata _language, string calldata _keyword, uint8 _productType) internal pure {
        if (bytes(_language).length == 0 || bytes(_keyword).length == 0) revert EmptyKeyword();
        if (bytes(_language).length > MAX_LANGUAGE_LENGTH || bytes(_keyword).length > MAX_KEYWORD_LENGTH) revert KeywordTooLong();
        if (_productType > 3) revert InvalidType();
    }

    function _addKnownKeyword(bytes32 key, string calldata _language) internal {
        if (!keywordExists[key]) {
            keywordExists[key] = true;
            allKeywordKeys.push(key);
            keywordKeysByLanguage[_language].push(key);
        }
    }

    function _addToTypeArray(bytes32 key, uint8 _type) internal {
        bytes32[] storage arr = _type == 0 ? physicalKeywordKeysByLanguage[keywordLanguage[key]] : _type == 1 ? virtualKeywordKeysByLanguage[keywordLanguage[key]] : _type == 2 ? serviceKeywordKeysByLanguage[keywordLanguage[key]] : wantToBuyKeywordKeysByLanguage[keywordLanguage[key]];
        typeKeywordIndex[key] = arr.length;
        arr.push(key);
    }

    function _removeFromTypeArray(bytes32 key, uint8 _type) internal {
        bytes32[] storage arr = _type == 0 ? physicalKeywordKeysByLanguage[keywordLanguage[key]] : _type == 1 ? virtualKeywordKeysByLanguage[keywordLanguage[key]] : _type == 2 ? serviceKeywordKeysByLanguage[keywordLanguage[key]] : wantToBuyKeywordKeysByLanguage[keywordLanguage[key]];
        uint256 idx = typeKeywordIndex[key];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            bytes32 lastKey = arr[lastIdx];
            arr[idx] = lastKey;
            typeKeywordIndex[lastKey] = idx;
        }
        arr.pop();
        delete typeKeywordIndex[key];
    }

    function _keysToTexts(bytes32[] storage keys) internal view returns (string[] memory result) {
        uint256 len = keys.length;
        result = new string[](len);
        for (uint256 i = 0; i < len;) { result[i] = keywordText[keys[i]]; unchecked { ++i; } }
    }
}

