// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PSSToken} from "../src/PSSToken.sol";

/// @dev Pair-token test fixture, installed at the assignment's pairedCurrency address.
contract PairFixture {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Test-only factory/trader. Settles negative deltas by balance change, takes positive deltas.
contract V4Participant is IUnlockCallback {
    IPoolManager internal immutable manager;

    struct Operation {
        PoolKey key;
        bool seed;
        ModifyLiquidityParams liquidity;
        SwapParams swapParams;
        bool shortPay;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deploy(bytes32 salt) external returns (PSSToken) {
        return new PSSToken{salt: salt}();
    }

    function move(PSSToken token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount));
    }

    function seed(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity) external returns (BalanceDelta) {
        Operation memory op;
        op.key = key;
        op.seed = true;
        op.liquidity = ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0));
        return abi.decode(manager.unlock(abi.encode(op)), (BalanceDelta));
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount, bool shortPay) external returns (BalanceDelta) {
        Operation memory op;
        op.key = key;
        op.swapParams =
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        op.shortPay = shortPay;
        return abi.decode(manager.unlock(abi.encode(op)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Operation memory op = abi.decode(data, (Operation));
        BalanceDelta delta;
        if (op.seed) (delta,) = manager.modifyLiquidity(op.key, op.liquidity, "");
        else delta = manager.swap(op.key, op.swapParams, "");
        _settle(op.key.currency0, delta.amount0(), op.shortPay);
        _settle(op.key.currency1, delta.amount1(), op.shortPay);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, bool shortPay) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount - (shortPay ? 1 : 0)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}

contract UniswapV4Test is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant PAIRED = address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint160 internal constant PROVENANCE_PRICE = 125270724187523965593206900;
    uint256 internal constant Q96 = 1 << 96;
    IPoolManager internal manager;
    V4Participant internal factory;
    V4Participant internal trader;

    function setUp() public {
        vm.chainId(1);
        // Construct in place, preserving PoolManager's original-address guard.
        vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = MANAGER.call("");
        require(built && runtime.length > 0);
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        vm.etch(PAIRED, address(new PairFixture()).code);
        factory = new V4Participant(manager);
        trader = new V4Participant(manager);
    }

    function test_SeedBuyAndSellWithPSSAsCurrency0() public {
        _exercise(true, false);
    }

    function test_SeedBuyAndSellWithPSSAsCurrency1() public {
        _exercise(false, false);
    }

    function test_UnderpaidSellRevertsCurrencyNotSettled() public {
        _exercise(true, true);
    }

    function _exercise(bool tokenFirst, bool shortPay) private {
        PSSToken token = _deployInOrder(tokenFirst);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, SUPPLY / 10);

        PoolKey memory key = PoolKey(
            Currency.wrap(tokenFirst ? address(token) : PAIRED),
            Currency.wrap(tokenFirst ? PAIRED : address(token)),
            3000,
            60,
            IHooks(address(0))
        );
        uint160 price = tokenFirst ? PROVENANCE_PRICE : uint160((1 << 192) / uint256(PROVENANCE_PRICE));
        int24 tick = manager.initialize(key, price);
        int24 floorTick = (tick / 60) * 60;
        if (tick < 0 && tick % 60 != 0) floorTick -= 60;
        // The initial position contains only PSS; the active price starts just outside it.
        int24 lower = tokenFirst ? floorTick + 60 : TickMath.minUsableTick(60);
        int24 upper = tokenFirst ? TickMath.maxUsableTick(60) : floorTick;
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 seedBudget = SUPPLY * 9 / 10;
        uint256 liquidity = tokenFirst
            ? FullMath.mulDiv(seedBudget, FullMath.mulDiv(a, b, Q96), b - a)
            : FullMath.mulDiv(seedBudget, Q96, b - a);
        assertLe(liquidity, type(uint128).max);
        uint256 required = tokenFirst
            ? SqrtPriceMath.getAmount0Delta(a, b, uint128(liquidity), true)
            : SqrtPriceMath.getAmount1Delta(a, b, uint128(liquidity), true);
        assertLe(required, seedBudget);
        assertGt(required, seedBudget * 9999 / 10_000);
        factory.seed(key, lower, upper, uint128(liquidity));
        assertEq(token.balanceOf(MANAGER), required);
        assertEq(PairFixture(PAIRED).balanceOf(MANAGER), 0);
        assertEq(token.balanceOf(address(token)), 0);
        factory.move(token, token.BURN_ADDRESS(), token.balanceOf(address(factory)));
        assertEq(token.balanceOf(address(factory)), 0);
        (,,, uint24 poolFee) = manager.getSlot0(key.toId());
        assertEq(poolFee, 3000);

        PairFixture(PAIRED).mint(address(trader), 1 ether);
        uint256 poolBefore = token.balanceOf(MANAGER);
        BalanceDelta buyDelta = trader.swap(key, !tokenFirst, -0.01 ether, false);
        int128 tokenDelta = tokenFirst ? buyDelta.amount0() : buyDelta.amount1();
        assertGt(tokenDelta, 0);
        uint256 gross = uint128(tokenDelta);
        uint256 fee = gross * 3 / 100;
        uint256 bought = token.balanceOf(address(trader));
        assertEq(bought, gross - fee);
        assertEq(token.balanceOf(MANAGER), poolBefore - gross);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());

        uint256 pairBefore = PairFixture(PAIRED).balanceOf(address(trader));
        uint256 dividendsBefore = token.claimableDividends(address(trader));
        assertGt(dividendsBefore, 0);
        if (shortPay) {
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
            trader.swap(key, tokenFirst, -int256(bought), true);
            assertEq(token.balanceOf(address(trader)), bought);
            assertEq(PairFixture(PAIRED).balanceOf(address(trader)), pairBefore);
            assertEq(token.balanceOf(address(token)), fee);
        }
        trader.swap(key, tokenFirst, -int256(bought), false);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(MANAGER), poolBefore - fee);
        assertEq(token.balanceOf(address(token)), fee);
        assertGt(PairFixture(PAIRED).balanceOf(address(trader)), pairBefore);
        assertEq(token.claimableDividends(address(trader)), dividendsBefore);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        vm.prank(address(trader));
        assertEq(token.claim(), dividendsBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _deployInOrder(bool tokenFirst) private returns (PSSToken) {
        bytes32 codeHash = keccak256(type(PSSToken).creationCode);
        for (uint256 i; i < 1000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
            if ((predicted < PAIRED) == tokenFirst) return factory.deploy(salt);
        }
        revert("test salt search exhausted");
    }
}
