// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PSSToken} from "../src/PSSToken.sol";

/// @dev Pair-token stand-in installed at the assignment's pairedCurrency address.
contract PairStub {
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

/// @dev A router that receives PoolManager output on a user's behalf and forwards it afterwards.
contract Forwarder {
    function forward(IERC20 token, address to) external {
        require(token.transfer(to, token.balanceOf(address(this))));
    }
}

/// @dev Factory, LP or trader. Settles what it owes by transfer or by burning ERC-6909 claims, and
/// collects what it is owed by take (to itself or a third party) or by minting ERC-6909 claims.
contract V4Actor is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable manager;

    enum Kind {
        Liquidity,
        Swap,
        Redeem
    }

    struct Op {
        Kind kind;
        PoolKey key;
        ModifyLiquidityParams liquidity;
        SwapParams swapParams;
        bool outAsClaims;
        bool inFromClaims;
        address takeTo;
        Currency redeemCurrency;
        uint256 redeemAmount;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deploy(bytes32 salt) external returns (PSSToken) {
        return new PSSToken{salt: salt}();
    }

    function move(IERC20 token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }

    function claim(PSSToken token) external returns (uint256) {
        return token.claim();
    }

    function modifyLiquidity(PoolKey memory key, int24 lower, int24 upper, int256 liquidityDelta)
        external
        returns (BalanceDelta)
    {
        Op memory op;
        op.kind = Kind.Liquidity;
        op.key = key;
        op.liquidity = ModifyLiquidityParams(lower, upper, liquidityDelta, bytes32(0));
        return abi.decode(manager.unlock(abi.encode(op)), (BalanceDelta));
    }

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        bool outAsClaims,
        bool inFromClaims,
        address takeTo
    ) external returns (BalanceDelta) {
        Op memory op;
        op.kind = Kind.Swap;
        op.key = key;
        op.swapParams = SwapParams(
            zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        op.outAsClaims = outAsClaims;
        op.inFromClaims = inFromClaims;
        op.takeTo = takeTo;
        return abi.decode(manager.unlock(abi.encode(op)), (BalanceDelta));
    }

    /// @dev Burn ERC-6909 claims and take the underlying tokens out of the manager.
    function redeem(Currency currency, uint256 amount) external {
        Op memory op;
        op.kind = Kind.Redeem;
        op.redeemCurrency = currency;
        op.redeemAmount = amount;
        manager.unlock(abi.encode(op));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Op memory op = abi.decode(data, (Op));
        if (op.kind == Kind.Redeem) {
            manager.burn(address(this), op.redeemCurrency.toId(), op.redeemAmount);
            manager.take(op.redeemCurrency, address(this), op.redeemAmount);
            return "";
        }
        BalanceDelta delta;
        if (op.kind == Kind.Liquidity) (delta,) = manager.modifyLiquidity(op.key, op.liquidity, "");
        else delta = manager.swap(op.key, op.swapParams, "");
        _settle(op, op.key.currency0, delta.amount0());
        _settle(op, op.key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Op memory op, Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));
            if (op.inFromClaims) {
                manager.burn(address(this), currency.toId(), amount);
            } else {
                manager.sync(currency);
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            uint256 amount = uint128(delta);
            if (op.outAsClaims) manager.mint(address(this), currency.toId(), amount);
            else manager.take(currency, op.takeTo == address(0) ? address(this) : op.takeTo, amount);
        }
    }
}

