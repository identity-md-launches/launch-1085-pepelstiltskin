// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PSSToken} from "../src/PSSToken.sol";

/// @notice Ghost-ledger handler: every operation the token exposes, in random order with bounded
/// inputs, mirrored into an independent model of who should hold what. The invariants compare the
/// token's balances against the model account by account, so a fee charged on the wrong leg, or an
/// amount delivered short, is caught even when totals still add up.
contract LedgerHandler is Test {
    PSSToken public immutable token;
    address public immutable manager;
    address public immutable burn;

    address[6] public actors =
        [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xD157), address(0xE4E), address(0xF4A7)];

    mapping(address => uint256) public ghost;
    uint256 public ghostManager;
    uint256 public ghostReserve;
    uint256 public ghostBurn;
    uint256 public ghostFees;
    uint256 public ghostClaimed;
    uint256 public distributions;
    uint256 public lastIndex;
    uint256 public calls;

    constructor(PSSToken token_) {
        token = token_;
        manager = token_.POOL_MANAGER();
        burn = token_.BURN_ADDRESS();
    }

    /// @dev Seed the ghost ledger from the live state once the test has distributed the supply.
    function sync() external {
        for (uint256 i; i < actors.length; ++i) {
            ghost[actors[i]] = token.balanceOf(actors[i]);
        }
        ghostManager = token.balanceOf(manager);
        ghostReserve = token.balanceOf(address(token));
        ghostBurn = token.balanceOf(burn);
    }

    /// @dev A transfer out of the manager: taxed unless it goes back to the manager.
    function buy(uint256 recipientSeed, uint256 rawAmount) external {
        address to = _anyRecipient(recipientSeed);
        uint256 amount = bound(rawAmount, 0, ghostManager);
        uint256 fee = to == manager ? 0 : amount * 300 / 10_000;
        uint256 eligibleBefore = token.eligibleSupply();
        vm.prank(manager);
        token.transfer(to, amount);
        ghostManager -= amount;
        ghostReserve += fee;
        ghostFees += fee;
        _credit(to, amount - fee);
        if (fee != 0 && eligibleBefore != 0) ++distributions;
        _afterCall();
    }

    /// @dev A sale: a holder sends tokens to the manager, never taxed.
    function sell(uint256 actorSeed, uint256 rawAmount) external {
        address from = actors[actorSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, ghost[from]);
        uint256 owed = token.claimableDividends(from);
        vm.prank(from);
        token.transfer(manager, amount);
        ghost[from] -= amount;
        ghostManager += amount;
        assertEq(token.claimableDividends(from), owed, "a sale changed earned dividends");
        _afterCall();
    }

    /// @dev Wallet to anywhere except the manager (that is sell): never taxed. Optionally via allowance.
    function move(uint256 actorSeed, uint256 recipientSeed, uint256 rawAmount, bool useAllowance) external {
        address from = actors[actorSeed % actors.length];
        address to = _anyRecipient(recipientSeed);
        if (to == manager) to = actors[(recipientSeed >> 8) % actors.length];
        uint256 amount = bound(rawAmount, 0, ghost[from]);
        uint256 fromOwed = token.claimableDividends(from);
        uint256 toOwed = token.claimableDividends(to);
        if (useAllowance) {
            vm.prank(from);
            token.approve(address(this), amount);
            token.transferFrom(from, to, amount);
            assertEq(token.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            token.transfer(to, amount);
        }
        ghost[from] -= amount;
        _credit(to, amount);
        assertEq(token.claimableDividends(from), fromOwed, "a transfer changed the sender's dividends");
        assertEq(token.claimableDividends(to), toOwed, "a transfer changed the recipient's dividends");
        _afterCall();
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 owed = token.claimableDividends(actor);
        vm.prank(actor);
        uint256 got = token.claim();
        assertEq(got, owed, "claim paid something other than the view");
        ghost[actor] += got;
        ghostReserve -= got;
        ghostClaimed += got;
        assertEq(token.claimableDividends(actor), 0, "a claim left something claimable");
        _afterCall();
    }

    /// @dev Everything in one transaction: buy, claim, sell. Same-block dividend capture is allowed by
    /// design; the ledger must still agree and nothing beyond the fee may be captured.
    function roundTrip(uint256 actorSeed, uint256 rawAmount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, ghostManager);
        uint256 fee = amount * 300 / 10_000;
        uint256 eligibleBefore = token.eligibleSupply();
        vm.prank(manager);
        token.transfer(actor, amount);
        ghostManager -= amount;
        ghostReserve += fee;
        ghostFees += fee;
        ghost[actor] += amount - fee;
        if (fee != 0 && eligibleBefore != 0) ++distributions;
        uint256 owed = token.claimableDividends(actor);
        vm.prank(actor);
        uint256 got = token.claim();
        assertEq(got, owed);
        ghost[actor] += got;
        ghostReserve -= got;
        ghostClaimed += got;
        uint256 balance = ghost[actor];
        vm.prank(actor);
        token.transfer(manager, balance);
        ghost[actor] = 0;
        ghostManager += balance;
        _afterCall();
    }

    /// @dev Manager self-transfer: untaxed and must not touch anything.
    function managerSelfTransfer(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 0, ghostManager);
        uint256 index = token.magnifiedDividendPerShare();
        vm.prank(manager);
        token.transfer(manager, amount);
        assertEq(token.magnifiedDividendPerShare(), index);
        _afterCall();
    }

    function _credit(address to, uint256 net) private {
        if (to == manager) ghostManager += net;
        else if (to == address(token)) ghostReserve += net;
        else if (to == burn) ghostBurn += net;
        else ghost[to] += net;
    }

    function _afterCall() private {
        uint256 index = token.magnifiedDividendPerShare();
        assertGe(index, lastIndex, "dividend index decreased");
        lastIndex = index;
        ++calls;
    }

    function _anyRecipient(uint256 seed) private view returns (address) {
        uint256 pick = seed % 9;
        if (pick < actors.length) return actors[pick];
        if (pick == 6) return manager;
        if (pick == 7) return burn;
        return address(token);
    }
}

