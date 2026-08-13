// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #26: CommunityArbitrationFactory — Community Arbitration Factory
 * Responsibility: Manage arbitrator qualifications, deploy case clones, track active cases, global vote interval
 * Deploy order: #26 (depends on PlatformSettings, DepositFactory, CommunityArbitrationTemplate)
 *
 * Business flow:
 *   1. Merchants with deposit >= 1000 USDT qualify as arbitrators after cooldown
 *   2. Business contracts call createCase() to deploy a case clone
 *   3. Case clones call back for vote tracking, resolution, and arbitrator penalties
 */

import "./interfaces/Interfaces.sol";

/// @title CommunityArbitrationFactory - Community Arbitration Case Deployer
/// @author WEB3GUARANTEE
contract CommunityArbitrationFactory {

    // ==================== Constants ====================

    uint256 public immutable ARBITRATOR_MIN_DEPOSIT;
    uint256 public constant QUALIFY_COOLDOWN = 30 days; // production
    uint256 public constant EVIDENCE_WINDOW = 24 hours; // production
    uint256 public constant VOTING_DURATION = 48 hours; // production
    uint256 public constant VOTE_INTERVAL = 10 minutes; // production
    uint256 public constant MAX_ARBITRATORS = 13; // production
    uint256 public constant ARBITRATION_WINDOW = 7 days; // production — 对齐前端 contracts.ts ARBITRATION_WINDOW_MS
    uint256 public constant WRONG_VOTE_LIMIT = 3;
    uint256 public constant WRONG_VOTE_COOLDOWN = 30 days; // production
    uint256 public constant ARBITRATION_FEE_RATE = 1000;
    uint256 public constant COMMUNITY_SHARE = 9000;
    uint256 public constant PLATFORM_SHARE = 1000;

    // ==================== State Variables ====================

    address public owner;
    IPlatformSettings public settings;
    address public caseTemplate;
    /// USDT address (for arbitrator qualification check)
    address public usdtAddr;
    /// Case => payment token used by that case (for Template self-lookup)
    mapping(address => address) public caseToken;

    // --- Arbitrator management ---
    mapping(address => uint256) public arbitratorQualifyTime;
    mapping(address => uint256) public arbitratorWrongVotes;
    mapping(address => uint256) public arbitratorCooldownUntil;

    // --- Case management (swap-delete) ---
    address[] public activeCases;
    mapping(address => uint256) public activeCaseIndex;
    address[] public allCases;
    mapping(address => bool) public isFactoryCase;
    mapping(address => mapping(bytes16 => address)) public businessCaseMap;

    // --- Language market isolation: index cases by language ---
    mapping(string => address[]) public casesByLanguage;
    mapping(address => string) public caseLanguage;
    mapping(address => uint256) public caseLanguageIndex;

    // --- Global vote interval ---
    uint256 public lastGlobalVoteTime;

    // ==================== Events ====================

    event CaseCreated(address indexed caseAddr, address indexed businessContract, bytes16 orderId, BusinessType businessType);
    event CaseResolved(address indexed caseAddr);
    event ArbitratorQualified(address indexed arbitrator, uint256 qualifyTime);
    event ArbitratorDisqualified(address indexed arbitrator);
    event ArbitratorPenalized(address indexed arbitrator, uint256 cooldownUntil);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    // ==================== Constructor ====================

    constructor(address _settings, address _caseTemplate, address _usdt) {
        if (_settings == address(0) || _caseTemplate == address(0) || _usdt == address(0)) revert ZeroAddress();
        owner = msg.sender;
        settings = IPlatformSettings(_settings);
        caseTemplate = _caseTemplate;
        usdtAddr = _usdt;
        ARBITRATOR_MIN_DEPOSIT = 1000 * (10 ** uint256(IERC20(_usdt).decimals()));
    }

    // ==================== Modifiers ====================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setCaseTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); caseTemplate = _tpl; }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    modifier onlyFactoryCase() {
        if (!isFactoryCase[msg.sender]) revert NotFactoryCase();
        _;
    }

    // ==================== Arbitrator Management ====================

    /// @dev Arbitrator deposit qualification = USDT balance >= 1000 USD
    function _arbitratorBalance(address depositAddr) internal view returns (uint256) {
        IMerchantDeposit dep = IMerchantDeposit(depositAddr);
        return dep.balanceOf(usdtAddr);
    }

    function refreshArbitratorQualification(address merchant) external {
        address depositAddr = IDepositFactory(settings.getDepositFactory()).getDeposit(merchant);
        if (depositAddr == address(0)) {
            if (arbitratorQualifyTime[merchant] != 0) {
                arbitratorQualifyTime[merchant] = 0;
                emit ArbitratorDisqualified(merchant);
            }
            return;
        }
        uint256 bal = _arbitratorBalance(depositAddr);
        if (bal >= ARBITRATOR_MIN_DEPOSIT) {
            if (arbitratorQualifyTime[merchant] == 0) {
                arbitratorQualifyTime[merchant] = block.timestamp;
                emit ArbitratorQualified(merchant, block.timestamp);
            }
        } else {
            if (arbitratorQualifyTime[merchant] != 0) {
                arbitratorQualifyTime[merchant] = 0;
                emit ArbitratorDisqualified(merchant);
            }
        }
    }

    function isQualifiedArbitrator(address addr) public view returns (bool) {
        uint256 qt = arbitratorQualifyTime[addr];
        if (qt == 0) return false;
        if (block.timestamp < qt + QUALIFY_COOLDOWN) return false;
        if (block.timestamp < arbitratorCooldownUntil[addr]) return false;
        address depositAddr = IDepositFactory(settings.getDepositFactory()).getDeposit(addr);
        if (depositAddr == address(0)) return false;
        if (_arbitratorBalance(depositAddr) < ARBITRATOR_MIN_DEPOSIT) return false;
        return true;
    }

    /// @notice Reset wrong vote count after cooldown expires (anyone can call, only effective when cooldown has passed)
    function resetWrongVotesIfCooldownExpired(address addr) external {
        if (arbitratorCooldownUntil[addr] == 0) return;
        if (block.timestamp < arbitratorCooldownUntil[addr]) return;
        arbitratorWrongVotes[addr] = 0;
        arbitratorCooldownUntil[addr] = 0;
    }

    // ==================== Case Management ====================

    /// @notice Create arbitration case (dual payment channel: business contract passes order paymentToken)
    /// @dev Design: each business order may create only one community arbitration case for its lifetime.
    function createCase(CaseInitParams calldata params, address paymentToken) external returns (address) {
        if (!settings.isAuthorizedContract(msg.sender)) revert NotAuthorized();
        if (params.businessContract != msg.sender) revert NotAuthorized();
        if (businessCaseMap[params.businessContract][params.orderId] != address(0)) revert CaseAlreadyExists();
        if (paymentToken == address(0)) revert PaymentTokenRequired();
        if (paymentToken != usdtAddr) revert TokenNotAccepted();

        address caseAddr = _clone(caseTemplate);
        // Write paymentToken into caseToken mapping, Template.initialize fetches it back via factory
        caseToken[caseAddr] = paymentToken;
        ICommunityArbitrationTemplate(caseAddr).initialize(
            params, EVIDENCE_WINDOW, VOTING_DURATION, MAX_ARBITRATORS
        );

        isFactoryCase[caseAddr] = true;
        activeCaseIndex[caseAddr] = activeCases.length;
        activeCases.push(caseAddr);
        allCases.push(caseAddr);
        businessCaseMap[params.businessContract][params.orderId] = caseAddr;

        // Language market isolation: read language from case and index it
        string memory language = ICommunityArbitrationTemplate(caseAddr).language();
        if (bytes(language).length > 0) {
            caseLanguage[caseAddr] = language;
            caseLanguageIndex[caseAddr] = casesByLanguage[language].length;
            casesByLanguage[language].push(caseAddr);
        }

        settings.authorizeContractByFactory(caseAddr);

        emit CaseCreated(caseAddr, params.businessContract, params.orderId, params.businessType);
        return caseAddr;
    }

    /// @notice Get payment token for a specified case (Template fetches this during initialize)
    function getCaseToken(address caseAddr) external view returns (address) {
        return caseToken[caseAddr];
    }

    function caseResolved(address caseAddr) external onlyFactoryCase {
        // [H-21 fix]: Delete isFactoryCase FIRST to act as reentrancy lock
        delete isFactoryCase[caseAddr];

        // Design: businessCaseMap is intentionally retained as an immutable per-order case record.
        uint256 idx = activeCaseIndex[caseAddr];
        uint256 last = activeCases.length - 1;
        if (idx != last) {
            address moved = activeCases[last];
            activeCases[idx] = moved;
            activeCaseIndex[moved] = idx;
        }
        activeCases.pop();
        delete activeCaseIndex[caseAddr];

        emit CaseResolved(caseAddr);
    }

    // ==================== Vote Tracking ====================

    function recordVoteResult(address arbitrator, bool wasCorrect) external onlyFactoryCase {
        uint256 cooldownEnd = arbitratorCooldownUntil[arbitrator];
        if (cooldownEnd != 0 && block.timestamp >= cooldownEnd) {
            arbitratorWrongVotes[arbitrator] = 0;
            arbitratorCooldownUntil[arbitrator] = 0;
        }
        if (!wasCorrect) {
            uint256 wrongVotes = arbitratorWrongVotes[arbitrator] + 1;
            if (wrongVotes >= WRONG_VOTE_LIMIT) {
                arbitratorCooldownUntil[arbitrator] = block.timestamp + WRONG_VOTE_COOLDOWN;
                arbitratorWrongVotes[arbitrator] = 0;
                emit ArbitratorPenalized(arbitrator, arbitratorCooldownUntil[arbitrator]);
            } else {
                arbitratorWrongVotes[arbitrator] = wrongVotes;
            }
        }
    }

    function updateGlobalVoteTime() external onlyFactoryCase {
        lastGlobalVoteTime = block.timestamp;
    }

    // ==================== Query Functions ====================

    function getActiveCases(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = activeCases.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = activeCases[i];
        }
        return result;
    }

    function getActiveCaseCount() external view returns (uint256) {
        return activeCases.length;
    }

    function getCaseForBusiness(address businessContract, bytes16 orderId) external view returns (address) {
        return businessCaseMap[businessContract][orderId];
    }

    function getArbitratorInfo(address addr) external view returns (
        uint256 qualifyTime, uint256 wrongVotes, uint256 cooldownUntil, bool qualified
    ) {
        return (
            arbitratorQualifyTime[addr],
            arbitratorWrongVotes[addr],
            arbitratorCooldownUntil[addr],
            isQualifiedArbitrator(addr)
        );
    }

    function getAllCases(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = allCases.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allCases[i];
        }
        return result;
    }

    /// Language market isolation: get cases by language with pagination
    function getCasesByLanguage(string calldata language, uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = casesByLanguage[language].length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = casesByLanguage[language][i];
        }
        return result;
    }

    /// Language market isolation: get case count by language
    function getCaseCountByLanguage(string calldata language) external view returns (uint256) {
        return casesByLanguage[language].length;
    }

    // ==================== EIP-1167 Clone ====================

    // Audit note [H-03]: Using create instead of create2 is an intentional choice.
    // (1) Target chains (BSC/Polygon PoS) have extremely rare and short reorgs
    // (2) Clone address is immediately registered to factory mapping in the same transaction
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
}
