// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PSSToken} from "../src/PSSToken.sol";

/// @dev Closed set of holders allows checking all liabilities, including holders with zero balance.
contract DividendHandler is Test {
    PSSToken public immutable token;
    address public immutable manager;
    address public immutable burn;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xD157)];
    uint256 public fees;
    uint256 public claimed;
    uint256 public donations;

    constructor(PSSToken token_) {
        token = token_;
        manager = token_.POOL_MANAGER();
        burn = token_.BURN_ADDRESS();
    }

    function buy(uint256 recipient, uint256 rawAmount) external {
        address to = _recipient(recipient);
        uint256 amount = bound(rawAmount, 0, token.balanceOf(manager));
        uint256 fee = to == manager ? 0 : amount * 3 / 100;
        if (to == address(token)) donations += amount - fee;
        fees += fee;
        vm.prank(manager);
        token.transfer(to, amount);
    }

    function move(uint256 sender, uint256 recipient, uint256 rawAmount, bool useAllowance) external {
        address from = actors[sender % actors.length];
        address to = _recipient(recipient);
        uint256 amount = bound(rawAmount, 0, token.balanceOf(from));
        uint256 fromOwed = token.claimableDividends(from);
        uint256 toOwed = token.claimableDividends(to);
        if (to == address(token)) donations += amount;
        if (useAllowance) {
            vm.prank(from);
            token.approve(address(this), amount);
            token.transferFrom(from, to, amount);
        } else {
            vm.prank(from);
            token.transfer(to, amount);
        }
        // Moving tokens must not move dividends which were already earned.
        assertEq(token.claimableDividends(from), fromOwed);
        assertEq(token.claimableDividends(to), toOwed);
    }

    function claim(uint256 who, bool thirdParty) external {
        address actor = actors[who % actors.length];
        uint256 owed = token.claimableDividends(actor);
        uint256 balance = token.balanceOf(actor);
        uint256 received;
        if (thirdParty) {
            received = token.claimFor(actor);
        } else {
            vm.prank(actor);
            received = token.claim();
        }
        claimed += received;
        assertEq(received, owed);
        assertEq(token.balanceOf(actor), balance + owed);
        vm.prank(actor);
        assertEq(token.claim(), 0);
    }

    function _recipient(uint256 index) private view returns (address) {
        index %= 7;
        if (index < 4) return actors[index];
        if (index == 4) return manager;
        if (index == 5) return burn;
        return address(token);
    }
}

contract DividendInvariantTest is Test {
    PSSToken internal token;
    DividendHandler internal handler;

    function setUp() public {
        token = new PSSToken();
        handler = new DividendHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 25_000_000 ether);
        }
        token.transfer(token.POOL_MANAGER(), 900_000_000 ether);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SupplyEntitlementsAndFeeReserveAreConserved() public view {
        uint256 eligible;
        uint256 owed;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            eligible += token.balanceOf(actor);
            owed += token.claimableDividends(actor);
        }
        uint256 reserve = token.balanceOf(address(token));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            eligible + reserve + token.balanceOf(token.POOL_MANAGER()) + token.balanceOf(token.BURN_ADDRESS()),
            token.totalSupply()
        );
        assertEq(token.eligibleSupply(), eligible);
        assertLe(owed + token.queuedDividends(), reserve);
        assertEq(token.totalFeesCollected(), handler.fees());
        assertEq(token.totalDividendsClaimed(), handler.claimed());
        assertEq(reserve + handler.claimed(), handler.fees() + handler.donations());
        assertLe(handler.claimed(), handler.fees());
        assertEq(token.claimableDividends(token.POOL_MANAGER()), 0);
        assertEq(token.claimableDividends(token.BURN_ADDRESS()), 0);
        assertEq(token.claimableDividends(address(token)), 0);
    }
}