contract PSSLedgerInvariantTest is Test {
    PSSToken internal token;
    LedgerHandler internal handler;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new PSSToken();
        handler = new LedgerHandler(token);
        // Launch shape: 10% to the first actor (the distributor's claimants), 90% to the pool, nothing
        // left with the deployer. Other actors start empty and only ever hold what they buy or receive.
        token.transfer(handler.actors(0), SUPPLY / 10);
        token.transfer(token.POOL_MANAGER(), SUPPLY * 9 / 10);
        assertEq(token.balanceOf(address(this)), 0);
        handler.sync();
        targetContract(address(handler));
        // Only the token operations are fuzzed; sync() is a one-time setup helper and must never run
        // mid-sequence, or it would re-base the ledger on the live state and hide drift.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LedgerHandler.buy.selector;
        selectors[1] = LedgerHandler.sell.selector;
        selectors[2] = LedgerHandler.move.selector;
        selectors[3] = LedgerHandler.claim.selector;
        selectors[4] = LedgerHandler.roundTrip.selector;
        selectors[5] = LedgerHandler.managerSelfTransfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Minimized failure sequence: the last holder exits, then an empty holder buys,
    /// attempts to claim and sells. Fees queue because there was no pre-buy eligible supply.
    function test_EmptyFloatRoundTripDoesNotCountQueuedFeesAsDistributed() public {
        handler.roundTrip(0, 0);
        handler.roundTrip(1, 300);
        assertEq(token.eligibleSupply(), 0);
        assertEq(token.queuedDividends(), 9);
        assertEq(handler.distributions(), 0);
        invariant_FeesAreCollectedOnceAndNeverOverpaid();

        handler.buy(1, 1000);
        assertEq(token.queuedDividends(), 39);
        assertEq(handler.distributions(), 0);
        assertEq(token.claimableDividends(handler.actors(1)), 0);
        invariant_FeesAreCollectedOnceAndNeverOverpaid();

        handler.buy(2, 1000);
        assertEq(token.queuedDividends(), 0);
        assertEq(handler.distributions(), 1);
        assertApproxEqAbs(token.claimableDividends(handler.actors(1)), 69, 1);
        assertEq(token.claimableDividends(handler.actors(2)), 0);
        handler.claim(1);
        invariant_FeesAreCollectedOnceAndNeverOverpaid();
        invariant_EveryBalanceMatchesTheGhostLedger();
        invariant_ExcludedAddressesNeverHaveDividends();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_EveryBalanceMatchesTheGhostLedger() public view {
        uint256 eligible;
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghost(actor), "an actor's balance drifted from the ledger");
            eligible += token.balanceOf(actor);
        }
        assertEq(token.balanceOf(token.POOL_MANAGER()), handler.ghostManager(), "manager balance drifted");
        assertEq(token.balanceOf(address(token)), handler.ghostReserve(), "reserve drifted");
        assertEq(token.balanceOf(token.BURN_ADDRESS()), handler.ghostBurn(), "burn balance drifted");
        assertEq(token.balanceOf(address(this)), 0, "the deployer received tokens");
        assertEq(token.eligibleSupply(), eligible, "eligible supply is not the sum of eligible balances");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(
            eligible + handler.ghostManager() + handler.ghostReserve() + handler.ghostBurn(), SUPPLY, "supply leaked"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FeesAreCollectedOnceAndNeverOverpaid() public view {
        assertEq(token.totalFeesCollected(), handler.ghostFees(), "fees collected differ from 3% of manager outflows");
        assertEq(token.totalDividendsClaimed(), handler.ghostClaimed(), "claims differ from what holders received");
        assertLe(handler.ghostClaimed(), handler.ghostFees(), "more was claimed than was ever collected");
        uint256 owed;
        for (uint256 i; i < 6; ++i) {
            owed += token.claimableDividends(handler.actors(i));
        }
        uint256 reserve = token.balanceOf(address(token));
        assertLe(owed + token.queuedDividends(), reserve, "the reserve does not cover entitlements");
        uint256 distributed = token.totalFeesCollected() - token.queuedDividends();
        assertLe(handler.ghostClaimed() + owed, distributed, "more was allocated than was distributed");
        // Each distribution loses under one unit globally; each holder keeps under one unit fractional.
        assertLe(
            distributed - handler.ghostClaimed() - owed,
            handler.distributions() + 6,
            "rounding lost more than its bound"
        );
        if (handler.distributions() == 0) assertEq(token.magnifiedDividendPerShare(), 0);
        else assertGt(token.magnifiedDividendPerShare(), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ExcludedAddressesNeverHaveDividends() public view {
        assertEq(token.claimableDividends(token.POOL_MANAGER()), 0);
        assertEq(token.claimableDividends(address(token)), 0);
        assertEq(token.claimableDividends(token.BURN_ADDRESS()), 0);
        assertEq(token.claimableDividends(address(0)), 0);
    }
}
