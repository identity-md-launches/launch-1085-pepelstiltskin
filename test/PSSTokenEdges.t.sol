// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PSSToken} from "../src/PSSToken.sol";

/// @dev A holder that is a contract with no receive hook: claim() must work for it without callbacks.
contract PlainHolder {
    function claimFrom(PSSToken token) external returns (uint256) {
        return token.claim();
    }

    function send(PSSToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }
}

/// @dev A router that receives PoolManager output and forwards it to the end user in a later call.
contract ForwardingRouter {
    function forward(PSSToken token, address to) external {
        require(token.transfer(to, token.balanceOf(address(this))));
    }
}

/// @notice Edge cases and failure paths on top of test/PSSToken.t.sol: inputs the implementation
/// did not obviously consider, repeated calls, callers that are not who the code assumed.
contract PSSTokenEdgesTest is Test {
    PSSToken internal token;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant STRANGER = address(0x5712A);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant MAGNITUDE = 2 ** 128;

    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new PSSToken();
    }

    // ---------------------------------------------------------------------------------------
    // Fixed parameters and absence of privileged surface
    // ---------------------------------------------------------------------------------------

    function test_ConstantsMatchTheBriefAndExclusionsAreFixed() public view {
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.INITIAL_SUPPLY(), token.totalSupply());
        assertEq(token.BUY_FEE_BPS(), 300);
        assertEq(token.BPS_DENOMINATOR(), 10_000);
        assertEq(token.MAGNITUDE(), MAGNITUDE);
        assertEq(token.POOL_MANAGER(), MANAGER);
        assertEq(token.BURN_ADDRESS(), DEAD);
        assertTrue(token.isExcludedFromDividends(MANAGER));
        assertTrue(token.isExcludedFromDividends(address(token)));
        assertTrue(token.isExcludedFromDividends(DEAD));
        assertTrue(token.isExcludedFromDividends(address(0)));
        assertFalse(token.isExcludedFromDividends(address(this)));
        assertFalse(token.isExcludedFromDividends(ALICE));
        assertFalse(token.isExcludedFromDividends(STRANGER));
    }

    function test_RejectsEtherAndUnknownCalldata() public {
        vm.deal(address(this), 1 ether);
        (bool paid,) = address(token).call{value: 1}("");
        assertFalse(paid, "token must not accept ether");
        (bool fallbackHit,) = address(token).call(hex"deadbeef");
        assertFalse(fallbackHit, "token must not have a fallback");
        (bool emptyHit,) = address(token).call("");
        assertFalse(emptyHit, "token must not have a receive function");
        assertEq(address(token).balance, 0);
    }

    /// @dev A second, disjoint list of privileged selectors. None may move or freeze a holder, whether
    /// the caller is the deployer or a stranger, and the holder must still be able to transfer after.
    function test_NoPrivilegedSelectorMovesOrFreezesAHolder() public {
        token.transfer(ALICE, 1000 ether);
        string[14] memory signatures = [
            "freeze(address)",
            "freezeAccount(address)",
            "blocklist(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "renounceOwnership()",
            "setDividendExclusion(address,bool)",
            "rescueTokens(address,uint256)",
            "withdraw()",
            "setPool(address)",
            "distribute()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(STRANGER);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, address(this), 1));
        assertFalse(moved, "deployer moved a holder's balance without allowance");
        assertEq(token.balanceOf(ALICE), 1000 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 500 ether));
        assertEq(token.balanceOf(BOB), 500 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Allowance edges on taxed transfers
    // ---------------------------------------------------------------------------------------

    function test_RevertWhen_ApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// @dev The allowance is spent against the gross amount, so an allowance that only covers the
    /// net receipt (97%) is not enough to pull a buy out of the manager.
    function test_RevertWhen_BuyAllowanceCoversOnlyTheNetAmount() public {
        token.transfer(MANAGER, 1000 ether);
        vm.prank(MANAGER);
        token.approve(BOB, 970 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 970 ether, 1000 ether)
        );
        vm.prank(BOB);
        token.transferFrom(MANAGER, ALICE, 1000 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.allowance(MANAGER, BOB), 970 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BuyViaAllowanceNeedsGrossAllowance(uint256 allowance, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY / 2);
        allowance = bound(allowance, 0, SUPPLY);
        token.transfer(MANAGER, SUPPLY / 2);
        vm.prank(MANAGER);
        token.approve(BOB, allowance);
        if (allowance < amount) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowance, amount)
            );
            vm.prank(BOB);
            token.transferFrom(MANAGER, ALICE, amount);
            assertEq(token.balanceOf(ALICE), 0);
            return;
        }
        vm.prank(BOB);
        assertTrue(token.transferFrom(MANAGER, ALICE, amount));
        uint256 fee = amount * 300 / 10_000;
        assertEq(token.balanceOf(ALICE), amount - fee);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.allowance(MANAGER, BOB), allowance == type(uint256).max ? allowance : allowance - amount);
    }

    // ---------------------------------------------------------------------------------------
    // Fee routing: who pays, who does not, for any amount and any ordinary pair of wallets
    // ---------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_WalletTransfersAndSellsNeverPayAFee(address from, address to, uint256 amount) public {
        vm.assume(from != address(0) && to != address(0));
        vm.assume(from != MANAGER && to != MANAGER);
        vm.assume(from != address(token) && to != address(token));
        vm.assume(from != address(this) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        token.transfer(from, amount);
        assertEq(token.balanceOf(from), amount);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from != to) {
            assertEq(token.balanceOf(from), 0);
            assertEq(token.balanceOf(to), toBefore + amount);
        } else {
            assertEq(token.balanceOf(to), amount);
        }
        uint256 sell = token.balanceOf(to);
        vm.prank(to);
        assertTrue(token.transfer(MANAGER, sell));
        assertEq(token.balanceOf(MANAGER), sell);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.magnifiedDividendPerShare(), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The manager's entire balance can leave in one buy; the rule has no minimum pool reserve.
    function test_BuyOfEntireManagerBalanceLeavesManagerEmpty() public {
        token.transfer(MANAGER, SUPPLY);
        vm.prank(MANAGER);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(MANAGER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY - SUPPLY * 3 / 100);
        assertEq(token.balanceOf(address(token)), SUPPLY * 3 / 100);
        // Alice is the only eligible holder, so the whole fee is hers (minus global dust).
        assertApproxEqAbs(token.claimableDividends(ALICE), SUPPLY * 3 / 100, 1);
        vm.prank(ALICE);
        token.claim();
        assertLe(token.balanceOf(address(token)), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Per-transfer rounding: splitting a buy into sub-34-wei pieces pays nothing. This is dust-level
    /// and gas makes it irrelevant, but it is the exact boundary of the fee rule, so pin it.
    function test_FeeBoundaryAtThirtyFourMinorUnits() public {
        token.transfer(MANAGER, 1000);
        token.transfer(ALICE, 1);
        for (uint256 i; i < 3; ++i) {
            vm.prank(MANAGER);
            token.transfer(BOB, 33);
        }
        assertEq(token.balanceOf(BOB), 99);
        assertEq(token.totalFeesCollected(), 0);
        vm.prank(MANAGER);
        token.transfer(BOB, 34);
        assertEq(token.totalFeesCollected(), 1);
        assertEq(token.balanceOf(BOB), 99 + 33);
        vm.prank(MANAGER);
        token.transfer(BOB, 99);
        assertEq(token.totalFeesCollected(), 1 + 2);
        assertEq(token.balanceOf(BOB), 132 + 97);
    }

    // ---------------------------------------------------------------------------------------
    // Dividend accounting edges
    // ---------------------------------------------------------------------------------------

    function test_DividendsDistributedEventReportsPostTransferEligibleSupply() public {
        token.transfer(ALICE, 19_400 ether);
        token.transfer(BOB, 9700 ether);
        token.transfer(MANAGER, SUPPLY - 29_100 ether);
        // Eligible supply at distribution time includes Carol's net receipt (9700) but not the fee.
        vm.expectEmit(false, false, false, true, address(token));
        emit DividendsDistributed(300 ether, 38_800 ether);
        vm.prank(MANAGER);
        token.transfer(CAROL, 10_000 ether);
        assertEq(token.magnifiedDividendPerShare(), 300 ether * MAGNITUDE / 38_800 ether);
    }

    /// @dev A buy routed to the token contract itself: the fee is distributed, the net is a donation
    /// that nobody can claim, and the reserve still covers every entitlement.
    function test_BuyRoutedToTokenContractDistributesOnlyTheFee() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        vm.expectEmit(false, false, false, true, address(token));
        emit DividendsDistributed(30 ether, 1000 ether);
        vm.prank(MANAGER);
        token.transfer(address(token), 1000 ether);
        assertEq(token.balanceOf(address(token)), 1000 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
        assertEq(token.eligibleSupply(), 1000 ether);
        assertApproxEqAbs(token.claimableDividends(ALICE), 30 ether, 1);
        assertEq(token.claimableDividends(address(token)), 0);
        vm.prank(ALICE);
        uint256 claimed = token.claim();
        assertEq(token.balanceOf(address(token)), 1000 ether - claimed);
        assertGe(token.balanceOf(address(token)), 970 ether);
    }

    /// @dev Queued fees survive an untaxed (sub-34-wei) buy that creates the first eligible holder, and
    /// are flushed by the next taxed buy even when that buy's recipient is excluded.
    function test_QueuedFeesFlushOnNextTaxedBuyEvenToExcludedRecipient() public {
        token.transfer(MANAGER, SUPPLY);
        vm.prank(MANAGER);
        token.transfer(DEAD, 1000);
        assertEq(token.queuedDividends(), 30);
        vm.prank(MANAGER);
        token.transfer(ALICE, 33);
        assertEq(token.queuedDividends(), 30, "an untaxed buy must not flush the queue");
        assertEq(token.magnifiedDividendPerShare(), 0);
        assertEq(token.eligibleSupply(), 33);
        vm.expectEmit(false, false, false, true, address(token));
        emit DividendsDistributed(33, 33);
        vm.prank(MANAGER);
        token.transfer(DEAD, 100);
        assertEq(token.queuedDividends(), 0);
        assertEq(token.claimableDividends(ALICE), 33);
        vm.prank(ALICE);
        assertEq(token.claim(), 33);
        assertEq(token.balanceOf(ALICE), 66);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev Many holders of uneven size: everyone claims, nobody is overpaid, and what remains in the
    /// contract is bounded by one minor unit per holder plus one of global dust.
    function test_ManyHoldersClaimEverythingButDust() public {
        uint256 holders = 40;
        uint256 eligible;
        for (uint256 i; i < holders; ++i) {
            uint256 amount = (i + 1) * 123_456_789 + 7;
            token.transfer(_holder(i), amount);
            eligible += amount;
        }
        token.transfer(MANAGER, SUPPLY - eligible);
        uint256 buy = 123_456_789_012_345_678_901;
        uint256 fee = buy * 3 / 100;
        vm.prank(MANAGER);
        token.transfer(DEAD, buy);
        assertEq(token.eligibleSupply(), eligible);
        uint256 sumClaimable;
        for (uint256 i; i < holders; ++i) {
            uint256 owed = token.claimableDividends(_holder(i));
            uint256 exact = fee * token.balanceOf(_holder(i)) / eligible;
            assertLe(owed, exact, "a holder is owed more than its pro rata share");
            assertGe(owed + 1, exact, "a holder is owed more than one unit less than its share");
            sumClaimable += owed;
        }
        assertLe(sumClaimable, fee);
        assertGe(sumClaimable + holders + 1, fee);
        uint256 claimed;
        for (uint256 i; i < holders; ++i) {
            address holder = _holder(i);
            uint256 before = token.balanceOf(holder);
            uint256 owed = token.claimableDividends(holder);
            vm.prank(holder);
            uint256 got = token.claim();
            assertEq(got, owed);
            assertEq(token.balanceOf(holder), before + got);
            assertEq(token.claimableDividends(holder), 0);
            claimed += got;
        }
        assertEq(claimed, sumClaimable);
        assertEq(token.totalDividendsClaimed(), claimed);
        assertEq(token.balanceOf(address(token)), fee - claimed);
        assertLe(fee - claimed, holders + 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Claimed dividends are ordinary PSS: they can be sold untaxed and, once bought back from the
    /// manager, pay the fee again like any other buy.
    function test_ClaimedTokensCanBeSoldUntaxedAndBoughtBackTaxed() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(BOB, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 2000 ether);
        vm.prank(MANAGER);
        token.transfer(DEAD, 1000 ether); // 30 PSS fee, 15 each
        vm.prank(ALICE);
        uint256 claimed = token.claim();
        assertApproxEqAbs(claimed, 15 ether, 1);
        uint256 managerBefore = token.balanceOf(MANAGER);
        uint256 feesBefore = token.totalFeesCollected();
        uint256 aliceBalance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.transfer(MANAGER, aliceBalance);
        assertEq(token.balanceOf(MANAGER), managerBefore + 1000 ether + claimed);
        assertEq(token.totalFeesCollected(), feesBefore, "a sell of claimed tokens must not be taxed");
        assertEq(token.claimableDividends(ALICE), 0);
        // Bob is now the only eligible holder; Alice's buy-back pays a fee that Bob and Alice share.
        vm.prank(MANAGER);
        token.transfer(ALICE, 1000 ether);
        assertEq(token.totalFeesCollected(), feesBefore + 30 ether);
        assertEq(token.balanceOf(ALICE), 970 ether);
        uint256 eligible = 1970 ether;
        assertApproxEqAbs(token.claimableDividends(ALICE), 30 ether * 970 ether / eligible, 1);
        assertApproxEqAbs(token.claimableDividends(BOB), 15 ether + 30 ether * 1000 ether / eligible, 2);
    }

    /// @dev A holder who exits earns nothing from fees paid while away and resumes earning on return.
    function test_HolderWhoExitsEarnsNothingWhileAwayAndResumesOnReturn() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(BOB, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 2000 ether);
        vm.prank(ALICE);
        token.transfer(MANAGER, 1000 ether);
        vm.prank(MANAGER);
        token.transfer(DEAD, 1000 ether); // fee 30, Bob alone eligible
        assertEq(token.claimableDividends(ALICE), 0);
        assertApproxEqAbs(token.claimableDividends(BOB), 30 ether, 1);
        vm.prank(BOB);
        token.transfer(ALICE, 1000 ether); // Alice returns with Bob's tokens, Bob keeps his dividends
        assertEq(token.claimableDividends(ALICE), 0);
        assertApproxEqAbs(token.claimableDividends(BOB), 30 ether, 1);
        vm.prank(MANAGER);
        token.transfer(DEAD, 1000 ether); // fee 30, Alice alone eligible now
        assertApproxEqAbs(token.claimableDividends(ALICE), 30 ether, 1);
        assertApproxEqAbs(token.claimableDividends(BOB), 30 ether, 1);
        vm.prank(ALICE);
        assertApproxEqAbs(token.claim(), 30 ether, 1);
        vm.prank(BOB);
        assertApproxEqAbs(token.claim(), 30 ether, 1);
        assertLe(token.balanceOf(address(token)), 2);
    }

    /// @dev Integrator hazard the README documents: an intermediary that briefly holds manager output
    /// earns the dividend of that buy; forwarding the tokens does not forward the entitlement.
    function test_IntermediaryKeepsDividendsEarnedWhileHolding() public {
        ForwardingRouter router = new ForwardingRouter();
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        vm.prank(MANAGER);
        token.transfer(address(router), 1000 ether);
        assertEq(token.balanceOf(address(router)), 970 ether);
        uint256 routerOwed = token.claimableDividends(address(router));
        uint256 fee = 30 ether;
        assertApproxEqAbs(routerOwed, fee * 970 ether / 1970 ether, 1);
        router.forward(token, BOB);
        assertEq(token.balanceOf(BOB), 970 ether);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.claimableDividends(BOB), 0, "forwarded tokens must not carry history");
        assertEq(token.claimableDividends(address(router)), routerOwed);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    /// @dev Contract holders claim like anyone else; the token makes no callback that could revert.
    function test_ContractHolderClaimsWithoutCallbacks() public {
        PlainHolder holder = new PlainHolder();
        token.transfer(address(holder), 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        vm.prank(MANAGER);
        token.transfer(DEAD, 1000 ether);
        uint256 owed = token.claimableDividends(address(holder));
        assertApproxEqAbs(owed, 30 ether, 1);
        assertEq(holder.claimFrom(token), owed);
        assertEq(token.balanceOf(address(holder)), 1000 ether + owed);
        assertEq(holder.claimFrom(token), 0);
        holder.send(token, MANAGER, 1000 ether + owed);
        assertEq(token.balanceOf(address(holder)), 0);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    /// @dev claimableDividends must equal what claim() pays, before and after any intervening transfers,
    /// including after a self-transfer and after a zero-value transfer that re-checkpoints the account.
    function test_ViewMatchesClaimAfterCheckpoints() public {
        token.transfer(ALICE, 777 ether);
        token.transfer(BOB, 333 ether);
        token.transfer(MANAGER, SUPPLY - 1110 ether);
        vm.prank(MANAGER);
        token.transfer(CAROL, 12_345 ether);
        uint256 owed = token.claimableDividends(ALICE);
        vm.startPrank(ALICE);
        token.transfer(ALICE, 777 ether);
        token.transfer(BOB, 0);
        token.approve(BOB, 1);
        assertEq(token.claimableDividends(ALICE), owed);
        assertEq(token.claim(), owed);
        vm.stopPrank();
        assertEq(token.claimableDividends(ALICE), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Property tests over the arithmetic
    // ---------------------------------------------------------------------------------------

    /// @dev Three holders of arbitrary size and a buy of arbitrary size to an excluded recipient: each
    /// entitlement is its pro rata share rounded down by at most one unit, and the sum never exceeds
    /// the fee. After everyone claims, the reserve holds at most three units of dust plus one global.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ProRataSplitWithinOneUnit(uint256 a, uint256 b, uint256 c, uint256 buy) public {
        a = bound(a, 1, 100_000_000 ether);
        b = bound(b, 1, 100_000_000 ether);
        c = bound(c, 1, 100_000_000 ether);
        buy = bound(buy, 34, 600_000_000 ether);
        token.transfer(ALICE, a);
        token.transfer(BOB, b);
        token.transfer(CAROL, c);
        token.transfer(MANAGER, SUPPLY - a - b - c);
        vm.prank(MANAGER);
        token.transfer(DEAD, buy);
        uint256 fee = buy * 300 / 10_000;
        uint256 eligible = a + b + c;
        assertEq(token.eligibleSupply(), eligible);
        assertEq(token.balanceOf(address(token)), fee);
        address[3] memory who = [ALICE, BOB, CAROL];
        uint256[3] memory bal = [a, b, c];
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 owed = token.claimableDividends(who[i]);
            uint256 exact = fee * bal[i] / eligible;
            assertLe(owed, exact);
            assertGe(owed + 1, exact);
            sum += owed;
        }
        assertLe(sum, fee);
        assertGe(sum + 4, fee);
        uint256 claimed;
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            claimed += token.claim();
        }
        assertEq(claimed, sum);
        assertEq(token.balanceOf(address(token)), fee - claimed);
        assertLe(fee - claimed, 4);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A pseudo-random sequence of buys, sells, moves and claims among three holders never pays
    /// out more than was collected, and what is lost to rounding is bounded by the number of
    /// distributions plus the number of holders.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_RepeatedBuysAndClaimsNeverOverpay(uint256 seed, uint8 stepsRaw) public {
        uint256 steps = bound(stepsRaw, 1, 40);
        address[3] memory who = [ALICE, BOB, CAROL];
        token.transfer(MANAGER, SUPPLY);
        uint256 distributions;
        uint256 claimed;
        for (uint256 s; s < steps; ++s) {
            seed = uint256(keccak256(abi.encode(seed, s)));
            address actor = who[seed % 3];
            uint256 action = (seed >> 8) % 4;
            uint256 amount = (seed >> 16) % 1_000_000 ether;
            if (action == 0) {
                amount = bound(amount, 0, token.balanceOf(MANAGER));
                uint256 fee = amount * 300 / 10_000;
                vm.prank(MANAGER);
                token.transfer(actor, amount);
                if (fee != 0 && token.eligibleSupply() != 0) ++distributions;
            } else if (action == 1) {
                amount = bound(amount, 0, token.balanceOf(actor));
                vm.prank(actor);
                token.transfer(MANAGER, amount);
            } else if (action == 2) {
                amount = bound(amount, 0, token.balanceOf(actor));
                vm.prank(actor);
                token.transfer(who[(seed >> 4) % 3], amount);
            } else {
                uint256 owed = token.claimableDividends(actor);
                vm.prank(actor);
                uint256 got = token.claim();
                assertEq(got, owed);
                claimed += got;
            }
            uint256 owedNow;
            for (uint256 i; i < 3; ++i) {
                owedNow += token.claimableDividends(who[i]);
            }
            uint256 reserve = token.balanceOf(address(token));
            assertLe(owedNow + token.queuedDividends(), reserve, "reserve does not cover entitlements");
            assertEq(reserve + claimed, token.totalFeesCollected(), "fees, reserve and claims disagree");
            uint256 distributed = token.totalFeesCollected() - token.queuedDividends();
            assertLe(claimed + owedNow, distributed, "more was allocated than distributed");
            assertLe(distributed - claimed - owedNow, distributions + 3, "rounding lost more than expected");
        }
        assertEq(token.totalDividendsClaimed(), claimed);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _holder(uint256 i) private pure returns (address) {
        return address(uint160(0x1000 + i));
    }
}
