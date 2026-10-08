// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PSSToken} from "../src/PSSToken.sol";

/// @dev A holder that can forward PSS but cannot call the token's dividend functions.
contract TransferOnlyHolder {
    function forward(PSSToken token, address recipient, uint256 amount) external {
        token.transfer(recipient, amount);
    }
}

contract DividendRevisionTest is Test {
    PSSToken internal token;
    address internal constant HOLDER = address(0x401D);
    address internal constant BUYER = address(0xB0B);
    address internal constant CALLER = address(0xCA11);
    address internal constant CLAIMANT = address(0xC1A1);

    function setUp() public {
        token = new PSSToken();
    }

    function test_ThirdPartyCanReleaseDistributorDividendsAfterAllocationLeaves() public {
        TransferOnlyHolder distributor = new TransferOnlyHolder();
        token.transfer(address(distributor), 100_000_000 ether);
        token.transfer(token.POOL_MANAGER(), 900_000_000 ether);
        _buy(BUYER, 1_000_000 ether);

        uint256 owed = token.claimableDividends(address(distributor));
        assertGt(owed, 29_000 ether);
        distributor.forward(token, CLAIMANT, 100_000_000 ether);
        assertEq(token.claimableDividends(address(distributor)), owed);
        assertEq(token.claimableDividends(CLAIMANT), 0);
        assertEq(token.balanceOf(address(distributor)), 0);

        vm.expectEmit(true, false, false, true, address(token));
        emit PSSToken.DividendClaimed(address(distributor), owed);
        vm.prank(CALLER);
        assertEq(_claimFor(address(distributor)), owed);
        assertEq(token.balanceOf(address(distributor)), owed);
        assertEq(token.balanceOf(CALLER), 0);
        assertEq(token.balanceOf(CLAIMANT), 100_000_000 ether);
        assertEq(token.claimableDividends(address(distributor)), 0);
        assertEq(_claimFor(address(distributor)), 0);
        assertEq(token.totalDividendsClaimed(), owed);
        assertEq(token.balanceOf(address(token)), token.totalFeesCollected() - owed);
    }

    function test_BuyerEarnsOnlyForTokensHeldBeforeItsBuy() public {
        token.transfer(HOLDER, 3_000_000 ether);
        token.transfer(BUYER, 1_000_000 ether);
        token.transfer(token.POOL_MANAGER(), token.balanceOf(address(this)));
        _buy(BUYER, 100_000_000 ether);
        assertApproxEqAbs(token.claimableDividends(HOLDER), 2_250_000 ether, 1);
        assertApproxEqAbs(token.claimableDividends(BUYER), 750_000 ether, 1);
        uint256 owed = token.claimableDividends(BUYER);
        vm.prank(BUYER);
        assertEq(token.claim(), owed);
        assertEq(_claimFor(BUYER), 0);
    }

    function test_ClaimForPaysOnlyBeneficiaryAndNewBalanceEarnsOnlyFutureFees() public {
        token.transfer(HOLDER, 1 ether);
        token.transfer(BUYER, 1 ether);
        token.transfer(token.POOL_MANAGER(), token.balanceOf(address(this)));
        _buy(token.BURN_ADDRESS(), 100 ether);
        uint256 owed = token.claimableDividends(HOLDER);
        assertEq(owed, 1.5 ether);
        vm.prank(CALLER);
        assertEq(_claimFor(HOLDER), owed);
        assertEq(token.balanceOf(HOLDER), 2.5 ether);
        assertEq(token.balanceOf(CALLER), 0);
        assertEq(token.claimableDividends(HOLDER), 0);
        vm.prank(HOLDER);
        assertEq(token.claim(), 0);

        _buy(token.BURN_ADDRESS(), 100 ether);
        assertApproxEqAbs(token.claimableDividends(HOLDER), uint256(3 ether) * 5 / 7, 1);
        assertApproxEqAbs(token.claimableDividends(BUYER), 1.5 ether + uint256(3 ether) * 2 / 7, 1);

        vm.prank(CALLER);
        (bool redirected,) = address(token).call(abi.encodeWithSignature("claimFor(address,address)", HOLDER, CALLER));
        assertFalse(redirected);
        assertEq(token.balanceOf(CALLER), 0);
    }

    function test_ClaimForExcludedAndEmptyAccountsReturnsZero() public {
        token.transfer(HOLDER, 1 ether);
        token.transfer(token.POOL_MANAGER(), token.balanceOf(address(this)));
        _buy(BUYER, 100 ether);
        address[5] memory accounts = [token.POOL_MANAGER(), address(token), token.BURN_ADDRESS(), address(0), CALLER];
        uint256 reserve = token.balanceOf(address(token));
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(_claimFor(accounts[i]), 0);
        }
        assertEq(token.balanceOf(address(token)), reserve);
        assertEq(token.totalDividendsClaimed(), 0);
    }

    function test_EmptyFloatBuyQueuesFeeWithoutRebatingNewBuyer() public {
        token.transfer(token.POOL_MANAGER(), token.totalSupply());
        _buy(BUYER, 100 ether);
        assertEq(token.queuedDividends(), 3 ether);
        assertEq(token.claimableDividends(BUYER), 0);
        assertEq(_claimFor(BUYER), 0);

        _buy(HOLDER, 100 ether);
        assertEq(token.queuedDividends(), 0);
        assertApproxEqAbs(token.claimableDividends(BUYER), 6 ether, 1);
        assertEq(token.claimableDividends(HOLDER), 0);
    }

    function test_EmptyThirdPartyClaimsPreserveFractionalEntitlements() public {
        token.transfer(HOLDER, 1);
        token.transfer(BUYER, 2);
        token.transfer(token.POOL_MANAGER(), token.balanceOf(address(this)));
        for (uint256 i; i < 4; ++i) {
            _buy(token.BURN_ADDRESS(), 34);
            if (i < 3) assertEq(_claimFor(HOLDER), 0);
        }
        assertEq(_claimFor(HOLDER), 1);
        assertEq(_claimFor(BUYER), 2);
        assertEq(token.balanceOf(address(token)), 1);
    }

    // Use the ABI directly so the regression can also run against the original missing selector.
    function _claimFor(address account) private returns (uint256) {
        (bool success, bytes memory result) = address(token).call(abi.encodeWithSignature("claimFor(address)", account));
        assertTrue(success, "claimFor unavailable: contract holder dividends cannot be paid");
        return abi.decode(result, (uint256));
    }

    function _buy(address to, uint256 amount) private {
        vm.prank(token.POOL_MANAGER());
        token.transfer(to, amount);
    }
}
