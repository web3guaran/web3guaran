// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * Contract #10: DepositFactory - Deposit Factory
 * Responsibility: Clone-deploys merchant deposit contracts (MerchantDepositTemplate)
 * Deployment: 12th to deploy
 *
 * Workflow:
 *     1. Merchant calls createDeposit() to create a deposit contract
 *     2. Factory clones MerchantDepositTemplate via EIP-1167
 *     3. Initializes clone and records merchant-to-deposit mapping
 *     4. Each merchant can only create one deposit contract
 */

import "./interfaces/Interfaces.sol";
import "./MerchantDepositTemplate.sol";

/// @title DepositFactory - Merchant Deposit Deployment Factory
/// @author WEB3GUARANTEE
/// @notice Deploys merchant deposit contracts via EIP-1167 clone and manages deposit-merchant mappings
contract DepositFactory {

    // ==================== Anti-Contract Call ====================

    /// @dev Reject unauthorized contract calls; only EOA or whitelisted contract wallets allowed
    modifier noContract() {
        if (msg.sender != tx.origin) revert NoContractCalls();
        _;
    }

    // ==================== State Variables ====================

    // ===== Payment Channel (BSC Mainnet Address) =====
    /// BSC Mainnet USDT
    address public constant USDT_ADDRESS = 0x55d398326f99059fF775485246999027B3197955;

    /// Contract owner (deployer)
    address public owner;

    /// Merchant deposit template address (for EIP-1167 cloning)
    address public depositTemplate;

    /// Platform settings contract address
    address public settingsAddr;

    /// USDT token contract address
    address public usdtAddr;

    /// Merchant address => deposit contract address (one per merchant max)
    mapping(address => address) public merchantDeposit;

    /// List of all created deposit contract addresses
    address[] public allDeposits;

    /// Unified merchant deposit unlock cooldown starts only after all business domains are inactive.
    mapping(address => uint256) public unlockCooldownStart;
    uint256 public constant UNLOCK_COOLDOWN_PERIOD = 24 hours; // production

    /// True only for the duration of an admin-forced zombie-recycle sweep
    /// (adminRecycleDeposit / continueRecycleDeposit). While true, refreshMerchantActivity
    /// is a no-op: the forced delist/cancel callbacks route through it in the SAME tx, and
    /// counting that platform-forced cleanup as "merchant activity" would reset the zombie
    /// inactivity timer (lastActivityTime), making forceRecycle's inactivity check impossible
    /// to pass. Set/cleared synchronously inside the admin-only recycle functions; EVM is
    /// single-threaded so no external call can interleave while it is true, and any revert
    /// rolls it back to false automatically.
    bool private _recycling;

    // ==================== Events ====================

    /// Emitted when a deposit contract is created
    event DepositCreated(address indexed merchant, address depositContract);

    /// Emitted during zombie deposit recycling
    event DepositRecycled(address indexed merchant, address depositContract);
    event UnlockCooldownStarted(address indexed merchant, uint256 startTime, uint256 endTime);
    event UnlockCooldownReset(address indexed merchant);
    /// Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    // ==================== Modifiers ====================

    // Audit note: owner is a Gnosis Safe multisig; all onlyOwner operations require multi-sig confirmation
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    // ==================== Constructor ====================

    /**
     * @notice Deploy deposit factory contract
     * @param _depositTemplate Merchant deposit template contract address
     * @param _settings Platform settings contract address
     */
    constructor(address _depositTemplate, address _settings) {
        if (_depositTemplate == address(0) || _settings == address(0)) revert ZeroAddress();
        owner = msg.sender;
        depositTemplate = _depositTemplate;
        settingsAddr = _settings;
        usdtAddr = USDT_ADDRESS;
    }

    function setDepositTemplate(address _tpl) external onlyOwner { if (_tpl == address(0)) revert ZeroAddress(); depositTemplate = _tpl; }

    /// Transfer contract ownership to a new owner
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }


    // ==================== Core Functions ====================

    /**
     * @notice Merchant creates a deposit contract (USDT only)
     * @dev Each merchant can only create one deposit contract. After creation, use deposit(amount, token) to fund USDT.
     * @return Newly created deposit contract address
     */
    function createDeposit() external noContract returns (address) {
        if (merchantDeposit[msg.sender] != address(0)) revert AlreadyHasDeposit();
        if (IPlatformSettings(settingsAddr).isBlacklisted(msg.sender)) revert IsBlacklisted();

        address clone = _clone(depositTemplate);
        address[] memory tokenList = new address[](1);
        tokenList[0] = usdtAddr;
        MerchantDepositTemplate(clone).initialize(msg.sender, tokenList, settingsAddr);
        IPlatformSettings(settingsAddr).authorizeContractByFactory(clone);
        merchantDeposit[msg.sender] = clone;
        allDeposits.push(clone);
        emit DepositCreated(msg.sender, clone);
        return clone;
    }

    // ==================== Zombie Deposit Activity Refresh ====================

    /**
     * @notice Refresh merchant deposit activity timestamp (only callable by the three factories)
     * @dev When a merchant performs platform operations (list/ship/delist products, C2C, auction, etc.),
     *           this is called by ProductFactory / C2CFactory / AuctionFactory as a relay.
     *           Silently skips addresses without deposits (buyer operations may also trigger this; should not revert).
     * @param merchant Merchant address
     */
    function refreshMerchantActivity(address merchant) external {
        IPlatformSettings _s = IPlatformSettings(settingsAddr);
        address pf = _s.getProductFactory();
        address cf = _s.getC2CFactory();
        address af = _s.getAuctionFactory();
        address dep = merchantDeposit[merchant];
        if (msg.sender != pf && msg.sender != cf && msg.sender != af && msg.sender != dep) revert NotAuthorized();
        if (dep != address(0)) {
            // Skip the activity refresh during an admin-forced recycle sweep: the forced
            // delist/cancel callbacks reach here in the same tx, and refreshing lastActivityTime
            // would reset the zombie timer and block forceRecycle. Cooldown bookkeeping is left
            // untouched (harmless during recycle, and correct for the normal path).
            if (!_recycling) {
                IMerchantDeposit(dep).refreshActivity();
            }
            _refreshUnlockCooldown(merchant);
        }
    }


    // ==================== Unified Unlock Cooldown ====================


    function _businessCounts(address merchant) internal view returns (
        uint256 activeProducts,
        uint256 activeAuctions,
        uint256 activeC2COrders,
        uint256 activeTrades
    ) {
        IPlatformSettings _s = IPlatformSettings(settingsAddr);
        address pf = _s.getProductFactory();
        if (pf != address(0)) {
            (activeProducts,,) = IProductFactory(pf).getDelistInfo(merchant);
        }
        address af = _s.getAuctionFactory();
        if (af != address(0)) {
            activeAuctions = IAuctionFactory(af).activeSellerAuctionCount(merchant);
        }
        address cf = _s.getC2CFactory();
        if (cf != address(0)) {
            activeC2COrders = IC2CFactory(cf).activeOrderCountOf(merchant);
        }
        address cm = _s.getCooldownManager();
        if (cm != address(0)) {
            activeTrades = ICooldownManager(cm).activeTradeCount(merchant);
        }
    }

    function _allBusinessSettled(address merchant) internal view returns (bool settled) {
        (uint256 activeProducts, uint256 activeAuctions, uint256 activeC2COrders, uint256 activeTrades) = _businessCounts(merchant);
        return activeProducts == 0 && activeAuctions == 0 && activeC2COrders == 0 && activeTrades == 0;
    }

    function _refreshUnlockCooldown(address merchant) internal {
        bool settled = _allBusinessSettled(merchant);
        uint256 start = unlockCooldownStart[merchant];
        if (settled) {
            if (start == 0) {
                uint256 nowTs = block.timestamp;
                unlockCooldownStart[merchant] = nowTs;
                emit UnlockCooldownStarted(merchant, nowTs, nowTs + UNLOCK_COOLDOWN_PERIOD);
            }
        } else if (start != 0) {
            unlockCooldownStart[merchant] = 0;
            emit UnlockCooldownReset(merchant);
        }
    }

    function refreshUnlockCooldown(address merchant) external {
        IPlatformSettings _s = IPlatformSettings(settingsAddr);
        address pf = _s.getProductFactory();
        address cf = _s.getC2CFactory();
        address af = _s.getAuctionFactory();
        address dep = merchantDeposit[merchant];
        // Allow the merchant to start their OWN unlock cooldown directly. Without this, a depositor who never
        // runs any business (e.g. someone who only staked >=1000 to qualify as an arbitrator) can never start
        // the cooldown: withdraw() starts it then reverts in the same tx (rolling back the start), and the only
        // other trigger (refreshMerchantActivity) fires on business events they never produce. The merchant can
        // only refresh their own cooldown (merchant == caller), it moves no funds, and _refreshUnlockCooldown
        // still gates start on all business being settled, so this cannot grief anyone.
        if (msg.sender != pf && msg.sender != cf && msg.sender != af && msg.sender != dep && msg.sender != merchant) revert NotAuthorized();
        if (dep != address(0)) {
            _refreshUnlockCooldown(merchant);
        }
    }

    function canWithdrawDeposit(address merchant) external view returns (bool) {
        if (!_allBusinessSettled(merchant)) return false;
        uint256 start = unlockCooldownStart[merchant];
        return start > 0 && block.timestamp >= start + UNLOCK_COOLDOWN_PERIOD;
    }

    function getUnlockCooldownInfo(address merchant) external view returns (
        bool conditionsMet,
        uint256 cooldownStart,
        uint256 cooldownEnd,
        bool canWithdraw,
        uint256 activeProducts,
        uint256 activeAuctions,
        uint256 activeC2COrders,
        uint256 activeTrades
    ) {
        (activeProducts, activeAuctions, activeC2COrders, activeTrades) = _businessCounts(merchant);
        conditionsMet = activeProducts == 0 && activeAuctions == 0 && activeC2COrders == 0 && activeTrades == 0;
        cooldownStart = unlockCooldownStart[merchant];
        cooldownEnd = cooldownStart > 0 ? cooldownStart + UNLOCK_COOLDOWN_PERIOD : 0;
        canWithdraw = conditionsMet && cooldownStart > 0 && block.timestamp >= cooldownEnd;
    }

    // ==================== Zombie Deposit Recycling ====================

    /**
     * @notice Admin recycles zombie deposit (merchant inactive for 365 days)
     * @dev Calls the deposit contract's forceRecycle(), transferring deposit to platform wallet
     * Audit note [H-01]: product/C2C batch cleanup may be partial because each factory limits per-call work.
     *   Recycling only proceeds when the unified business counters are already zero after cleanup.
     *   If more orders remain, the call reverts and admin/CS should call again until all batches are cleared.
     * Audit note: refreshMerchantActivity intentionally treats any successful merchant-controlled operation as activity.
     *   Zombie deposits model lost/private-key-abandoned accounts; an account able to act is not considered zombie.
     * Caller: admin only
     * @param _merchant Target merchant address
     */
    function adminRecycleDeposit(address _merchant) external {
        IPlatformSettings _s = IPlatformSettings(settingsAddr);
        if (!_s.isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        address depositAddr = merchantDeposit[_merchant];
        if (depositAddr == address(0)) revert NoDepositContract();
        // Suppress activity-timer refresh: the forced delist/cancel below route through
        // refreshMerchantActivity in this SAME tx; without this flag they would reset
        // lastActivityTime to now and make forceRecycle's inactivity check always fail.
        _recycling = true;
        address pf = _s.getProductFactory();
        if (pf != address(0)) {
            try IProductFactory(pf).delistAllProductsFor(_merchant) {} catch {}
        }
        address cf = _s.getC2CFactory();
        if (cf != address(0)) {
            for (uint256 round; round < 10; round++) {
                try IC2CFactory(cf).cancelAllOrdersFor(_merchant) returns (bool allDone) {
                    if (allDone) break;
                } catch { break; }
            }
        }
        _recycling = false;
        if (!_allBusinessSettled(_merchant)) revert ProductsActiveOrCooldown();
        MerchantDepositTemplate(depositAddr).forceRecycle();
        emit DepositRecycled(_merchant, depositAddr);
    }

    /**
     * @notice Continue recycling C2C orders for a merchant with >500 orders
     * @dev [M-03 fix]: Allows admin to continue canceling orders in batches when initial cleanup is insufficient
     * Caller: admin only
     * @param _merchant Target merchant address
     * @return allDone Whether all C2C orders have been canceled
     */
    function continueRecycleDeposit(address _merchant) external returns (bool allDone) {
        IPlatformSettings _s = IPlatformSettings(settingsAddr);
        if (!_s.isAdminOrCS(msg.sender)) revert NotAdminOrCS();
        address depositAddr = merchantDeposit[_merchant];
        if (depositAddr == address(0)) revert NoDepositContract();

        address cf = _s.getC2CFactory();
        if (cf == address(0)) return true;

        // Suppress activity refresh during the forced cancel sweep (see adminRecycleDeposit).
        _recycling = true;
        allDone = true;
        for (uint256 round; round < 10; round++) {
            try IC2CFactory(cf).cancelAllOrdersFor(_merchant) returns (bool done) {
                if (done) {
                    allDone = true;
                    break;
                }
                allDone = false;
            } catch {
                allDone = false;
                break;
            }
        }
        _recycling = false;
    }

    // ==================== Query Functions ====================

    /**
     * @notice Get deposit contract address for a merchant
     * @param merchant Merchant address
     * @return Deposit contract address (zero address if not created)
     */
    function getDeposit(address merchant) external view returns (address) {
        return merchantDeposit[merchant];
    }

    /**
     * @notice Check if a merchant has created a deposit contract
     * @param merchant Merchant address
     * @return Whether a deposit contract exists
     */
    function hasDeposit(address merchant) external view returns (bool) {
        return merchantDeposit[merchant] != address(0);
    }

    /**
     * @notice Get total count of created deposit contracts
     * @return Deposit contract count
     */
    function getDepositCount() external view returns (uint256) {
        return allDeposits.length;
    }

    /// @notice Get paginated list of all deposit contract addresses
    /// @param offset Start index
    /// @param limit Return count (max 100)
    /// @return Array of deposit contract addresses
    function getAllDeposits(uint256 offset, uint256 limit) external view returns (address[] memory) {
        if (limit > 100) limit = 100;
        uint256 total = allDeposits.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allDeposits[i];
        }
        return result;
    }

    // ==================== Internal Utilities ====================

    /**
     * @notice EIP-1167 minimal proxy clone
     * @dev Deploys a minimal proxy contract pointing to impl using CREATE opcode
     *           The proxy delegates all calls to impl but uses its own storage
     * @param impl Template contract address (logic contract)
     * @return instance Newly deployed clone contract address
     */
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
}
