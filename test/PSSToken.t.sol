// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PSSToken} from "../src/PSSToken.sol";

contract PSSTokenTest is Test {
    PSSToken internal token;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DISTRIBUTOR = address(0xD157);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new PSSToken();
    }

    function test_ConstructorMintsEntireManifestSupplyOnlyToDeployer() public view {
        assertEq(token.name(), "Pepelstiltskin");
        assertEq(token.symbol(), "PSS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(MANAGER), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.BUY_FEE_BPS(), 300);
        assertEq(token.eligibleSupply(), SUPPLY);
    }

    function test_FactoryAllocationAndDistributorClaimArriveWhole() public {
        token.transfer(DISTRIBUTOR, SUPPLY / 10);
        token.transfer(MANAGER, SUPPLY * 9 / 10);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(MANAGER), 900_000_000 ether);
        assertEq(token.balanceOf(DISTRIBUTOR), 100_000_000 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, SUPPLY / 10);
        assertEq(token.balanceOf(ALICE), SUPPLY / 10);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.totalFeesCollected(), 0);
    }

    function test_BuySplitsFeeAndEmitsActualTransfers() public {
        token.transfer(MANAGER, SUPPLY * 9 / 10);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(MANAGER, address(token), 30 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(MANAGER, ALICE, 970 ether);
        _buy(ALICE, 1000 ether);
        assertEq(token.balanceOf(ALICE), 970 ether);
        assertEq(token.balanceOf(address(token)), 30 ether);
        assertEq(token.balanceOf(MANAGER), SUPPLY * 9 / 10 - 1000 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    function test_SalesWalletTransfersAndManagerSelfTransfersAreUntaxed() public {
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 300 ether);
        vm.prank(BOB);
        token.transfer(MANAGER, 300 ether);
        vm.prank(MANAGER);
        token.transfer(MANAGER, 300 ether);
        assertEq(token.balanceOf(ALICE), 700 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(MANAGER), 300 ether);
        assertEq(token.totalFeesCollected(), 0);
    }

    function test_TransferFromUsesFromAddressForFeeAndSpendsGrossAllowance() public {
        token.transfer(MANAGER, 1000 ether);
        vm.prank(MANAGER);
        token.approve(BOB, 1000 ether);
        vm.prank(BOB);
        token.transferFrom(MANAGER, ALICE, 1000 ether);
        assertEq(token.balanceOf(ALICE), 970 ether);
        assertEq(token.allowance(MANAGER, BOB), 0);

        vm.prank(ALICE);
        token.approve(MANAGER, 970 ether);
        vm.prank(MANAGER);
        token.transferFrom(ALICE, CAROL, 970 ether);
        assertEq(token.balanceOf(CAROL), 970 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    function test_InfiniteAllowanceAndDelegatedSell() public {
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, MANAGER, 1000 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.balanceOf(MANAGER), 1000 ether);
        assertEq(token.totalFeesCollected(), 0);
    }

    function test_PostBuyProRataDividendsAndClaims() public {
        _threeHolders();
        // After the buy, Alice owns 1/2, Bob 1/4 and Carol 1/4 of eligible supply.
        assertEq(token.eligibleSupply(), 38_800 ether);
        assertApproxEqAbs(token.claimableDividends(ALICE), 150 ether, 1);
        assertApproxEqAbs(token.claimableDividends(BOB), 75 ether, 1);
        assertApproxEqAbs(token.claimableDividends(CAROL), 75 ether, 1);
        uint256 owed = token.claimableDividends(ALICE);
        vm.expectEmit(true, false, false, true, address(token));
        emit PSSToken.DividendClaimed(ALICE, owed);
        vm.prank(ALICE);
        assertEq(token.claim(), owed);
        assertEq(token.balanceOf(ALICE), 19_400 ether + owed);
        assertEq(token.balanceOf(address(token)), 300 ether - owed);
        assertEq(token.claimableDividends(ALICE), 0);
        vm.prank(ALICE);
        assertEq(token.claim(), 0);
        assertEq(token.totalDividendsClaimed(), owed);
    }

    function test_TransferDoesNotTransferPastDividends() public {
        _threeHolders();
        uint256 aliceOwed = token.claimableDividends(ALICE);
        uint256 bobOwed = token.claimableDividends(BOB);
        uint256 balance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, balance);
        assertEq(token.claimableDividends(ALICE), aliceOwed);
        assertEq(token.claimableDividends(BOB), bobOwed);
        vm.prank(ALICE);
        assertEq(token.claim(), aliceOwed);
        assertEq(token.balanceOf(ALICE), aliceOwed);
    }

    function test_SellerKeepsEarnedDividendsAndNewHolderCannotClaimHistory() public {
        _threeHolders();
        uint256 owed = token.claimableDividends(ALICE);
        uint256 carolOwed = token.claimableDividends(CAROL);
        uint256 aliceBalance = token.balanceOf(ALICE);
        uint256 carolBalance = token.balanceOf(CAROL);
        vm.prank(ALICE);
        token.transfer(MANAGER, aliceBalance);
        vm.prank(CAROL);
        token.transfer(DISTRIBUTOR, carolBalance);
        assertEq(token.claimableDividends(ALICE), owed);
        assertEq(token.claimableDividends(CAROL), carolOwed);
        assertEq(token.claimableDividends(DISTRIBUTOR), 0);
        vm.prank(ALICE);
        assertEq(token.claim(), owed);
    }

    function test_FutureDividendsFollowCurrentBalancesIncludingPriorClaims() public {
        _threeHolders();
        vm.prank(ALICE);
        uint256 claimed = token.claim();
        uint256 bobBefore = token.claimableDividends(BOB);
        uint256 carolBefore = token.claimableDividends(CAROL);
        // A manager output to an excluded recipient is still taxed; eligible balances stay put.
        _buy(DEAD, 10_000 ether);
        uint256 eligible = 38_800 ether + claimed;
        assertApproxEqAbs(token.claimableDividends(ALICE), 300 ether * (19_400 ether + claimed) / eligible, 1);
        assertApproxEqAbs(token.claimableDividends(BOB) - bobBefore, 300 ether * 9700 ether / eligible, 1);
        assertApproxEqAbs(token.claimableDividends(CAROL) - carolBefore, 300 ether * 9700 ether / eligible, 1);
    }

    function test_ExcludedBalancesNeverEarnOrClaim() public {
        token.transfer(ALICE, 1 ether);
        token.transfer(DEAD, 100 ether);
        token.transfer(address(token), 100 ether);
        token.transfer(MANAGER, SUPPLY - 201 ether);
        _buy(DEAD, 1000 ether);
        assertEq(token.eligibleSupply(), 1 ether);
        assertEq(token.claimableDividends(ALICE), 30 ether);
        address[3] memory excluded = [MANAGER, address(token), DEAD];
        for (uint256 i; i < excluded.length; ++i) {
            assertTrue(token.isExcludedFromDividends(excluded[i]));
            assertEq(token.claimableDividends(excluded[i]), 0);
            vm.prank(excluded[i]);
            assertEq(token.claim(), 0);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoEligibleSupplyQueuesUntilNextTaxedBuy() public {
        token.transfer(MANAGER, SUPPLY);
        _buy(DEAD, 1000 ether);
        assertEq(token.queuedDividends(), 30 ether);
        assertEq(token.magnifiedDividendPerShare(), 0);
        assertEq(token.eligibleSupply(), 0);
        _buy(ALICE, 1000 ether);
        assertEq(token.queuedDividends(), 0);
        assertApproxEqAbs(token.claimableDividends(ALICE), 60 ether, 1);
        vm.prank(ALICE);
        uint256 claimed = token.claim();
        assertEq(token.balanceOf(address(token)), 60 ether - claimed);
    }

    function test_DirectDonationsAreNotMistakenForFees() public {
        token.transfer(address(token), 123 ether);
        assertEq(token.claimableDividends(address(this)), 0);
        assertEq(token.queuedDividends(), 0);
        assertEq(token.totalFeesCollected(), 0);
    }

    function test_ZeroTinyAndSelfTransfersPreserveAccounting() public {
        _threeHolders();
        uint256 before = token.claimableDividends(ALICE);
        vm.startPrank(ALICE);
        token.transfer(ALICE, token.balanceOf(ALICE));
        token.transfer(BOB, 0);
        vm.stopPrank();
        _buy(ALICE, 0);
        _buy(ALICE, 33);
        assertEq(token.claimableDividends(ALICE), before);
        assertEq(token.totalFeesCollected(), 300 ether);
        _buy(ALICE, 34);
        assertEq(token.totalFeesCollected(), 300 ether + 1);
    }

    function test_SubWeiAccrualSurvivesZeroTransfersAndEmptyClaims() public {
        token.transfer(ALICE, 1);
        token.transfer(BOB, 2);
        token.transfer(MANAGER, SUPPLY - 3);
        for (uint256 i; i < 4; ++i) {
            _buy(DEAD, 34); // One minor unit in dividends, split 1:2.
            vm.prank(ALICE);
            token.transfer(BOB, 0);
            if (i < 3) {
                vm.prank(ALICE);
                assertEq(token.claim(), 0);
            }
        }
        assertEq(token.claimableDividends(ALICE), 1);
        assertEq(token.claimableDividends(BOB), 2);
    }

    function test_RevertsOnZeroRecipientAndInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        token.transfer(MANAGER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, MANAGER, 100, 101));
        _buy(ALICE, 101);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_UnauthorizedTransferFromFailsEvenForDeployer() public {
        token.transfer(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), 100);
    }

    function test_FailedTransferRollsBackAllowanceAndDividends() public {
        _threeHolders();
        uint256 before = token.claimableDividends(ALICE);
        uint256 amount = token.balanceOf(ALICE) + 1;
        vm.prank(ALICE);
        token.approve(BOB, amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, token.balanceOf(ALICE), amount
            )
        );
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, amount);
        assertEq(token.allowance(ALICE, BOB), amount);
        assertEq(token.claimableDividends(ALICE), before);
    }

    function test_NoAdminMintBurnOrFeeSetterSelectors() public {
        string[17] memory signatures = [
            "owner()",
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "setOwner(address)",
            "pause()",
            "blacklist(address)",
            "setFee(uint256)",
            "setBuyFee(uint256)",
            "excludeFromDividends(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "seize(address)",
            "sweep(address)",
            "setPoolManager(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory callData = abi.encodeWithSignature(signatures[i], ALICE, SUPPLY);
            (bool deployerSuccess,) = address(token).call(callData);
            assertFalse(deployerSuccess, signatures[i]);
            vm.prank(ALICE);
            (bool strangerSuccess,) = address(token).call(callData);
            assertFalse(strangerSuccess, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.BUY_FEE_BPS(), 300);
    }

    function test_RuntimeHasNoForbiddenOpcodesAndFitsDeploymentLimit() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BuyConservesSupplyAndReserves(uint256 amount) public {
        token.transfer(MANAGER, SUPPLY * 9 / 10);
        amount = bound(amount, 0, SUPPLY * 9 / 10);
        _buy(ALICE, amount);
        uint256 fee = amount * 3 / 100;
        assertEq(token.balanceOf(ALICE), amount - fee);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.balanceOf(MANAGER) + token.balanceOf(address(this)) + token.balanceOf(ALICE) + fee, SUPPLY);
        uint256 eligible = token.eligibleSupply();
        assertApproxEqAbs(token.claimableDividends(ALICE), fee * (amount - fee) / eligible, 1);
        vm.prank(ALICE);
        token.claim();
        token.claim();
        assertLe(token.totalDividendsClaimed(), fee);
        assertEq(token.balanceOf(address(token)) + token.totalDividendsClaimed(), fee);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _threeHolders() internal {
        token.transfer(ALICE, 19_400 ether);
        token.transfer(BOB, 9700 ether);
        token.transfer(MANAGER, SUPPLY - 29_100 ether);
        _buy(CAROL, 10_000 ether);
    }

    function _buy(address to, uint256 amount) internal {
        vm.prank(MANAGER);
        token.transfer(to, amount);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
}
