// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Pepelstiltskin
/// @notice Fixed-supply PSS with a buy-only fee paid to holders as claimable PSS.
/// @dev The launch factory receives the entire supply and handles all launch allocations.
contract PSSToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BUY_FEE_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAGNITUDE = 2 ** 128;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public magnifiedDividendPerShare;
    uint256 public queuedDividends;
    uint256 public totalFeesCollected;
    uint256 public totalDividendsClaimed;

    mapping(address account => uint256 index) private _paidIndex;
    mapping(address account => uint256 scaledAmount) private _accrued;

    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);
    event DividendClaimed(address indexed account, uint256 amount);

    constructor() ERC20("Pepelstiltskin", "PSS") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Exclusions are permanent. The zero address cannot receive ERC-20 transfers.
    function isExcludedFromDividends(address account) public view returns (bool) {
        return account == POOL_MANAGER || account == address(this) || account == BURN_ADDRESS || account == address(0);
    }

    function eligibleSupply() public view returns (uint256) {
        return totalSupply() - balanceOf(POOL_MANAGER) - balanceOf(address(this)) - balanceOf(BURN_ADDRESS);
    }

    /// @notice Whole PSS minor units currently claimable, including earnings before a sale.
    function claimableDividends(address account) public view returns (uint256) {
        if (isExcludedFromDividends(account)) return 0;
        return (_accrued[account] + balanceOf(account) * (magnifiedDividendPerShare - _paidIndex[account])) / MAGNITUDE;
    }

    /// @notice Claim only the caller's dividends. An empty or repeated claim returns zero.
    function claim() external returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @notice Anyone may trigger a payout to the holder; the caller cannot redirect it.
    /// @dev Supports contract holders that cannot call claim() themselves.
    function claimFor(address account) external returns (uint256 amount) {
        return _claim(account);
    }

    /// @dev No external calls or receiver callbacks. Fractional entitlements survive claims.
    function _claim(address account) private returns (uint256 amount) {
        _accrue(account);
        amount = _accrued[account] / MAGNITUDE;
        if (amount == 0) return 0;

        _accrued[account] %= MAGNITUDE;
        totalDividendsClaimed += amount;
        // The holder was checkpointed above: claimed tokens earn only future dividends.
        super._update(address(this), account, amount);
        emit DividendClaimed(account, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        _accrue(from);
        _accrue(to);

        // Transfers TO the manager, including a manager self-transfer, are always untaxed.
        if (from == POOL_MANAGER && to != POOL_MANAGER) {
            uint256 available = balanceOf(from);
            if (available < amount) revert ERC20InsufficientBalance(from, available, amount);
            uint256 fee = amount * BUY_FEE_BPS / BPS_DENOMINATOR;
            if (fee != 0) {
                super._update(from, address(this), fee);
                totalFeesCollected += fee;
                _distribute(fee);
                _accrue(to);
                super._update(from, to, amount - fee);
                return;
            }
        }

        super._update(from, to, amount);
    }

    /// @dev Checkpoint the OLD balance before every balance change. No holder enumeration.
    function _accrue(address account) private {
        if (isExcludedFromDividends(account)) return;
        uint256 index = magnifiedDividendPerShare;
        uint256 previous = _paidIndex[account];
        if (index == previous) return;
        _accrued[account] += balanceOf(account) * (index - previous);
        _paidIndex[account] = index;
    }

    /// @dev Distribute before the net buy arrives; only pre-buy balances share in this fee.
    /// Fees with no eligible holder wait for the next positive-fee buy with eligible supply.
    /// Global division dust stays in reserve; it is never allocated a second time.
    function _distribute(uint256 fee) private {
        uint256 amount = queuedDividends + fee;
        uint256 supply = eligibleSupply();
        if (supply == 0) {
            queuedDividends = amount;
            return;
        }
        queuedDividends = 0;
        magnifiedDividendPerShare += amount * MAGNITUDE / supply;
        emit DividendsDistributed(amount, supply);
    }
}