/// @notice Uniswap v4 paths beyond the plain buy and sell in test/UniswapV4.t.sol: exact-output buys,
/// output routed through an intermediary, liquidity withdrawn by the factory, ERC-6909 claim
/// redemption, and several traders interleaving before they claim.
contract UniswapV4EdgesTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant PAIRED = address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant USER = address(0x05E4);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint160 internal constant PROVENANCE_PRICE = 125270724187523965593206900;
    uint256 internal constant Q96 = 1 << 96;

    IPoolManager internal manager;
    V4Actor internal factory;
    V4Actor internal trader;
    V4Actor internal other;
    PSSToken internal token;
    PoolKey internal key;
    bool internal tokenFirst;
    int24 internal lower;
    int24 internal upper;
    uint128 internal liquidity;

    function setUp() public {
        vm.chainId(1);
        vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = MANAGER.call("");
        require(built && runtime.length > 0);
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        vm.etch(PAIRED, address(new PairStub()).code);
        factory = new V4Actor(manager);
        trader = new V4Actor(manager);
        other = new V4Actor(manager);
    }

    // ---------------------------------------------------------------------------------------
    // Exact-output buys: the pool delivers the gross, the trader receives the net
    // ---------------------------------------------------------------------------------------

    function test_ExactOutputBuyDeliversNetOfFeeWithPSSAsCurrency0() public {
        _launch(true);
        _exactOutputBuy(1000 ether);
    }

    function test_ExactOutputBuyDeliversNetOfFeeWithPSSAsCurrency1() public {
        _launch(false);
        _exactOutputBuy(1000 ether);
    }

    function _exactOutputBuy(uint256 wanted) private {
        uint256 poolBefore = token.balanceOf(MANAGER);
        BalanceDelta delta = trader.swap(key, !tokenFirst, int256(wanted), false, false, address(0));
        int128 tokenDelta = tokenFirst ? delta.amount0() : delta.amount1();
        assertEq(uint256(uint128(tokenDelta)), wanted, "the pool did not deliver the exact output");
        uint256 fee = wanted * 3 / 100;
        assertEq(token.balanceOf(address(trader)), wanted - fee, "the trader did not receive the net amount");
        assertEq(token.balanceOf(MANAGER), poolBefore - wanted);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.totalFeesCollected(), fee);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        // The trader can sell the whole net receipt back; settlement balances exactly.
        trader.swap(key, tokenFirst, -int256(wanted - fee), false, false, address(0));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(MANAGER), poolBefore - fee);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Output taken to a third party (router pattern)
    // ---------------------------------------------------------------------------------------

    function test_OutputTakenToRouterIsTaxedOnceAndRouterKeepsTheDividend() public {
        _launch(true);
        Forwarder router = new Forwarder();
        BalanceDelta delta = trader.swap(key, false, -0.01 ether, false, false, address(router));
        uint256 gross = uint128(delta.amount0());
        uint256 fee = gross * 3 / 100;
        assertEq(token.balanceOf(address(router)), gross - fee);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.totalFeesCollected(), fee);
        uint256 routerOwed = token.claimableDividends(address(router));
        assertGt(routerOwed, 0);
        router.forward(token, USER);
        assertEq(token.balanceOf(USER), gross - fee, "forwarding must not be taxed");
        assertEq(token.totalFeesCollected(), fee, "forwarding must not collect a second fee");
        assertEq(token.claimableDividends(USER), 0);
        assertEq(token.claimableDividends(address(router)), routerOwed);
        // The user can still sell what arrived, untaxed, and the pool settles.
        vm.prank(USER);
        token.transfer(address(trader), gross - fee);
        trader.swap(key, true, -int256(gross - fee), false, false, address(0));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Liquidity withdrawn by the factory: a manager outflow, so it is taxed like any other
    // ---------------------------------------------------------------------------------------

    /// @dev The README documents this: the token cannot tell a withdrawal from a buy. Any PSS the
    /// factory (or whoever holds the position) pulls out of the pool arrives net of 3%, and the fee is
    /// shared by the holders. Settlement still balances because take() does not check receipt.
    function test_LiquidityWithdrawalByFactoryIsTaxedAsAManagerOutflow() public {
        _launch(true);
        uint256 poolBefore = token.balanceOf(MANAGER);
        uint256 claimantOwedBefore = token.claimableDividends(CLAIMANT);
        int256 remove = -int256(uint256(liquidity) / 10);
        BalanceDelta delta = factory.modifyLiquidity(key, lower, upper, remove);
        uint256 gross = uint128(delta.amount0());
        assertGt(gross, 0);
        assertEq(delta.amount1(), 0, "a single-sided PSS position must not pay out the pair currency");
        uint256 fee = gross * 3 / 100;
        assertEq(token.balanceOf(address(factory)), gross - fee, "the withdrawal was not taxed at 3%");
        assertEq(token.balanceOf(MANAGER), poolBefore - gross);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.totalFeesCollected(), fee);
        assertGt(token.claimableDividends(CLAIMANT), claimantOwedBefore);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    // ---------------------------------------------------------------------------------------
    // ERC-6909 claims: the fee attaches to the token leaving the manager, not to the swap
    // ---------------------------------------------------------------------------------------

    /// @dev A trader who took swap output as ERC-6909 claims holds no PSS and pays no fee until the
    /// claims are redeemed; redemption is a manager outflow and pays the full 3% on the amount taken.
    /// The untaxed in-manager round trip this permits is reported in .imd-findings.json rather than
    /// asserted here.
    function test_RedeemingClaimsPaysTheFeeOnTheAmountTaken() public {
        _launch(true);
        uint256 poolBefore = token.balanceOf(MANAGER);
        BalanceDelta delta = trader.swap(key, false, -0.01 ether, true, false, address(0));
        uint256 gross = uint128(delta.amount0());
        uint256 claims = IERC6909Claims(MANAGER).balanceOf(address(trader), key.currency0.toId());
        assertEq(claims, gross, "claims must equal the swap output");
        assertEq(token.balanceOf(address(trader)), 0, "no PSS leaves the manager when output is minted as claims");
        assertEq(token.balanceOf(MANAGER), poolBefore);
        assertEq(token.claimableDividends(address(trader)), 0, "claim holders are not PSS holders");

        uint256 half = gross / 2;
        trader.redeem(key.currency0, half);
        uint256 fee = half * 3 / 100;
        assertEq(token.balanceOf(address(trader)), half - fee, "redemption must pay the 3% buy fee");
        assertEq(token.balanceOf(MANAGER), poolBefore - half);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.totalFeesCollected(), fee);
        assertEq(IERC6909Claims(MANAGER).balanceOf(address(trader), key.currency0.toId()), gross - half);
        assertGt(token.claimableDividends(address(trader)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    // ---------------------------------------------------------------------------------------
    // Several traders interleaving, then everyone claims
    // ---------------------------------------------------------------------------------------

    function test_InterleavedTradersAccrueExactlyTheFeesAndCanAllClaim() public {
        _launch(true);
        PairStub(PAIRED).mint(address(other), 1 ether);
        uint256 fees;
        uint256 poolBefore = token.balanceOf(MANAGER);
        fees += _buyAndFee(trader, 0.01 ether);
        fees += _buyAndFee(other, 0.02 ether);
        uint256 traderHalf = token.balanceOf(address(trader)) / 2;
        trader.swap(key, true, -int256(traderHalf), false, false, address(0));
        fees += _buyAndFee(other, 0.005 ether);
        fees += _buyAndFee(trader, 0.001 ether);
        assertEq(token.totalFeesCollected(), fees);
        assertEq(token.balanceOf(address(token)), fees);
        uint256 owed = token.claimableDividends(address(trader)) + token.claimableDividends(address(other))
            + token.claimableDividends(CLAIMANT);
        assertLe(owed, fees);
        assertGe(owed + 4 + 3, fees, "more than rounding went missing across four distributions");
        uint256 claimed = trader.claim(token) + other.claim(token);
        vm.prank(CLAIMANT);
        claimed += token.claim();
        assertEq(claimed, owed);
        assertEq(token.balanceOf(address(token)), fees - claimed);
        assertEq(token.totalDividendsClaimed(), claimed);
        // Everyone can exit through the pool with what they hold, dividends included.
        trader.swap(key, true, -int256(token.balanceOf(address(trader))), false, false, address(0));
        other.swap(key, true, -int256(token.balanceOf(address(other))), false, false, address(0));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(other)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(
            token.balanceOf(MANAGER) + token.balanceOf(address(token)) + token.balanceOf(CLAIMANT)
                + token.balanceOf(token.BURN_ADDRESS()),
            SUPPLY
        );
        assertLt(token.balanceOf(MANAGER), poolBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _buyAndFee(V4Actor who, uint256 pairIn) private returns (uint256 fee) {
        uint256 before = token.balanceOf(address(who));
        BalanceDelta delta = who.swap(key, false, -int256(pairIn), false, false, address(0));
        uint256 gross = uint128(delta.amount0());
        fee = gross * 3 / 100;
        assertEq(token.balanceOf(address(who)), before + gross - fee);
    }

    // ---------------------------------------------------------------------------------------
    // Launch fixture: deploy in the requested currency order, seed single-sided, fund the trader
    // ---------------------------------------------------------------------------------------

    function _launch(bool tokenFirst_) private {
        tokenFirst = tokenFirst_;
        token = _deployInOrder(tokenFirst_);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, SUPPLY / 10);

        key = PoolKey(
            Currency.wrap(tokenFirst_ ? address(token) : PAIRED),
            Currency.wrap(tokenFirst_ ? PAIRED : address(token)),
            3000,
            60,
            IHooks(address(0))
        );
        uint160 price = tokenFirst_ ? PROVENANCE_PRICE : uint160((1 << 192) / uint256(PROVENANCE_PRICE));
        int24 tick = manager.initialize(key, price);
        int24 floorTick = (tick / 60) * 60;
        if (tick < 0 && tick % 60 != 0) floorTick -= 60;
        lower = tokenFirst_ ? floorTick + 60 : TickMath.minUsableTick(60);
        upper = tokenFirst_ ? TickMath.maxUsableTick(60) : floorTick;
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 seedBudget = SUPPLY * 9 / 10;
        uint256 liq = tokenFirst_
            ? FullMath.mulDiv(seedBudget, FullMath.mulDiv(a, b, Q96), b - a)
            : FullMath.mulDiv(seedBudget, Q96, b - a);
        require(liq <= type(uint128).max);
        liquidity = uint128(liq);
        uint256 required = tokenFirst_
            ? SqrtPriceMath.getAmount0Delta(a, b, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(a, b, liquidity, true);
        factory.modifyLiquidity(key, lower, upper, int256(liq));
        assertEq(token.balanceOf(MANAGER), required, "the seed moved something other than the exact amount");
        assertEq(token.balanceOf(address(token)), 0, "the seed was taxed");
        factory.move(token, token.BURN_ADDRESS(), token.balanceOf(address(factory)));
        assertEq(token.balanceOf(address(factory)), 0);
        (,,, uint24 poolFee) = manager.getSlot0(key.toId());
        assertEq(poolFee, 3000);
        PairStub(PAIRED).mint(address(trader), 1 ether);
    }

    function _deployInOrder(bool tokenFirst_) private returns (PSSToken) {
        bytes32 codeHash = keccak256(type(PSSToken).creationCode);
        for (uint256 i; i < 1000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
            if ((predicted < PAIRED) == tokenFirst_) return factory.deploy(salt);
        }
        revert("test salt search exhausted");
    }
}
